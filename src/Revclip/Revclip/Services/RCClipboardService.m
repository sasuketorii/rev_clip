//
//  RCClipboardService.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import "RCClipboardService.h"

#import <ImageIO/ImageIO.h>

#import "RCConstants.h"
#import "RCExcludeAppService.h"
#import "RCDataCleanService.h"
#import "RCDatabaseManager.h"
#import "RCPanicEraseService.h"
#import "RCPrivacyService.h"
#import "RCClipData.h"
#import "RCClipItem.h"
#import "NSColor+HexString.h"
#import "RCUtilities.h"
#import <os/log.h>

NSString * const RCClipboardDidChangeNotification = @"RCClipboardDidChangeNotification";

static NSTimeInterval const kRCClipboardPollingInterval = 0.5;
static NSInteger const kRCDefaultMaxClipSizeBytes = 52428800;
static NSString * const kRCClipDataFileExtension = @"rcclip";
static NSString * const kRCStoreTypeString = @"String";
static NSString * const kRCStoreTypeRTF = @"RTF";
static NSString * const kRCStoreTypeRTFD = @"RTFD";
static NSString * const kRCStoreTypePDF = @"PDF";
static NSString * const kRCStoreTypeFilenames = @"Filenames";
static NSString * const kRCStoreTypeURL = @"URL";
static NSString * const kRCStoreTypeTIFF = @"TIFF";

static os_log_t RCClipboardServiceLog(void) {
    static os_log_t logger = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        logger = os_log_create("com.revclip", "RCClipboardService");
    });
    return logger;
}

@interface RCClipboardService ()

@property (atomic, readwrite, assign) BOOL isMonitoring;
@property (nonatomic, strong, nullable) dispatch_source_t monitorTimer;
@property (nonatomic, strong) dispatch_queue_t monitoringQueue;
@property (nonatomic, strong) dispatch_queue_t fileOperationQueue;
@property (nonatomic, assign) NSInteger cachedChangeCount;
@property (nonatomic, strong, nullable) RCPrivacyService *privacyService;

- (NSInteger)readGeneralPasteboardChangeCount;
- (RCPrivacyService *)resolvedPrivacyService;
- (BOOL)canReadPasteboardContentsUsingPrivacyGate;
- (void)handleClipboardAccessStateDidChange:(NSNotification *)notification;

@end

@implementation RCClipboardService

+ (instancetype)shared {
    static RCClipboardService *sharedService = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedService = [[self alloc] init];
    });
    return sharedService;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isMonitoring = NO;
        _monitoringQueue = dispatch_queue_create("com.revclip.clipboard.monitoring", DISPATCH_QUEUE_SERIAL);
        _fileOperationQueue = dispatch_queue_create("com.revclip.clipboard.file", DISPATCH_QUEUE_SERIAL);
        _cachedChangeCount = [self readGeneralPasteboardChangeCount];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleClipboardAccessStateDidChange:)
                                                     name:RCClipboardAccessStateDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    // G3-016: dealloc ではタイマー invalidate のみ直接実行。
    // stopMonitoring は @synchronized 等の副作用があるため、
    // dealloc 内ではタイマーのキャンセルだけ行う。
    dispatch_source_t timer = _monitorTimer;
    _monitorTimer = nil;
    _isMonitoring = NO;
    if (timer != nil) {
        dispatch_source_cancel(timer);
    }
}

#pragma mark - Public

- (void)startMonitoring {
    @synchronized (self) {
        if (self.isMonitoring) {
            return;
        }

        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.monitoringQueue);
        if (timer == nil) {
            return;
        }

        self.cachedChangeCount = [self readGeneralPasteboardChangeCount];
        uint64_t interval = (uint64_t)(kRCClipboardPollingInterval * (double)NSEC_PER_SEC);
        uint64_t leeway = interval / 10;

        dispatch_source_set_timer(timer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval),
                                  interval,
                                  leeway);

        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(timer, ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            [strongSelf pollPasteboardOnMonitoringQueue];
        });

        self.monitorTimer = timer;
        self.isMonitoring = YES;
        dispatch_resume(timer);
    }
}

- (void)stopMonitoring {
    dispatch_source_t timer = nil;

    @synchronized (self) {
        if (!self.isMonitoring) {
            return;
        }

        timer = self.monitorTimer;
        self.monitorTimer = nil;
        self.isMonitoring = NO;
    }

    if (timer != nil) {
        dispatch_source_cancel(timer);
    }
}

- (void)captureCurrentClipboard {
    // G3-003: 冗長な early excluded app チェックを削除。
    // saveClipFromPasteboardOnMonitoringQueue: 内の shouldSkipCurrentApplication で
    // 同じチェックが行われるため、ここでは不要。
    dispatch_async(self.monitoringQueue, ^{
        [self captureCurrentClipboardOnMonitoringQueue];
    });
}

- (void)flushQueueWithCompletion:(void(^)(void))completion {
    dispatch_async(self.monitoringQueue, ^{
        if (completion != nil) {
            completion();
        }
    });
}

#pragma mark - Private: Monitor / Capture

- (RCPrivacyService *)resolvedPrivacyService {
    RCPrivacyService *service = self.privacyService;
    return (service != nil) ? service : [RCPrivacyService shared];
}

- (BOOL)canReadPasteboardContentsUsingPrivacyGate {
    return [[self resolvedPrivacyService] shouldCaptureClipboardContents];
}

- (void)handleClipboardAccessStateDidChange:(NSNotification *)notification {
    (void)notification;
    if ([self canReadPasteboardContentsUsingPrivacyGate]) {
        [self captureCurrentClipboard];
        return;
    }
    [[self resolvedPrivacyService] presentClipboardAccessGuidanceIfNeeded];
}

- (NSInteger)readGeneralPasteboardChangeCount {
    if ([NSThread isMainThread]) {
        return [NSPasteboard generalPasteboard].changeCount;
    }

    __block NSInteger changeCount = 0;
    dispatch_sync(dispatch_get_main_queue(), ^{
        changeCount = [NSPasteboard generalPasteboard].changeCount;
    });
    return changeCount;
}

- (void)pollPasteboardOnMonitoringQueue {
    if (!self.isMonitoring) {
        return;
    }

    // G3-004: 内部ペースト操作中はポーリングをスキップして重複登録を防ぐ
    if (self.isPastingInternally) {
        return;
    }

    // G3-001: NSPasteboard の読み取りをメインキューで実行
    __block NSInteger currentChangeCount = 0;
    __block RCClipData *clipData = nil;
    __block NSString *capturedBundleIdentifier = @"";
    __block BOOL shouldSkipConcealedOrTransient = NO;
    __block BOOL skippedDueToPrivacy = NO;
    dispatch_block_t readBlock = ^{
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        currentChangeCount = pasteboard.changeCount;

        if (currentChangeCount == self.cachedChangeCount) {
            return;
        }

        if (![self canReadPasteboardContentsUsingPrivacyGate]) {
            skippedDueToPrivacy = YES;
            return;
        }

        NSRunningApplication *frontmostApplication = [NSWorkspace sharedWorkspace].frontmostApplication;
        capturedBundleIdentifier = frontmostApplication.bundleIdentifier ?: @"";

        NSArray<NSString *> *concealedTypes = @[
            @"org.nspasteboard.ConcealedType",
            @"org.nspasteboard.TransientType",
            @"org.nspasteboard.AutoGeneratedType",
        ];
        for (NSString *type in concealedTypes) {
            if ([pasteboard dataForType:type] != nil) {
                shouldSkipConcealedOrTransient = YES;
                break;
            }
        }

        if (!shouldSkipConcealedOrTransient) {
            clipData = [RCClipData clipDataFromPasteboard:pasteboard];
        }
    };
    if ([NSThread isMainThread]) {
        readBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), readBlock);
    }
    if (currentChangeCount == self.cachedChangeCount) {
        return;
    }
    self.cachedChangeCount = currentChangeCount;

    if (skippedDueToPrivacy) {
        [[self resolvedPrivacyService] presentClipboardAccessGuidanceIfNeeded];
        return;
    }

    if (shouldSkipConcealedOrTransient) {
        return;
    }

    [self processClipDataOnMonitoringQueue:clipData
                  sourceBundleIdentifier:capturedBundleIdentifier];
}

- (void)captureCurrentClipboardOnMonitoringQueue {
    // G3-001: NSPasteboard の読み取りをメインキューで実行
    __block RCClipData *clipData = nil;
    __block NSString *capturedBundleIdentifier = @"";
    __block BOOL shouldSkipConcealedOrTransient = NO;
    __block BOOL skippedDueToPrivacy = NO;
    dispatch_block_t readBlock = ^{
        if (![self canReadPasteboardContentsUsingPrivacyGate]) {
            skippedDueToPrivacy = YES;
            return;
        }

        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        self.cachedChangeCount = pasteboard.changeCount;

        NSArray<NSString *> *concealedTypes = @[
            @"org.nspasteboard.ConcealedType",
            @"org.nspasteboard.TransientType",
            @"org.nspasteboard.AutoGeneratedType",
        ];
        for (NSString *type in concealedTypes) {
            if ([pasteboard dataForType:type] != nil) {
                shouldSkipConcealedOrTransient = YES;
                break;
            }
        }

        if (!shouldSkipConcealedOrTransient) {
            clipData = [RCClipData clipDataFromPasteboard:pasteboard];
        }

        NSRunningApplication *frontmostApplication = [NSWorkspace sharedWorkspace].frontmostApplication;
        capturedBundleIdentifier = frontmostApplication.bundleIdentifier ?: @"";
    };
    if ([NSThread isMainThread]) {
        readBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), readBlock);
    }

    if (skippedDueToPrivacy) {
        [[self resolvedPrivacyService] presentClipboardAccessGuidanceIfNeeded];
        return;
    }

    if (shouldSkipConcealedOrTransient) {
        return;
    }

    [self processClipDataOnMonitoringQueue:clipData
                  sourceBundleIdentifier:capturedBundleIdentifier];
}

- (void)processClipDataOnMonitoringQueue:(RCClipData *)clipData
                    sourceBundleIdentifier:(NSString *)sourceBundleIdentifier {
    if ([RCPanicEraseService shared].isPanicInProgress) {
        return;
    }

    if ([[RCExcludeAppService shared] shouldExcludeAppWithBundleIdentifier:sourceBundleIdentifier]) {
        return;
    }

    if (![self hasClipContent:clipData]) {
        return;
    }

    if (![self shouldStoreClipData:clipData]) {
        return;
    }

    NSString *dataHash = [clipData dataHash];
    if (dataHash.length == 0) {
        return;
    }

    RCDatabaseManager *databaseManager = [RCDatabaseManager shared];
    if (![databaseManager setupDatabase]) {
        return;
    }

    NSInteger updateTime = [self currentTimestamp];
    NSDictionary *existingClipDict = [databaseManager clipItemWithDataHash:dataHash];
    if (existingClipDict != nil) {
        [self handleExistingClipWithHash:dataHash
                            existingDict:existingClipDict
                              updateTime:updateTime
                         databaseManager:databaseManager];
        return;
    }

    NSString *directoryPath = [RCUtilities clipDataDirectoryPath];
    if (![RCUtilities ensureDirectoryExists:directoryPath]) {
        return;
    }

    NSString *identifier = [NSUUID UUID].UUIDString;
    NSString *dataFileName = [NSString stringWithFormat:@"%@.%@", identifier, kRCClipDataFileExtension];
    NSString *dataPath = [directoryPath stringByAppendingPathComponent:dataFileName];

    if (![self saveClipData:clipData toPath:dataPath]) {
        return;
    }

    NSString *thumbnailPath = [self generateThumbnailPathForClipData:clipData
                                                           identifier:identifier
                                                        directoryPath:directoryPath];

    BOOL isColorCode = NO;
    if (clipData.stringValue.length > 0 && [NSColor isPotentialColorStringCandidate:clipData.stringValue]) {
        isColorCode = [NSColor isValidColorString:clipData.stringValue];
    }

    NSDictionary *clipDictionary = @{
        @"data_path": dataPath,
        @"title": clipData.title ?: @"",
        @"data_hash": dataHash,
        @"primary_type": clipData.primaryType ?: @"",
        @"update_time": @(updateTime),
        @"thumbnail_path": thumbnailPath ?: @"",
        @"is_color_code": @(isColorCode),
    };

    if (![databaseManager insertClipItem:clipDictionary]) {
        [self deleteFileAtPath:dataPath];
        [self deleteFileAtPath:thumbnailPath];
        return;
    }

    RCClipItem *clipItem = [[RCClipItem alloc] initWithDictionary:clipDictionary];
    // G3-006: トリミングロジックは RCDataCleanService に一本化。
    // ここでは重複して trimHistoryIfNeeded を呼ばない。
    [[RCDataCleanService shared] scheduleDebouncedCleanup];
    [self postClipboardDidChangeNotificationWithClipItem:clipItem];
}

/// G3-014: shouldOverwrite / shouldReorder セマンティクス
///
/// shouldOverwrite (kRCPrefOverwriteSameHistory):
///   YES — 同一ハッシュのクリップが再度コピーされた場合、既存レコードの
///          update_time を更新して最新位置に移動（"上書き"）する。
///   NO  — 既存レコードを更新しない。
///
/// shouldReorder (kRCPrefReorderClipsAfterPasting):
///   YES — ペースト後に同一クリップを再利用した場合にも update_time を更新して
///          リストの先頭に並べ替える。
///   NO  — 並べ替えを行わない。
///
/// 両方が NO の場合、既存クリップに対しては一切の更新を行わずスキップする。
- (void)handleExistingClipWithHash:(NSString *)dataHash
                      existingDict:(NSDictionary *)existingClipDict
                        updateTime:(NSInteger)updateTime
                   databaseManager:(RCDatabaseManager *)databaseManager {
    BOOL shouldOverwrite = [self boolPreferenceForKey:kRCPrefOverwriteSameHistory defaultValue:YES];
    BOOL shouldReorder = [self boolPreferenceForKey:kRCPrefReorderClipsAfterPasting defaultValue:YES];

    if (!shouldOverwrite && !shouldReorder) {
        return;
    }

    if (![databaseManager updateClipItemUpdateTime:dataHash time:updateTime]) {
        return;
    }

    NSMutableDictionary *updatedDict = [existingClipDict mutableCopy];
    updatedDict[@"update_time"] = @(updateTime);
    RCClipItem *updatedItem = [[RCClipItem alloc] initWithDictionary:updatedDict];
    [self postClipboardDidChangeNotificationWithClipItem:updatedItem];
}

#pragma mark - Private: Filtering

- (BOOL)hasClipContent:(RCClipData *)clipData {
    return (clipData.stringValue.length > 0
            || clipData.RTFData.length > 0
            || clipData.RTFDData.length > 0
            || clipData.PDFData.length > 0
            || clipData.fileNames.count > 0
            || clipData.fileURLs.count > 0
            || clipData.URLString.length > 0
            || clipData.TIFFData.length > 0);
}

- (BOOL)shouldStoreClipData:(RCClipData *)clipData {
    NSDictionary *storeTypes = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kRCPrefStoreTypesKey];
    if (![storeTypes isKindOfClass:[NSDictionary class]]) {
        return YES;
    }

    BOOL hasSupportedType = NO;
    BOOL hasEnabledType = NO;

    BOOL hasString = (clipData.stringValue.length > 0);
    if (hasString) {
        hasSupportedType = YES;
        hasEnabledType = hasEnabledType || [self isStoreTypeEnabledForKey:kRCStoreTypeString inStoreTypes:storeTypes];
    }

    BOOL hasRTF = (clipData.RTFData.length > 0);
    if (hasRTF) {
        hasSupportedType = YES;
        hasEnabledType = hasEnabledType || [self isStoreTypeEnabledForKey:kRCStoreTypeRTF inStoreTypes:storeTypes];
    }

    BOOL hasRTFD = (clipData.RTFDData.length > 0);
    if (hasRTFD) {
        hasSupportedType = YES;
        hasEnabledType = hasEnabledType || [self isStoreTypeEnabledForKey:kRCStoreTypeRTFD inStoreTypes:storeTypes];
    }

    BOOL hasPDF = (clipData.PDFData.length > 0);
    if (hasPDF) {
        hasSupportedType = YES;
        hasEnabledType = hasEnabledType || [self isStoreTypeEnabledForKey:kRCStoreTypePDF inStoreTypes:storeTypes];
    }

    BOOL hasFiles = (clipData.fileNames.count > 0 || clipData.fileURLs.count > 0);
    if (hasFiles) {
        hasSupportedType = YES;
        hasEnabledType = hasEnabledType || [self isStoreTypeEnabledForKey:kRCStoreTypeFilenames inStoreTypes:storeTypes];
    }

    BOOL hasURL = (clipData.URLString.length > 0);
    if (hasURL) {
        hasSupportedType = YES;
        hasEnabledType = hasEnabledType || [self isStoreTypeEnabledForKey:kRCStoreTypeURL inStoreTypes:storeTypes];
    }

    BOOL hasTIFF = (clipData.TIFFData.length > 0);
    if (hasTIFF) {
        hasSupportedType = YES;
        hasEnabledType = hasEnabledType || [self isStoreTypeEnabledForKey:kRCStoreTypeTIFF inStoreTypes:storeTypes];
    }

    if (!hasSupportedType) {
        return YES;
    }

    return hasEnabledType;
}

- (BOOL)isStoreTypeEnabledForKey:(NSString *)key inStoreTypes:(NSDictionary *)storeTypes {
    id value = storeTypes[key];
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value boolValue];
    }
    if ([value isKindOfClass:[NSString class]]) {
        return [(NSString *)value boolValue];
    }
    return YES;
}

#pragma mark - Private: File / Thumbnail

// G3-002: dispatch_sync は monitoringQueue → fileOperationQueue への呼び出しであり、
// 同一キューへの sync ではないためデッドロックの危険はない。
// 戻り値が必要なため dispatch_sync を使用している。
- (BOOL)saveClipData:(RCClipData *)clipData toPath:(NSString *)path {
    if (path.length == 0) {
        return NO;
    }

    NSError *archiveError = nil;
    NSData *archivedData = [NSKeyedArchiver archivedDataWithRootObject:clipData
                                                  requiringSecureCoding:YES
                                                                  error:&archiveError];
    if (archivedData == nil) {
        os_log_error(RCClipboardServiceLog(),
                     "Failed to archive clip data before size check (%{private}@)",
                     archiveError.localizedDescription);
        return NO;
    }

    // CFBooleanRef チェック付きの安全な読み取り
    id rawValue = [[NSUserDefaults standardUserDefaults] objectForKey:kRCPrefMaxClipSizeBytesKey];
    NSInteger maxClipSizeBytes = kRCDefaultMaxClipSizeBytes;
    if ([rawValue isKindOfClass:[NSNumber class]] &&
        CFGetTypeID((__bridge CFTypeRef)rawValue) != CFBooleanGetTypeID()) {
        maxClipSizeBytes = [(NSNumber *)rawValue integerValue];
    } else if ([rawValue isKindOfClass:[NSString class]]) {
        maxClipSizeBytes = [(NSString *)rawValue integerValue];
    }
    if (maxClipSizeBytes < 1048576) {
        maxClipSizeBytes = kRCDefaultMaxClipSizeBytes;
    }
    if (archivedData.length > (NSUInteger)maxClipSizeBytes) {
        os_log_debug(RCClipboardServiceLog(),
                     "Skipping clip save because archived data size (%lu bytes) exceeds limit (%ld bytes)",
                     (unsigned long)archivedData.length,
                     (long)maxClipSizeBytes);
        return NO;
    }

    __block BOOL saved = NO;
    dispatch_sync(self.fileOperationQueue, ^{
        saved = [clipData saveToPath:path];
    });
    return saved;
}

// G3-011: CGImageSource でサムネイル生成。大きな画像でもメモリ効率が良い。
- (NSString *)generateThumbnailPathForClipData:(RCClipData *)clipData
                                     identifier:(NSString *)identifier
                                  directoryPath:(NSString *)directoryPath {
    if (clipData.TIFFData.length == 0 || identifier.length == 0 || directoryPath.length == 0) {
        return @"";
    }

    NSSize targetSize = [self thumbnailTargetSize];
    CGFloat maxDimension = MAX(targetSize.width, targetSize.height);
    if (maxDimension <= 0.0) {
        return @"";
    }

    CGImageSourceRef imageSource = CGImageSourceCreateWithData((__bridge CFDataRef)clipData.TIFFData, NULL);
    if (imageSource == NULL) {
        return @"";
    }

    NSDictionary *thumbnailOptions = @{
        (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @((NSInteger)maxDimension),
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
    };

    CGImageRef thumbnailRef = CGImageSourceCreateThumbnailAtIndex(imageSource, 0,
                                                                   (__bridge CFDictionaryRef)thumbnailOptions);
    CFRelease(imageSource);

    if (thumbnailRef == NULL) {
        return @"";
    }

    NSBitmapImageRep *bitmapRep = [[NSBitmapImageRep alloc] initWithCGImage:thumbnailRef];
    CGImageRelease(thumbnailRef);

    if (bitmapRep == nil) {
        return @"";
    }

    NSData *thumbnailData = [bitmapRep representationUsingType:NSBitmapImageFileTypeJPEG
                                                    properties:@{ NSImageCompressionFactor: @0.7 }];
    if (!thumbnailData) {
        thumbnailData = [bitmapRep representationUsingType:NSBitmapImageFileTypePNG
                                                properties:@{}];
    }
    if (!thumbnailData || thumbnailData.length == 0) {
        return @"";
    }

    NSString *thumbnailFileName = [NSString stringWithFormat:@"%@.thumbnail.tiff", identifier];
    NSString *thumbnailPath = [directoryPath stringByAppendingPathComponent:thumbnailFileName];

    // G3-002: dispatch_sync は monitoringQueue → fileOperationQueue であり安全
    __block BOOL wrote = NO;
    dispatch_sync(self.fileOperationQueue, ^{
        NSError *error = nil;
        wrote = [thumbnailData writeToFile:thumbnailPath options:NSDataWritingAtomic error:&error];
        if (!wrote) {
            os_log_error(RCClipboardServiceLog(),
                         "Failed to save thumbnail at path %{private}@ (%{private}@)",
                         thumbnailPath, error.localizedDescription);
            return;
        }

        NSError *permissionError = nil;
        BOOL permissionApplied = [[NSFileManager defaultManager] setAttributes:@{ NSFilePosixPermissions: @(0600) }
                                                                   ofItemAtPath:thumbnailPath
                                                                          error:&permissionError];
        if (!permissionApplied && permissionError != nil) {
            os_log_error(RCClipboardServiceLog(),
                         "Failed to set thumbnail permissions for %{private}@ (%{private}@)",
                         thumbnailPath, permissionError.localizedDescription);
        }
    });

    return wrote ? thumbnailPath : @"";
}

- (NSSize)thumbnailTargetSize {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    CGFloat width = MIN(512.0, MAX(16.0, [defaults doubleForKey:kRCThumbnailWidthKey]));
    CGFloat height = MIN(512.0, MAX(16.0, [defaults doubleForKey:kRCThumbnailHeightKey]));
    return NSMakeSize(width, height);
}

- (void)deleteFileAtPath:(NSString *)path {
    if (path.length == 0) {
        return;
    }

    dispatch_sync(self.fileOperationQueue, ^{
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if (![fileManager fileExistsAtPath:path]) {
            return;
        }

        [RCPanicEraseService secureOverwriteFileAtPath:path];

        NSError *error = nil;
        BOOL removed = [fileManager removeItemAtPath:path error:&error];
        if (!removed) {
            os_log_error(RCClipboardServiceLog(),
                         "Failed to remove file at path %{private}@ (%{private}@)",
                         path, error.localizedDescription);
        }
    });
}

- (void)deleteFilesForClipItem:(RCClipItem *)clipItem {
    [self deleteFileAtPath:clipItem.dataPath];
    [self deleteFileAtPath:clipItem.thumbnailPath];
}

#pragma mark - Private: Cleanup / Notification

// G3-006: trimHistoryIfNeeded は RCDataCleanService に一本化されたため削除。

- (NSInteger)currentTimestamp {
    return (NSInteger)([[NSDate date] timeIntervalSince1970] * 1000.0);
}

- (BOOL)boolPreferenceForKey:(NSString *)key defaultValue:(BOOL)defaultValue {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id value = [defaults objectForKey:key];
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value boolValue];
    }
    if ([value isKindOfClass:[NSString class]]) {
        return [(NSString *)value boolValue];
    }
    return defaultValue;
}

- (NSInteger)integerPreferenceForKey:(NSString *)key defaultValue:(NSInteger)defaultValue {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id value = [defaults objectForKey:key];
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value integerValue];
    }
    if ([value isKindOfClass:[NSString class]]) {
        return [(NSString *)value integerValue];
    }
    return defaultValue;
}

- (void)postClipboardDidChangeNotificationWithClipItem:(RCClipItem *)clipItem {
    if (clipItem == nil) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:RCClipboardDidChangeNotification
                                                            object:self
                                                          userInfo:@{ @"clipItem": clipItem }];
    });
}

@end
