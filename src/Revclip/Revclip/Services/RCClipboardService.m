//
//  RCClipboardService.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import "RCClipboardService.h"
#import "RCFileImagePreview.h"
#import "Revclip-Swift.h"
#import "RCStorageMigration.h"
#import <sys/stat.h>

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
@property (nonatomic, strong) dispatch_queue_t persistenceQueue;
@property (atomic, assign) BOOL captureSuspended;
@property (atomic, assign) NSUInteger monitoringGeneration;
// Main-thread-owned pasteboard generation state.
@property (nonatomic, strong, nullable) NSNumber *internalChangeCount;
// Guarded by pendingCondition; includes the currently executing save.
@property (nonatomic, strong) NSCondition *pendingCondition;
@property (nonatomic, assign) NSUInteger pendingCaptureCount;
@property (nonatomic, assign) NSUInteger pendingCaptureBytes;
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
        _pendingCondition = [NSCondition new];
        _monitoringQueue = dispatch_queue_create("com.revclip.clipboard.monitoring", DISPATCH_QUEUE_SERIAL);
        _persistenceQueue = dispatch_queue_create("com.revclip.clipboard.persistence", DISPATCH_QUEUE_SERIAL);
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
    // Never hold the lifecycle lock while waiting for the main thread.
    if (!NSThread.isMainThread) {
        dispatch_sync(dispatch_get_main_queue(), ^{ [self startMonitoring]; });
        return;
    }
    @synchronized (self) {
        if (self.isMonitoring) {
            return;
        }

        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.monitoringQueue);
        if (timer == nil) {
            return;
        }

        self.captureSuspended = NO;
        NSUInteger generation = ++self.monitoringGeneration;
        dispatch_block_t reset = ^{ self.cachedChangeCount = [self readGeneralPasteboardChangeCount]; };
        if (NSThread.isMainThread) reset(); else dispatch_sync(dispatch_get_main_queue(), reset);
        uint64_t interval = (uint64_t)(kRCClipboardPollingInterval * (double)NSEC_PER_SEC);
        uint64_t leeway = interval / 10;

        dispatch_source_set_timer(timer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval),
                                  interval,
                                  leeway);

        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(timer, ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil || generation != strongSelf.monitoringGeneration) { return; }
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
        self.captureSuspended = YES;
        self.monitoringGeneration++;
        if (!self.isMonitoring) { return; }

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
        dispatch_async(self.persistenceQueue, ^{
            if (completion) completion();
        });
    });
}

- (void)recordInternalPasteboardChangeCount:(NSInteger)changeCount {
    NSAssert(NSThread.isMainThread, @"Internal clipboard writes must complete on main");
    self.internalChangeCount = @(changeCount);
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
    if (!self.isMonitoring || self.captureSuspended) return;
    [self acquireSnapshotForcingRead:NO];
}

- (void)captureCurrentClipboardOnMonitoringQueue {
    if (self.captureSuspended) return;
    [self acquireSnapshotForcingRead:YES];
}

- (void)acquireSnapshotForcingRead:(BOOL)force {
    __block RCClipData *clip = nil;
    __block NSString *source = @"";
    __block BOOL denied = NO;
    dispatch_block_t read = ^{
        if (self.captureSuspended) return;
        NSPasteboard *board = NSPasteboard.generalPasteboard;
        NSInteger generation = board.changeCount;
        if (self.internalChangeCount) {
            if (generation == self.internalChangeCount.integerValue) {
                self.cachedChangeCount = generation;
                return;
            }
            self.internalChangeCount = nil;
        }
        if (!force && generation == self.cachedChangeCount) return;
        // Record the generation inspected, not a newer generation published
        // by a data provider during the read. The latter is retried next poll.
        self.cachedChangeCount = generation;
        if (![self canReadPasteboardContentsUsingPrivacyGate]) { denied = YES; return; }
        source = NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier ?: @"";
        clip = [self readEligibleClipFromPasteboard:board sourceBundleIdentifier:source];
    };
    if (NSThread.isMainThread) read(); else dispatch_sync(dispatch_get_main_queue(), read);
    if (denied) { [[self resolvedPrivacyService] presentClipboardAccessGuidanceIfNeeded]; return; }
    if (clip) [self enqueueCapturedClip:clip source:source];
}

- (NSUInteger)pendingCostForClip:(RCClipData *)clip {
    // Conservative retained payload accounting, without serializing or decoding.
    NSUInteger cost = 1024;
    NSArray *data = @[clip.HTMLData ?: NSData.data, clip.RTFData ?: NSData.data,
                     clip.RTFDData ?: NSData.data, clip.PDFData ?: NSData.data,
                     clip.TIFFData ?: NSData.data];
    for (NSData *item in data) {
        if (item.length > NSUIntegerMax - cost) return NSUIntegerMax;
        cost += item.length;
    }
    NSMutableArray<NSString *> *strings = [NSMutableArray arrayWithArray:clip.fileNames ?: @[]];
    [strings addObject:clip.stringValue ?: @""]; [strings addObject:clip.URLString ?: @""];
    for (NSURL *url in clip.fileURLs) [strings addObject:url.absoluteString];
    for (NSString *item in strings) {
        if (item.length > (NSUIntegerMax - cost) / 2) return NSUIntegerMax;
        cost += item.length * 2;
    }
    return cost;
}

- (void)enqueueCapturedClip:(RCClipData *)clip source:(NSString *)source {
    NSUInteger cost = [self pendingCostForClip:clip];
    static const NSUInteger byteBudget = 100 * 1024 * 1024;
    // Production acquisition is serial and off-main. Backpressure keeps the
    // already acquired original rather than dropping it. A single large item
    // is permitted alone; the existing archive-size preference remains the
    // authoritative per-item limit, not this queue's working-set target.
    [self.pendingCondition lock];
    while (self.pendingCaptureCount != 0 &&
           (self.pendingCaptureCount >= 16 || cost > byteBudget ||
            self.pendingCaptureBytes > byteBudget - cost)) {
        [self.pendingCondition wait];
    }
    self.pendingCaptureCount++;
    self.pendingCaptureBytes += cost;
    [self.pendingCondition unlock];
    dispatch_async(self.persistenceQueue, ^{
        @autoreleasepool {
            @try { [self processClipDataOnMonitoringQueue:clip sourceBundleIdentifier:source]; }
            @finally {
                [self.pendingCondition lock];
                self.pendingCaptureCount--; self.pendingCaptureBytes -= cost;
                [self.pendingCondition signal];
                [self.pendingCondition unlock];
            }
        }
    });
}

// Inspect only metadata before materializing potentially confidential clipboard contents.
- (BOOL)sourceIsExcluded:(NSString *)bundleIdentifier {
    return [[RCExcludeAppService shared] shouldExcludeAppWithBundleIdentifier:bundleIdentifier];
}

- (RCClipData *)readEligibleClipFromPasteboard:(NSPasteboard *)pasteboard sourceBundleIdentifier:(NSString *)bundleIdentifier {
    if ([self sourceIsExcluded:bundleIdentifier]) { return nil; }
    NSInteger changeCount = pasteboard.changeCount;
    NSArray<NSString *> *blockedTypes = @[@"org.nspasteboard.ConcealedType", @"org.nspasteboard.TransientType", @"org.nspasteboard.AutoGeneratedType"];
    for (NSString *type in pasteboard.types) {
        if ([blockedTypes containsObject:type]) { return nil; }
    }
    RCClipData *clip = [RCClipData clipDataFromPasteboard:pasteboard];
    NSDictionary *types = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kRCPrefStoreTypesKey];
    if (![self isStoreTypeEnabledForKey:@"HTML" inStoreTypes:types]) { clip.HTMLData = nil; }
    // Another application may change the pasteboard while a data provider is fulfilling a read.
    return pasteboard.changeCount == changeCount ? clip : nil;
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
    if (!existingClipDict) {
        // Preserve pre-v2 history without rewriting user archives. A legacy
        // digest did not identify every format, so only reuse it after checking
        // the authenticated original's complete payload, not its title/hash.
        NSString *legacyHash = [clipData legacyDataHash];
        NSDictionary *legacy = [databaseManager clipItemWithDataHash:legacyHash];
        if (legacy) {
            RCClipData *original = [RCClipData clipDataFromPath:legacy[@"data_path"]];
            if (original && [clipData hasSamePayloadAsClipData:original]) {
                existingClipDict = legacy;
                dataHash = legacyHash;
            }
        }
    }
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
    return (clipData.HTMLData.length > 0
            || clipData.stringValue.length > 0
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

    if (clipData.HTMLData.length > 0) {
        hasSupportedType = YES;
        hasEnabledType = [self isStoreTypeEnabledForKey:@"HTML" inStoreTypes:storeTypes];
    }
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
    __block BOOL saved = NO;
    dispatch_sync(self.fileOperationQueue, ^{
        saved = [clipData saveToPath:path maximumArchiveSize:(NSUInteger)maxClipSizeBytes];
    });
    return saved;
}

// G3-011: CGImageSource でサムネイル生成。大きな画像でもメモリ効率が良い。
- (NSString *)generateThumbnailPathForClipData:(RCClipData *)clipData
                                     identifier:(NSString *)identifier
                                  directoryPath:(NSString *)directoryPath {
    if (identifier.length == 0 || directoryPath.length == 0) {
        return @"";
    }

    NSSize targetSize = [self thumbnailTargetSize];
    CGFloat maxDimension = MAX(targetSize.width, targetSize.height);
    if (maxDimension <= 0.0) {
        return @"";
    }

    // Keep a larger encrypted snapshot for hover, independently of file-copy data.
    NSImage *fileImage = [RCFileImagePreview imageForClip:clipData size:360];
    NSData *sourceData = fileImage ? fileImage.TIFFRepresentation : clipData.TIFFData;
    if (!sourceData.length) return @"";
    if (fileImage) maxDimension = 720;
    CGImageSourceRef imageSource = CGImageSourceCreateWithData((__bridge CFDataRef)sourceData,
        (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCache: @NO});
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
        wrote = [RCStorageMigration validatePrivateDirectory:directoryPath create:NO]
            && [[RCStorageCipher shared] writeData:thumbnailData toPath:thumbnailPath error:&error];
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
        NSString *root = [RCUtilities clipDataDirectoryPath].stringByStandardizingPath;
        if (![RCStorageMigration validatePrivateDirectory:root create:NO]
            || ![path.stringByStandardizingPath.stringByDeletingLastPathComponent isEqualToString:root]) return;
        struct stat file;
        if (lstat(path.fileSystemRepresentation, &file) != 0 || !S_ISREG(file.st_mode) || file.st_nlink != 1) return;
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
