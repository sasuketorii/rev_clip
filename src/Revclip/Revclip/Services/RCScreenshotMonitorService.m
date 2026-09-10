//
//  RCScreenshotMonitorService.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import "RCScreenshotMonitorService.h"

#import <Cocoa/Cocoa.h>
#import <os/log.h>

#import "RCConstants.h"
#import "RCClipData.h"
#import "RCClipItem.h"
#import "RCClipboardService.h"
#import "RCDataCleanService.h"
#import "RCDatabaseManager.h"
#import "RCPanicEraseService.h"
#import "RCUtilities.h"
#import "NSImage+Resize.h"

static NSString * const kRCMetadataItemIsScreenCapture = @"kMDItemIsScreenCapture";
static NSString * const kRCMetadataItemFSCreationDate = @"kMDItemFSCreationDate";
static NSString * const kRCMetadataItemPath = @"kMDItemPath";
static NSString * const kRCScreenshotClipDataFileExtension = @"rcclip";
static NSString * const kRCScreenCaptureDefaultsDomain = @"com.apple.screencapture";
static NSString * const kRCScreenCaptureLocationKey = @"location";
static NSInteger const kRCDefaultMaxClipSizeBytes = 52428800;

static os_log_t RCScreenshotMonitorServiceLog(void) {
    static os_log_t logger = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        logger = os_log_create("com.revclip", "RCScreenshotMonitorService");
    });
    return logger;
}

@interface RCScreenshotMonitorService ()
@property (nonatomic, strong, nullable) NSMetadataQuery *metadataQuery;
@property (nonatomic, assign, getter=isMonitoring) BOOL monitoring;
@property (nonatomic, strong, nullable) NSDate *monitoringStartDate;
@property (nonatomic, strong) dispatch_queue_t screenshotImportQueue;

- (NSArray<NSString *> *)extractProcessableScreenshotPathsFromMetadataItems:(NSArray<NSMetadataItem *> *)items
                                                           monitoringStartDate:(nullable NSDate *)monitoringStartDate;
- (void)enqueueScreenshotImportsForPaths:(NSArray<NSString *> *)filePaths;
- (BOOL)shouldHandleCreationDate:(nullable NSDate *)creationDate monitoringStartDate:(nullable NSDate *)monitoringStartDate;
- (BOOL)isSupportedScreenshotPath:(NSString *)filePath;
- (NSString *)defaultDesktopDirectoryPath;
- (NSString *)screenshotDirectoryPath;
@end

@implementation RCScreenshotMonitorService

+ (instancetype)shared {
    static RCScreenshotMonitorService *sharedService = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedService = [[self alloc] init];
    });
    return sharedService;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _screenshotImportQueue = dispatch_queue_create("com.revclip.screenshot-import", DISPATCH_QUEUE_SERIAL);
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleUserDefaultsDidChange:)
                                                     name:NSUserDefaultsDidChangeNotification
                                                   object:[NSUserDefaults standardUserDefaults]];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSUserDefaultsDidChangeNotification
                                                  object:[NSUserDefaults standardUserDefaults]];
    [self stopMonitoring];
}

#pragma mark - Public

- (void)startMonitoring {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self startMonitoring];
        });
        return;
    }

    if (![[NSUserDefaults standardUserDefaults] boolForKey:kRCBetaObserveScreenshot]) {
        return;
    }

    if (self.monitoring) {
        return;
    }

    NSMetadataQuery *query = [[NSMetadataQuery alloc] init];
    query.predicate = [NSPredicate predicateWithFormat:@"%K == 1", kRCMetadataItemIsScreenCapture];
    NSString *screenshotDirectoryPath = [self screenshotDirectoryPath];
    query.searchScopes = screenshotDirectoryPath.length > 0
        ? @[screenshotDirectoryPath]
        : @[[self defaultDesktopDirectoryPath]];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleMetadataQueryUpdate:)
                                                 name:NSMetadataQueryDidUpdateNotification
                                               object:query];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleMetadataQueryGatherComplete:)
                                                 name:NSMetadataQueryDidFinishGatheringNotification
                                               object:query];

    self.metadataQuery = query;
    self.monitoringStartDate = [NSDate date];

    if (![query startQuery]) {
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:NSMetadataQueryDidUpdateNotification
                                                      object:query];
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:NSMetadataQueryDidFinishGatheringNotification
                                                      object:query];
        self.metadataQuery = nil;
        self.monitoringStartDate = nil;
        return;
    }

    self.monitoring = YES;
}

- (void)stopMonitoring {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self stopMonitoring];
        });
        return;
    }

    if (self.metadataQuery != nil) {
        [self.metadataQuery stopQuery];
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:NSMetadataQueryDidUpdateNotification
                                                      object:self.metadataQuery];
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:NSMetadataQueryDidFinishGatheringNotification
                                                      object:self.metadataQuery];
    }

    self.metadataQuery = nil;
    self.monitoringStartDate = nil;
    self.monitoring = NO;
}

- (void)flushQueueWithCompletion:(void(^)(void))completion {
    dispatch_async(self.screenshotImportQueue, ^{
        if (completion != nil) {
            completion();
        }
    });
}

#pragma mark - Private

- (void)handleUserDefaultsDidChange:(NSNotification *)notification {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self handleUserDefaultsDidChange:notification];
        });
        return;
    }

    BOOL shouldObserveScreenshot = [[NSUserDefaults standardUserDefaults] boolForKey:kRCBetaObserveScreenshot];
    if (shouldObserveScreenshot) {
        [self startMonitoring];
    } else {
        [self stopMonitoring];
    }
}

- (void)handleMetadataQueryUpdate:(NSNotification *)notification {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self handleMetadataQueryUpdate:notification];
        });
        return;
    }

    if (self.metadataQuery == nil || notification.object != self.metadataQuery) {
        return;
    }

    [self.metadataQuery disableUpdates];

    @try {
        NSArray<NSMetadataItem *> *addedItems = notification.userInfo[NSMetadataQueryUpdateAddedItemsKey];
        if (![addedItems isKindOfClass:[NSArray class]] || addedItems.count == 0) {
            return;
        }

        NSDate *monitoringStartDate = self.monitoringStartDate;
        NSArray<NSString *> *filePaths = [self extractProcessableScreenshotPathsFromMetadataItems:addedItems
                                                                                 monitoringStartDate:monitoringStartDate];
        [self enqueueScreenshotImportsForPaths:filePaths];
    } @finally {
        [self.metadataQuery enableUpdates];
    }
}

- (void)handleMetadataQueryGatherComplete:(NSNotification *)notification {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self handleMetadataQueryGatherComplete:notification];
        });
        return;
    }

    if (self.metadataQuery == nil || notification.object != self.metadataQuery) {
        return;
    }

    [self.metadataQuery disableUpdates];

    @try {
        NSMutableArray<NSMetadataItem *> *items = [NSMutableArray arrayWithCapacity:self.metadataQuery.resultCount];
        for (NSUInteger index = 0; index < self.metadataQuery.resultCount; index++) {
            id itemObject = [self.metadataQuery resultAtIndex:index];
            if (![itemObject isKindOfClass:[NSMetadataItem class]]) {
                continue;
            }

            [items addObject:(NSMetadataItem *)itemObject];
        }

        NSDate *monitoringStartDate = self.monitoringStartDate;
        NSArray<NSString *> *filePaths = [self extractProcessableScreenshotPathsFromMetadataItems:items
                                                                                 monitoringStartDate:monitoringStartDate];
        [self enqueueScreenshotImportsForPaths:filePaths];
    } @finally {
        [self.metadataQuery enableUpdates];
    }
}

- (NSArray<NSString *> *)extractProcessableScreenshotPathsFromMetadataItems:(NSArray<NSMetadataItem *> *)items
                                                           monitoringStartDate:(nullable NSDate *)monitoringStartDate {
    NSMutableArray<NSString *> *filePaths = [NSMutableArray arrayWithCapacity:items.count];

    for (id itemObject in items) {
        if (![itemObject isKindOfClass:[NSMetadataItem class]]) {
            continue;
        }

        NSMetadataItem *item = (NSMetadataItem *)itemObject;
        NSDate *creationDate = [item valueForAttribute:kRCMetadataItemFSCreationDate];
        if (![self shouldHandleCreationDate:creationDate monitoringStartDate:monitoringStartDate]) {
            continue;
        }

        NSString *filePath = [item valueForAttribute:kRCMetadataItemPath];
        if (![filePath isKindOfClass:[NSString class]] || filePath.length == 0) {
            continue;
        }
        if (![self isSupportedScreenshotPath:filePath]) {
            continue;
        }
        [filePaths addObject:filePath];
    }

    return [filePaths copy];
}

- (void)enqueueScreenshotImportsForPaths:(NSArray<NSString *> *)filePaths {
    if (filePaths.count == 0) {
        return;
    }

    dispatch_async(self.screenshotImportQueue, ^{
        for (NSString *filePath in filePaths) {
            [self saveScreenshotToClipHistory:filePath];
        }
    });
}

- (BOOL)shouldHandleCreationDate:(nullable NSDate *)creationDate monitoringStartDate:(nullable NSDate *)monitoringStartDate {
    if (![creationDate isKindOfClass:[NSDate class]]) {
        return NO;
    }

    if (![monitoringStartDate isKindOfClass:[NSDate class]]) {
        return NO;
    }

    return [creationDate compare:monitoringStartDate] == NSOrderedDescending;
}

- (BOOL)isSupportedScreenshotPath:(NSString *)filePath {
    NSString *fileExtension = filePath.pathExtension.lowercaseString;
    return [fileExtension isEqualToString:@"png"]
        || [fileExtension isEqualToString:@"jpg"]
        || [fileExtension isEqualToString:@"jpeg"]
        || [fileExtension isEqualToString:@"heic"]
        || [fileExtension isEqualToString:@"pdf"]
        || [fileExtension isEqualToString:@"tiff"]
        || [fileExtension isEqualToString:@"tif"];
}

- (NSString *)defaultDesktopDirectoryPath {
    NSArray<NSString *> *desktopPaths = NSSearchPathForDirectoriesInDomains(NSDesktopDirectory, NSUserDomainMask, YES);
    NSString *desktopPath = desktopPaths.firstObject;
    if (![desktopPath isKindOfClass:[NSString class]] || desktopPath.length == 0) {
        desktopPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Desktop"];
    }

    return [desktopPath stringByStandardizingPath];
}

- (NSString *)screenshotDirectoryPath {
    NSString *desktopPath = [self defaultDesktopDirectoryPath];

    CFPropertyListRef locationValue = CFPreferencesCopyAppValue((__bridge CFStringRef)kRCScreenCaptureLocationKey,
                                                                (__bridge CFStringRef)kRCScreenCaptureDefaultsDomain);
    if (locationValue == NULL) {
        return desktopPath;
    }

    NSString *configuredPath = @"";
    if (CFGetTypeID(locationValue) == CFStringGetTypeID()) {
        configuredPath = [(__bridge NSString *)locationValue copy];
    }
    CFRelease(locationValue);

    configuredPath = [configuredPath stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (configuredPath.length == 0) {
        return desktopPath;
    }

    NSString *expandedPath = [configuredPath stringByExpandingTildeInPath];
    if (![expandedPath isAbsolutePath]) {
        expandedPath = [NSHomeDirectory() stringByAppendingPathComponent:expandedPath];
    }

    return [expandedPath stringByStandardizingPath];
}

/// Saves the screenshot at the given path directly into clip history
/// without overwriting the user's current clipboard contents.
- (void)saveScreenshotToClipHistory:(NSString *)filePath {
    if ([RCPanicEraseService shared].isPanicInProgress) {
        return;
    }

    NSData *imageData = [NSData dataWithContentsOfFile:filePath];
    if (imageData.length == 0) {
        return;
    }

    NSImage *image = [[NSImage alloc] initWithData:imageData];
    if (image == nil) {
        return;
    }

    // Convert to TIFF data, which is how RCClipboardService stores images
    NSData *tiffData = [image TIFFRepresentation];
    if (tiffData.length == 0) {
        return;
    }

    // Build an RCClipData representing this screenshot image
    RCClipData *clipData = [[RCClipData alloc] init];
    clipData.TIFFData = tiffData;
    clipData.primaryType = NSPasteboardTypeTIFF;

    NSString *dataHash = [clipData dataHash];
    if (dataHash.length == 0) {
        return;
    }

    RCDatabaseManager *databaseManager = [RCDatabaseManager shared];
    if (![databaseManager setupDatabase]) {
        return;
    }

    NSInteger updateTime = (NSInteger)([[NSDate date] timeIntervalSince1970] * 1000.0);

    // If an identical screenshot already exists in history, just update its timestamp
    NSDictionary *existingClipDict = [databaseManager clipItemWithDataHash:dataHash];
    if (existingClipDict != nil) {
        if ([databaseManager updateClipItemUpdateTime:dataHash time:updateTime]) {
            NSMutableDictionary *updatedDict = [existingClipDict mutableCopy];
            updatedDict[@"update_time"] = @(updateTime);
            RCClipItem *updatedItem = [[RCClipItem alloc] initWithDictionary:updatedDict];
            [self postClipboardDidChangeNotificationWithClipItem:updatedItem];
        }
        return;
    }

    // Ensure the clip data directory exists
    NSString *directoryPath = [RCUtilities clipDataDirectoryPath];
    if (![RCUtilities ensureDirectoryExists:directoryPath]) {
        return;
    }

    // Save clip data to file
    NSString *identifier = [NSUUID UUID].UUIDString;
    NSString *dataFileName = [NSString stringWithFormat:@"%@.%@", identifier, kRCScreenshotClipDataFileExtension];
    NSString *dataPath = [directoryPath stringByAppendingPathComponent:dataFileName];

    NSError *archiveError = nil;
    NSData *archivedData = [NSKeyedArchiver archivedDataWithRootObject:clipData
                                                  requiringSecureCoding:YES
                                                                  error:&archiveError];
    if (archivedData == nil) {
        os_log_error(RCScreenshotMonitorServiceLog(),
                     "Failed to archive screenshot clip data before size check (%{private}@)",
                     archiveError.localizedDescription);
        return;
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
        os_log_debug(RCScreenshotMonitorServiceLog(),
                     "Skipping screenshot save because archived data size (%lu bytes) exceeds limit (%ld bytes)",
                     (unsigned long)archivedData.length,
                     (long)maxClipSizeBytes);
        return;
    }

    if (![clipData saveToPath:dataPath]) {
        return;
    }

    // Generate thumbnail
    NSString *thumbnailPath = [self generateThumbnailForImage:image
                                                   identifier:identifier
                                                directoryPath:directoryPath];

    NSDictionary *clipDictionary = @{
        @"data_path": dataPath,
        @"title": [clipData title] ?: @"",
        @"data_hash": dataHash,
        @"primary_type": clipData.primaryType ?: @"",
        @"update_time": @(updateTime),
        @"thumbnail_path": thumbnailPath ?: @"",
        @"is_color_code": @(NO),
    };

    if (![databaseManager insertClipItem:clipDictionary]) {
        [RCPanicEraseService secureOverwriteFileAtPath:dataPath];
        [[NSFileManager defaultManager] removeItemAtPath:dataPath error:nil];
        if (thumbnailPath.length > 0) {
            [RCPanicEraseService secureOverwriteFileAtPath:thumbnailPath];
            [[NSFileManager defaultManager] removeItemAtPath:thumbnailPath error:nil];
        }
        return;
    }

    RCClipItem *clipItem = [[RCClipItem alloc] initWithDictionary:clipDictionary];
    [[RCDataCleanService shared] scheduleDebouncedCleanup];
    [self postClipboardDidChangeNotificationWithClipItem:clipItem];
}

- (NSString *)generateThumbnailForImage:(NSImage *)image
                             identifier:(NSString *)identifier
                          directoryPath:(NSString *)directoryPath {
    if (image == nil || identifier.length == 0 || directoryPath.length == 0) {
        return @"";
    }

    CGFloat width = MIN(512.0, MAX(16.0, [[NSUserDefaults standardUserDefaults] doubleForKey:kRCThumbnailWidthKey]));
    CGFloat height = MIN(512.0, MAX(16.0, [[NSUserDefaults standardUserDefaults] doubleForKey:kRCThumbnailHeightKey]));
    NSSize targetSize = NSMakeSize(width, height);
    NSImage *thumbnailImage = [image resizedImageToFitSize:targetSize];
    if (thumbnailImage == nil) {
        thumbnailImage = [image resizedImageToSize:targetSize];
    }
    if (thumbnailImage == nil) {
        return @"";
    }

    NSData *thumbnailTIFFData = [thumbnailImage TIFFRepresentation];
    if (thumbnailTIFFData.length == 0) {
        return @"";
    }

    NSBitmapImageRep *bitmapRep = [[NSBitmapImageRep alloc] initWithData:thumbnailTIFFData];
    if (bitmapRep == nil) {
        return @"";
    }

    NSData *thumbnailData = [bitmapRep representationUsingType:NSBitmapImageFileTypeJPEG
                                                    properties:@{ NSImageCompressionFactor: @0.7 }];
    if (thumbnailData.length == 0) {
        return @"";
    }

    NSString *thumbnailFileName = [NSString stringWithFormat:@"%@.thumbnail.tiff", identifier];
    NSString *thumbnailPath = [directoryPath stringByAppendingPathComponent:thumbnailFileName];

    NSError *error = nil;
    BOOL wrote = [thumbnailData writeToFile:thumbnailPath options:NSDataWritingAtomic error:&error];
    if (!wrote) {
        os_log_error(RCScreenshotMonitorServiceLog(),
                     "Failed to save thumbnail at path %{private}@ (%{private}@)",
                     thumbnailPath, error.localizedDescription);
        return @"";
    }

    NSError *permissionError = nil;
    BOOL permissionApplied = [[NSFileManager defaultManager] setAttributes:@{ NSFilePosixPermissions: @(0600) }
                                                               ofItemAtPath:thumbnailPath
                                                                      error:&permissionError];
    if (!permissionApplied && permissionError != nil) {
        os_log_error(RCScreenshotMonitorServiceLog(),
                     "Failed to set thumbnail permissions at path %{private}@ (%{private}@)",
                     thumbnailPath, permissionError.localizedDescription);
    }

    return thumbnailPath;
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
