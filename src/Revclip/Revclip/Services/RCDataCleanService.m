//
//  RCDataCleanService.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import "RCDataCleanService.h"

#import "FMDB.h"
#import "RCClipItem.h"
#import "RCConstants.h"
#import "RCDatabaseManager.h"
#import "RCPanicEraseService.h"
#import "RCUtilities.h"
#import <CoreFoundation/CoreFoundation.h>
#import <os/log.h>

static NSTimeInterval const kRCCleanupInterval = 30.0 * 60.0;
static NSTimeInterval const kRCDebouncedCleanupInterval = 5.0;
static NSInteger const kRCDefaultMaxHistorySize = 30;
static NSInteger const kRCMaxAllowedHistorySize = 9999;
static NSInteger const kRCAutoExpiryDefaultValue = 30;
static NSInteger const kRCAutoExpiryMinimumValue = 1;
static NSInteger const kRCAutoExpiryMaximumValue = 9999;
static NSTimeInterval const kRCOrphanFileMinimumAge = 60.0;
static NSString * const kRCClipDataFileExtension = @"rcclip";
static NSString * const kRCThumbFileExtension = @"thumb";
static NSString * const kRCLegacyThumbnailFileExtension = @"thumbnail.tiff";
static NSString * const kRCThumbFileSuffix = @".thumb";
static NSString * const kRCLegacyThumbnailFileSuffix = @".thumbnail.tiff";

static os_log_t RCDataCleanServiceLog(void) {
    static os_log_t logger = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        logger = os_log_create("com.revclip", "RCDataCleanService");
    });
    return logger;
}

@interface RCDataCleanService ()

@property (nonatomic, strong, nullable) dispatch_source_t cleanupTimer;
@property (nonatomic, strong, nullable) dispatch_source_t cleanupDebounceTimer;
@property (nonatomic, strong) dispatch_queue_t cleanupQueue;

- (void)runDatabaseMaintenanceWithDatabaseManager:(RCDatabaseManager *)databaseManager;
- (BOOL)autoExpiryEnabledPreferenceValue;
- (NSInteger)autoExpiryValuePreference;
- (RCAutoExpiryUnit)autoExpiryUnitPreference;
- (NSString *)validatedCanonicalClipPath:(NSString *)path
                  clipDataDirectoryPath:(NSString *)canonicalClipDataDirectoryPath;
- (NSString *)resolvedPath:(NSString *)path;

@end

@implementation RCDataCleanService

+ (instancetype)shared {
    static RCDataCleanService *sharedService = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedService = [[self alloc] init];
    });
    return sharedService;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _cleanupQueue = dispatch_queue_create("com.revclip.data-cleanup", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    [self stopCleanupTimer];
}

- (void)startCleanupTimer {
    @synchronized (self) {
        if (self.cleanupTimer != nil) {
            return;
        }

        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.cleanupQueue);
        if (timer == nil) {
            return;
        }

        uint64_t interval = (uint64_t)(kRCCleanupInterval * (double)NSEC_PER_SEC);
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
            [strongSelf performCleanupOnCleanupQueue];
        });

        self.cleanupTimer = timer;
        dispatch_resume(timer);

        // G3-012: 初期 cleanup を @synchronized ブロック内で dispatch して
        // タイマー設定と初期クリーンアップの間に競合が発生しないようにする。
        dispatch_async(self.cleanupQueue, ^{
            [self performCleanupOnCleanupQueue];
        });
    }
}

- (void)stopCleanupTimer {
    dispatch_source_t timer = nil;
    dispatch_source_t debounceTimer = nil;

    @synchronized (self) {
        timer = self.cleanupTimer;
        self.cleanupTimer = nil;
        debounceTimer = self.cleanupDebounceTimer;
        self.cleanupDebounceTimer = nil;
    }

    if (timer != nil) {
        dispatch_source_cancel(timer);
    }
    if (debounceTimer != nil) {
        dispatch_source_cancel(debounceTimer);
    }
}

- (void)performCleanup {
    if ([RCPanicEraseService shared].isPanicInProgress) {
        return;
    }

    dispatch_async(self.cleanupQueue, ^{
        [self performCleanupOnCleanupQueue];
    });
}

- (void)scheduleDebouncedCleanup {
    if ([RCPanicEraseService shared].isPanicInProgress) {
        return;
    }

    dispatch_async(self.cleanupQueue, ^{
        @synchronized (self) {
            if (self.cleanupDebounceTimer != nil) {
                dispatch_source_cancel(self.cleanupDebounceTimer);
                self.cleanupDebounceTimer = nil;
            }

            dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.cleanupQueue);
            if (timer == nil) {
                return;
            }

            uint64_t interval = (uint64_t)(kRCDebouncedCleanupInterval * (double)NSEC_PER_SEC);
            uint64_t leeway = interval / 10;
            dispatch_source_set_timer(timer,
                                      dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval),
                                      DISPATCH_TIME_FOREVER,
                                      leeway);

            __weak typeof(self) weakSelf = self;
            dispatch_source_set_event_handler(timer, ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (strongSelf == nil) {
                    return;
                }

                @synchronized (strongSelf) {
                    if (strongSelf.cleanupDebounceTimer != timer) {
                        return;
                    }
                    strongSelf.cleanupDebounceTimer = nil;
                }

                dispatch_source_cancel(timer);
                [strongSelf performCleanupOnCleanupQueue];
            });

            self.cleanupDebounceTimer = timer;
            dispatch_resume(timer);
        }
    });
}

- (void)flushQueueWithCompletion:(void(^)(void))completion {
    dispatch_async(self.cleanupQueue, ^{
        if (completion != nil) {
            completion();
        }
    });
}

#pragma mark - Private

- (void)performCleanupOnCleanupQueue {
    if ([RCPanicEraseService shared].isPanicInProgress) {
        return;
    }

    RCDatabaseManager *databaseManager = [RCDatabaseManager shared];
    if (![databaseManager setupDatabase]) {
        return;
    }

    [self expireHistoryIfNeededWithDatabaseManager:databaseManager];
    [self trimHistoryIfNeededWithDatabaseManager:databaseManager];
    [self removeOrphanClipFilesWithDatabaseManager:databaseManager];
    [self runDatabaseMaintenanceWithDatabaseManager:databaseManager];
}

- (void)expireHistoryIfNeededWithDatabaseManager:(RCDatabaseManager *)databaseManager {
    if ([RCPanicEraseService shared].isPanicInProgress) {
        return;
    }

    if (![self autoExpiryEnabledPreferenceValue]) {
        return;
    }

    NSInteger expiryValue = [self autoExpiryValuePreference];
    RCAutoExpiryUnit expiryUnit = [self autoExpiryUnitPreference];

    NSInteger expiryDurationMs = 0;
    switch (expiryUnit) {
        case RCAutoExpiryUnitHour:
            expiryDurationMs = expiryValue * 3600 * 1000;
            break;
        case RCAutoExpiryUnitMinute:
            expiryDurationMs = expiryValue * 60 * 1000;
            break;
        case RCAutoExpiryUnitDay:
        default:
            expiryDurationMs = expiryValue * 86400 * 1000;
            break;
    }

    NSInteger nowMs = (NSInteger)([[NSDate date] timeIntervalSince1970] * 1000.0);
    NSInteger cutoffMs = nowMs - expiryDurationMs;
    NSArray<RCClipItem *> *expiredItems = [databaseManager clipItemsOlderThan:cutoffMs];
    for (RCClipItem *expiredItem in expiredItems) {
        if (expiredItem.dataHash.length == 0) {
            continue;
        }

        if ([databaseManager deleteClipItemWithDataHash:expiredItem.dataHash olderThan:cutoffMs]) {
            [self removeFilesForClipItem:expiredItem];
        }
    }
}

- (void)trimHistoryIfNeededWithDatabaseManager:(RCDatabaseManager *)databaseManager {
    if ([RCPanicEraseService shared].isPanicInProgress) {
        return;
    }

    NSInteger maxHistorySize = [self integerPreferenceForKey:kRCPrefMaxHistorySizeKey
                                                defaultValue:kRCDefaultMaxHistorySize];
    if (maxHistorySize <= 0) {
        maxHistorySize = kRCDefaultMaxHistorySize;
    }
    if (maxHistorySize > kRCMaxAllowedHistorySize) {
        maxHistorySize = kRCMaxAllowedHistorySize;
    }

    NSInteger count = [databaseManager clipItemCount];
    if (count <= maxHistorySize) {
        return;
    }

    NSArray<NSDictionary *> *clipDictionaries = [databaseManager fetchClipItemsWithLimit:count];
    if (clipDictionaries.count <= (NSUInteger)maxHistorySize) {
        return;
    }

    for (NSUInteger index = clipDictionaries.count; index > (NSUInteger)maxHistorySize; index--) {
        RCClipItem *oldItem = [[RCClipItem alloc] initWithDictionary:clipDictionaries[index - 1]];
        if (oldItem.dataHash.length == 0) {
            continue;
        }

        if ([databaseManager deleteClipItemWithDataHash:oldItem.dataHash]) {
            [self removeFilesForClipItem:oldItem];
        }
    }
}

- (void)runDatabaseMaintenanceWithDatabaseManager:(RCDatabaseManager *)databaseManager {
    [databaseManager performDatabaseOperation:^BOOL(FMDatabase *db) {
        BOOL vacuumed = [db executeStatements:@"PRAGMA incremental_vacuum;"];
        if (!vacuumed) {
            os_log_error(RCDataCleanServiceLog(), "Failed to execute incremental_vacuum pragma");
            return NO;
        }

        NSString *journalMode = [[db stringForQuery:@"PRAGMA journal_mode;"] lowercaseString];
        if ([journalMode isEqualToString:@"wal"]) {
            BOOL checkpointed = [db executeStatements:@"PRAGMA wal_checkpoint(TRUNCATE);"];
            if (!checkpointed) {
                os_log_error(RCDataCleanServiceLog(), "Failed to execute wal_checkpoint(TRUNCATE) pragma");
                return NO;
            }
        }

        return YES;
    }];
}

- (void)removeOrphanClipFilesWithDatabaseManager:(RCDatabaseManager *)databaseManager {
    NSString *clipDirectoryPath = [RCUtilities clipDataDirectoryPath];
    if (![RCUtilities ensureDirectoryExists:clipDirectoryPath]) {
        return;
    }
    NSString *canonicalClipDataDirectoryPath = [self canonicalPath:clipDirectoryPath];
    if (canonicalClipDataDirectoryPath.length == 0) {
        return;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *directoryError = nil;
    NSArray<NSString *> *fileNames = [fileManager contentsOfDirectoryAtPath:clipDirectoryPath
                                                                       error:&directoryError];
    if (fileNames == nil) {
        os_log_error(RCDataCleanServiceLog(),
                     "Failed to enumerate clip directory %{private}@ (%{private}@)",
                     clipDirectoryPath, directoryError.localizedDescription);
        return;
    }

    NSMutableSet<NSString *> *databaseClipPaths = [NSMutableSet set];
    NSMutableSet<NSString *> *databaseThumbnailPaths = [NSMutableSet set];
    NSInteger count = [databaseManager clipItemCount];
    if (count > 0) {
        NSArray<NSDictionary *> *clipDictionaries = [databaseManager fetchClipItemsWithLimit:count];
        for (NSDictionary *clipDictionary in clipDictionaries) {
            RCClipItem *clipItem = [[RCClipItem alloc] initWithDictionary:clipDictionary];
            NSString *canonicalDataPath = [self validatedCanonicalClipPath:clipItem.dataPath
                                                     clipDataDirectoryPath:canonicalClipDataDirectoryPath];
            if (canonicalDataPath.length > 0) {
                [databaseClipPaths addObject:canonicalDataPath];
            }

            NSString *canonicalThumbnailPath = [self validatedCanonicalClipPath:clipItem.thumbnailPath
                                                          clipDataDirectoryPath:canonicalClipDataDirectoryPath];
            if (canonicalThumbnailPath.length > 0) {
                [databaseThumbnailPaths addObject:canonicalThumbnailPath];
            }
        }
    }

    for (NSString *fileName in fileNames) {
        if (![self isClipDataFileName:fileName]) {
            continue;
        }

        NSString *clipFilePath = [self validatedCanonicalClipPath:[clipDirectoryPath stringByAppendingPathComponent:fileName]
                                            clipDataDirectoryPath:canonicalClipDataDirectoryPath];
        if (clipFilePath.length == 0) {
            continue;
        }

        if ([databaseClipPaths containsObject:clipFilePath]) {
            continue;
        }

        if (![self isOldEnoughForOrphanDeletionAtPath:clipFilePath fileManager:fileManager]) {
            continue;
        }

        [self removeFileAtPath:clipFilePath];
        [self removeCompanionThumbFilesForClipPath:clipFilePath];
    }

    for (NSString *fileName in fileNames) {
        if (![self isThumbnailFileName:fileName]) {
            continue;
        }

        NSString *thumbnailFilePath = [self validatedCanonicalClipPath:[clipDirectoryPath stringByAppendingPathComponent:fileName]
                                                 clipDataDirectoryPath:canonicalClipDataDirectoryPath];
        if (thumbnailFilePath.length == 0) {
            continue;
        }

        if ([databaseThumbnailPaths containsObject:thumbnailFilePath]) {
            continue;
        }

        NSString *correspondingClipPath = [self validatedCanonicalClipPath:[self clipPathForThumbnailFileName:fileName
                                                                                            clipDirectoryPath:clipDirectoryPath]
                                                     clipDataDirectoryPath:canonicalClipDataDirectoryPath];
        if (correspondingClipPath.length > 0 && [databaseClipPaths containsObject:correspondingClipPath]) {
            continue;
        }
        if (correspondingClipPath.length > 0 && [self isRegularFileAtPath:correspondingClipPath fileManager:fileManager]) {
            continue;
        }

        if (![self isOldEnoughForOrphanDeletionAtPath:thumbnailFilePath fileManager:fileManager]) {
            continue;
        }

        [self removeFileAtPath:thumbnailFilePath];
    }
}

- (void)removeFilesForClipItem:(RCClipItem *)clipItem {
    if (clipItem == nil) {
        return;
    }

    [self removeFileAtPath:clipItem.dataPath];
    [self removeFileAtPath:clipItem.thumbnailPath];
    [self removeCompanionThumbFilesForClipPath:clipItem.dataPath];
}

- (void)removeCompanionThumbFilesForClipPath:(NSString *)clipPath {
    NSString *standardizedClipPath = [self standardizedPath:clipPath];
    if (standardizedClipPath.length == 0) {
        return;
    }

    NSString *basePath = [standardizedClipPath stringByDeletingPathExtension];
    if (basePath.length == 0) {
        return;
    }

    NSString *thumbPath = [basePath stringByAppendingPathExtension:kRCThumbFileExtension];
    NSString *legacyThumbnailPath = [basePath stringByAppendingPathExtension:kRCLegacyThumbnailFileExtension];

    [self removeFileAtPath:thumbPath];
    [self removeFileAtPath:legacyThumbnailPath];
}

- (BOOL)isClipDataFileName:(NSString *)fileName {
    NSString *fileExtension = [[fileName pathExtension] lowercaseString];
    return [fileExtension isEqualToString:kRCClipDataFileExtension];
}

- (BOOL)isThumbnailFileName:(NSString *)fileName {
    NSString *lowercaseFileName = [fileName lowercaseString];
    return [lowercaseFileName hasSuffix:kRCThumbFileSuffix]
    || [lowercaseFileName hasSuffix:kRCLegacyThumbnailFileSuffix];
}

- (NSString *)clipPathForThumbnailFileName:(NSString *)thumbnailFileName
                         clipDirectoryPath:(NSString *)clipDirectoryPath {
    if (thumbnailFileName.length == 0 || clipDirectoryPath.length == 0) {
        return @"";
    }

    NSString *lowercaseFileName = [thumbnailFileName lowercaseString];
    NSString *baseFileName = nil;
    if ([lowercaseFileName hasSuffix:kRCThumbFileSuffix] && thumbnailFileName.length > kRCThumbFileSuffix.length) {
        baseFileName = [thumbnailFileName substringToIndex:(thumbnailFileName.length - kRCThumbFileSuffix.length)];
    } else if ([lowercaseFileName hasSuffix:kRCLegacyThumbnailFileSuffix]
               && thumbnailFileName.length > kRCLegacyThumbnailFileSuffix.length) {
        baseFileName = [thumbnailFileName substringToIndex:(thumbnailFileName.length - kRCLegacyThumbnailFileSuffix.length)];
    } else {
        return @"";
    }

    NSString *clipFileName = [baseFileName stringByAppendingPathExtension:kRCClipDataFileExtension];
    return [self standardizedPath:[clipDirectoryPath stringByAppendingPathComponent:clipFileName]];
}

- (BOOL)isRegularFileAtPath:(NSString *)path fileManager:(NSFileManager *)fileManager {
    NSString *standardizedPath = [self canonicalPath:path];
    if (standardizedPath.length == 0) {
        return NO;
    }

    BOOL isDirectory = NO;
    return [fileManager fileExistsAtPath:standardizedPath isDirectory:&isDirectory] && !isDirectory;
}

- (BOOL)isOldEnoughForOrphanDeletionAtPath:(NSString *)path fileManager:(NSFileManager *)fileManager {
    NSString *standardizedPath = [self canonicalPath:path];
    if (standardizedPath.length == 0) {
        return NO;
    }

    BOOL isDirectory = NO;
    if (![fileManager fileExistsAtPath:standardizedPath isDirectory:&isDirectory] || isDirectory) {
        return NO;
    }

    NSError *attributesError = nil;
    NSDictionary *attributes = [fileManager attributesOfItemAtPath:standardizedPath error:&attributesError];
    if (attributes == nil) {
        os_log_error(RCDataCleanServiceLog(),
                     "Failed to get file attributes for %{private}@ (%{private}@)",
                     standardizedPath, attributesError.localizedDescription);
        return NO;
    }

    NSDate *modifiedDate = attributes[NSFileModificationDate];
    if (![modifiedDate isKindOfClass:[NSDate class]]) {
        return NO;
    }

    NSTimeInterval age = [[NSDate date] timeIntervalSinceDate:modifiedDate];
    return age >= kRCOrphanFileMinimumAge;
}

- (void)removeFileAtPath:(NSString *)path {
    NSString *canonicalClipDataDirectoryPath = [self canonicalPath:[RCUtilities clipDataDirectoryPath]];
    NSString *canonicalPath = [self validatedCanonicalClipPath:path
                                         clipDataDirectoryPath:canonicalClipDataDirectoryPath];
    if (canonicalPath.length == 0) {
        os_log_with_type(RCDataCleanServiceLog(), OS_LOG_TYPE_DEBUG,
                         "Refusing to delete path outside clip data directory (%{private}@)",
                         path);
        return;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if (![fileManager fileExistsAtPath:canonicalPath isDirectory:&isDirectory] || isDirectory) {
        return;
    }

    [RCPanicEraseService secureOverwriteFileAtPath:canonicalPath];

    NSError *error = nil;
    BOOL removed = [fileManager removeItemAtPath:canonicalPath error:&error];
    if (!removed) {
        os_log_error(RCDataCleanServiceLog(),
                     "Failed to remove file %{private}@ (%{private}@)",
                     canonicalPath, error.localizedDescription);
    }
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

- (BOOL)autoExpiryEnabledPreferenceValue {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:kRCPrefAutoExpiryEnabledKey];
    if (value == nil) {
        return NO;
    }
    if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        return [(NSNumber *)value boolValue];
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value boolValue];
    }
    return NO;
}

- (NSInteger)autoExpiryValuePreference {
    NSInteger value = [self integerPreferenceForKey:kRCPrefAutoExpiryValueKey
                                       defaultValue:kRCAutoExpiryDefaultValue];
    if (value < kRCAutoExpiryMinimumValue || value > kRCAutoExpiryMaximumValue) {
        return kRCAutoExpiryDefaultValue;
    }
    return value;
}

- (RCAutoExpiryUnit)autoExpiryUnitPreference {
    NSInteger rawUnit = [self integerPreferenceForKey:kRCPrefAutoExpiryUnitKey
                                         defaultValue:RCAutoExpiryUnitDay];
    if (rawUnit < RCAutoExpiryUnitDay || rawUnit > RCAutoExpiryUnitMinute) {
        return RCAutoExpiryUnitDay;
    }
    return (RCAutoExpiryUnit)rawUnit;
}

- (NSString *)standardizedPath:(NSString *)path {
    if (path.length == 0) {
        return @"";
    }
    return [[path stringByExpandingTildeInPath] stringByStandardizingPath];
}

- (NSString *)resolvedPath:(NSString *)path {
    NSString *standardizedPath = [self standardizedPath:path];
    if (standardizedPath.length == 0) {
        return @"";
    }

    if (standardizedPath.isAbsolutePath) {
        return standardizedPath;
    }

    NSString *clipDataDirectoryPath = [self standardizedPath:[RCUtilities clipDataDirectoryPath]];
    if (clipDataDirectoryPath.length == 0) {
        return @"";
    }

    NSString *resolvedPath = [clipDataDirectoryPath stringByAppendingPathComponent:standardizedPath];
    return [resolvedPath stringByStandardizingPath];
}

- (NSString *)canonicalPath:(NSString *)path {
    NSString *resolvedPath = [self resolvedPath:path];
    if (resolvedPath.length == 0) {
        return @"";
    }

    return [resolvedPath stringByResolvingSymlinksInPath];
}

- (NSString *)validatedCanonicalClipPath:(NSString *)path
                  clipDataDirectoryPath:(NSString *)canonicalClipDataDirectoryPath {
    NSString *canonicalPath = [self canonicalPath:path];
    if (![self isPath:canonicalPath withinDirectory:canonicalClipDataDirectoryPath]) {
        return @"";
    }
    return canonicalPath;
}

- (BOOL)isPath:(NSString *)path withinDirectory:(NSString *)directoryPath {
    if (path.length == 0 || directoryPath.length == 0) {
        return NO;
    }

    if ([path isEqualToString:directoryPath]) {
        return YES;
    }

    NSString *directoryPrefix = [directoryPath hasSuffix:@"/"]
        ? directoryPath
        : [directoryPath stringByAppendingString:@"/"];
    return [path hasPrefix:directoryPrefix];
}

@end
