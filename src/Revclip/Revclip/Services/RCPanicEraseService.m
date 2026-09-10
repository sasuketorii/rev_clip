#import "RCPanicEraseService.h"

#import <Cocoa/Cocoa.h>
#import <os/log.h>

#import "RCClipboardService.h"
#import "RCConstants.h"
#import "RCDataCleanService.h"
#import "RCDatabaseManager.h"
#import "RCHotKeyService.h"
#import "RCMenuManager.h"
#import "RCScreenshotMonitorService.h"
#import "RCUtilities.h"

static os_log_t RCPanicEraseServiceLog(void) {
    static os_log_t logger = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        logger = os_log_create("com.revclip", "RCPanicEraseService");
    });
    return logger;
}

@interface RCPanicEraseService ()

@property (atomic, assign, readwrite) BOOL isPanicInProgress;
@property (nonatomic, strong) dispatch_queue_t panicQueue;

- (void)overwriteAndDeleteClipFiles;
- (void)overwriteFileWithZerosAtPath:(NSString *)path fileManager:(NSFileManager *)fileManager;

@end

@implementation RCPanicEraseService

+ (instancetype)shared {
    static RCPanicEraseService *sharedService = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedService = [[self alloc] init];
    });
    return sharedService;
}

+ (void)secureOverwriteFileAtPath:(NSString *)path {
    [[RCPanicEraseService shared] overwriteFileWithZerosAtPath:path
                                                   fileManager:[NSFileManager defaultManager]];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isPanicInProgress = NO;
        _panicQueue = dispatch_queue_create("com.revclip.panic", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)executePanicEraseWithCompletion:(nullable void(^)(BOOL success))completion {
    dispatch_async(self.panicQueue, ^{
        if (self.isPanicInProgress) {
            if (completion != nil) {
                completion(NO);
            }
            return;
        }

        self.isPanicInProgress = YES;

        dispatch_sync(dispatch_get_main_queue(), ^{
            [[RCClipboardService shared] stopMonitoring];
            [[RCScreenshotMonitorService shared] stopMonitoring];
            [[RCDataCleanService shared] stopCleanupTimer];
            [[RCHotKeyService shared] unregisterAllHotKeys];
        });

        dispatch_group_t flushGroup = dispatch_group_create();

        dispatch_group_enter(flushGroup);
        [[RCClipboardService shared] flushQueueWithCompletion:^{
            dispatch_group_leave(flushGroup);
        }];

        dispatch_group_enter(flushGroup);
        [[RCScreenshotMonitorService shared] flushQueueWithCompletion:^{
            dispatch_group_leave(flushGroup);
        }];

        dispatch_group_enter(flushGroup);
        [[RCDataCleanService shared] flushQueueWithCompletion:^{
            dispatch_group_leave(flushGroup);
        }];

        dispatch_group_wait(flushGroup,
                            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));

        [self overwriteAndDeleteClipFiles];

        RCDatabaseManager *databaseManager = [RCDatabaseManager shared];
        BOOL clipsDeleted = [databaseManager panicDeleteAllClipItems];
        BOOL snippetsDeleted = [databaseManager panicDeleteAllSnippets];
        if (!clipsDeleted || !snippetsDeleted) {
            os_log_error(RCPanicEraseServiceLog(),
                         "Panic: some DB rows could not be deleted (clips=%d, snippets=%d)",
                         clipsDeleted, snippetsDeleted);
        }
        [databaseManager closeDatabase];
        [databaseManager deleteDatabaseFiles];
        [databaseManager reinitializeDatabase];

        if ([NSThread isMainThread]) {
            [[NSPasteboard generalPasteboard] clearContents];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                [[NSPasteboard generalPasteboard] clearContents];
            });
        }

        [[RCMenuManager shared] clearThumbnailCache];

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSString *bundleIdentifier = [NSBundle mainBundle].bundleIdentifier;
        if (bundleIdentifier.length > 0) {
            [defaults removePersistentDomainForName:bundleIdentifier];
        }
        [defaults synchronize];

        dispatch_async(dispatch_get_main_queue(), ^{
            [NSApp terminate:nil];
        });

        if (completion != nil) {
            completion(YES);
        }
    });
}

- (void)overwriteAndDeleteClipFiles {
    NSString *applicationSupportPath = [RCUtilities applicationSupportPath];
    if (applicationSupportPath.length == 0) {
        return;
    }

    NSString *clipsDirectoryPath = [[applicationSupportPath stringByAppendingPathComponent:@"ClipsData"] stringByStandardizingPath];
    if (clipsDirectoryPath.length == 0) {
        return;
    }

    NSString *canonicalBase = [clipsDirectoryPath stringByResolvingSymlinksInPath];
    if (canonicalBase.length == 0) {
        return;
    }

    if (![canonicalBase hasSuffix:@"/"]) {
        canonicalBase = [canonicalBase stringByAppendingString:@"/"];
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSDirectoryEnumerator<NSString *> *enumerator = [fileManager enumeratorAtPath:clipsDirectoryPath];
    for (NSString *relativePath in enumerator) {
        NSString *filePath = [clipsDirectoryPath stringByAppendingPathComponent:relativePath];
        NSString *canonicalPath = [filePath stringByResolvingSymlinksInPath];
        if (![canonicalPath hasPrefix:canonicalBase]) {
            continue;
        }

        BOOL isDirectory = NO;
        if (![fileManager fileExistsAtPath:filePath isDirectory:&isDirectory] || isDirectory) {
            continue;
        }

        NSDictionary<NSFileAttributeKey, id> *attributes = [fileManager attributesOfItemAtPath:filePath error:nil];
        NSString *fileType = [attributes[NSFileType] isKindOfClass:[NSString class]] ? attributes[NSFileType] : nil;
        if (![fileType isEqualToString:NSFileTypeRegular]) {
            continue;
        }

        [self overwriteFileWithZerosAtPath:filePath fileManager:fileManager];
        [fileManager removeItemAtPath:filePath error:nil];
    }
}

- (void)overwriteFileWithZerosAtPath:(NSString *)path fileManager:(NSFileManager *)fileManager {
    if (path.length == 0 || fileManager == nil) {
        return;
    }

    NSDictionary<NSFileAttributeKey, id> *attributes = [fileManager attributesOfItemAtPath:path error:nil];
    unsigned long long fileSize = [attributes[NSFileSize] respondsToSelector:@selector(unsignedLongLongValue)]
        ? [attributes[NSFileSize] unsignedLongLongValue]
        : 0;

    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fileHandle == nil) {
        return;
    }

    static NSUInteger const kRCZeroBufferSize = 1024 * 1024;
    NSMutableData *zeroBuffer = [NSMutableData dataWithLength:kRCZeroBufferSize];

    @try {
        [fileHandle seekToFileOffset:0];
        unsigned long long remaining = fileSize;
        while (remaining > 0) {
            NSUInteger currentChunkSize = (NSUInteger)MIN(remaining, (unsigned long long)kRCZeroBufferSize);
            NSData *chunkData = (currentChunkSize == kRCZeroBufferSize)
                ? zeroBuffer
                : [zeroBuffer subdataWithRange:NSMakeRange(0, currentChunkSize)];
            [fileHandle writeData:chunkData];
            remaining -= currentChunkSize;
        }
        [fileHandle synchronizeFile];
    } @catch (NSException *exception) {
        (void)exception;
    } @finally {
        [fileHandle closeFile];
    }
}

@end
