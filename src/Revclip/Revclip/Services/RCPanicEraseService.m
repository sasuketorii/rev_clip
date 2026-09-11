#import "RCPanicEraseService.h"

#import <Cocoa/Cocoa.h>
#import <errno.h>
#import <fcntl.h>
#import <os/log.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

#import "RCClipboardService.h"
#import "RCConstants.h"
#import "RCDataCleanService.h"
#import "RCDatabaseManager.h"
#import "RCHotKeyService.h"
#import "RCMenuManager.h"
#import "RCScreenshotMonitorService.h"
#import "RCStorageMigration.h"
#import "RCUtilities.h"
#import "Revclip-Swift.h"

enum { kRCPanicZeroBufferSize = 64 * 1024 };

static os_log_t RCPanicEraseServiceLog(void) {
    static os_log_t logger = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        logger = os_log_create("com.revclip", "RCPanicEraseService");
    });
    return logger;
}

/// Validate a storage root without resolving through a symbolic link. A
/// missing root is safe to treat as already erased; every existing component
/// used by panic erase must be a private directory owned by this user.
static BOOL RCPanicValidateDirectoryRoot(NSString *path, BOOL *exists) {
    if (exists != NULL) {
        *exists = NO;
    }
    if (path.length == 0) {
        return NO;
    }

    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) != 0) {
        if (errno == ENOENT) {
            return YES;
        }
        return NO;
    }

    if (exists != NULL) {
        *exists = YES;
    }
    if (!S_ISDIR(info.st_mode)
        || info.st_uid != getuid()
        || (info.st_mode & (S_IRWXG | S_IRWXO)) != 0) {
        return NO;
    }

    int descriptor = open(path.fileSystemRepresentation,
                          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) {
        return NO;
    }
    BOOL isStillDirectory = NO;
    struct stat descriptorInfo;
    if (fstat(descriptor, &descriptorInfo) == 0) {
        isStillDirectory = S_ISDIR(descriptorInfo.st_mode)
            && descriptorInfo.st_uid == getuid()
            && (descriptorInfo.st_mode & (S_IRWXG | S_IRWXO)) == 0
            && descriptorInfo.st_dev == info.st_dev
            && descriptorInfo.st_ino == info.st_ino;
    }
    close(descriptor);
    return isStillDirectory;
}

static void RCPanicLogFileFailure(NSString *operation, NSString *path, int errorCode) {
    os_log_error(RCPanicEraseServiceLog(),
                 "Panic: %{public}@ failed for %{private}@ (errno=%d, %{public}@)",
                 operation,
                 path,
                 errorCode,
                 [NSString stringWithUTF8String:strerror(errorCode)] ?: @"unknown error");
}

@interface RCPanicEraseService ()

@property (atomic, assign, readwrite) BOOL isPanicInProgress;
@property (atomic, assign, readwrite) BOOL isEraseAttemptActive;
@property (nonatomic, strong) dispatch_queue_t panicQueue;

- (void)stopProducers;
- (BOOL)drainProducerQueues;
- (BOOL)overwriteAndDeleteClipFiles;
- (BOOL)overwriteAndDeleteClipFilesAtApplicationSupportPath:(NSString *)applicationSupportPath;
- (BOOL)validatePanicClipStorageAtApplicationSupportPath:(NSString *)applicationSupportPath;
- (BOOL)validateEntriesInDirectoryAtPath:(NSString *)directoryPath
                             fileManager:(NSFileManager *)fileManager;
- (BOOL)overwriteEntriesInDirectoryAtPath:(NSString *)directoryPath fileManager:(NSFileManager *)fileManager;
- (BOOL)overwriteFileWithZerosAtPath:(NSString *)path fileManager:(NSFileManager *)fileManager;
- (BOOL)validateDatabaseFilesForManager:(RCDatabaseManager *)databaseManager
                        databaseExists:(BOOL *)databaseExists;
- (BOOL)deleteDatabaseFilesForManager:(RCDatabaseManager *)databaseManager;
- (void)completePanicEraseOnMainWithSuccess:(BOOL)success
                                 completion:(nullable void(^)(BOOL success))completion;
- (void)finishPanicEraseFailureWithCompletion:(nullable void(^)(BOOL success))completion;

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

+ (BOOL)secureOverwriteFileAtPath:(NSString *)path {
    return [[RCPanicEraseService shared] overwriteFileWithZerosAtPath:path
                                                            fileManager:[NSFileManager defaultManager]];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isPanicInProgress = NO;
        _isEraseAttemptActive = NO;
        _panicQueue = dispatch_queue_create("com.revclip.panic", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)executePanicEraseWithCompletion:(nullable void(^)(BOOL success))completion {
    @synchronized (self) {
        // Accept the request synchronously: Quit must see the barrier even
        // before the background worker gets its first timeslice.
        // isPanicInProgress deliberately remains set after a failed attempt:
        // it is the write barrier while monitoring is stopped. A separate
        // attempt flag lets the user retry after the failure is reported.
        if (self.isEraseAttemptActive) {
            [self completePanicEraseOnMainWithSuccess:NO completion:completion];
            return;
        }

        self.isEraseAttemptActive = YES;
        self.isPanicInProgress = YES;
    }
    dispatch_async(self.panicQueue, ^{
        [self stopProducers];
        BOOL queuesDrained = [self drainProducerQueues];
        if (!queuesDrained) {
            os_log_error(RCPanicEraseServiceLog(),
                         "Panic: one or more service queues did not drain before timeout");
            // No file, database, keychain, pasteboard, or defaults mutation is
            // allowed while a producer may still be writing.
            [self finishPanicEraseFailureWithCompletion:completion];
            return;
        }

        RCDatabaseManager *databaseManager = [RCDatabaseManager shared];
        NSString *applicationSupportPath = [RCUtilities applicationSupportPath];
        BOOL databaseExists = NO;
        if (![self validatePanicClipStorageAtApplicationSupportPath:applicationSupportPath]
            || ![self validateDatabaseFilesForManager:databaseManager
                                       databaseExists:&databaseExists]) {
            os_log_error(RCPanicEraseServiceLog(),
                         "Panic: storage preflight failed; no database rows or key were destroyed");
            [self finishPanicEraseFailureWithCompletion:completion];
            return;
        }

        // Validate all clip entries before changing database rows. The erase
        // pass validates again immediately before each open, so a symlink or
        // unsupported entry never turns into a reported success.
        BOOL clipFilesDeleted = [self overwriteAndDeleteClipFilesAtApplicationSupportPath:applicationSupportPath];
        if (!clipFilesDeleted) {
            os_log_error(RCPanicEraseServiceLog(),
                         "Panic: clip storage erase failed; database rows and key were retained");
            [self finishPanicEraseFailureWithCompletion:completion];
            return;
        }

        BOOL clipsDeleted = YES;
        BOOL snippetsDeleted = YES;
        if (databaseExists) {
            clipsDeleted = [databaseManager panicDeleteAllClipItems];
            snippetsDeleted = [databaseManager panicDeleteAllSnippets];
        }
        if (!clipsDeleted || !snippetsDeleted) {
            os_log_error(RCPanicEraseServiceLog(),
                         "Panic: some DB rows could not be deleted (clips=%d, snippets=%d)",
                         clipsDeleted, snippetsDeleted);
        }
        [databaseManager closeDatabase];
        BOOL databaseFilesDeleted = [self deleteDatabaseFilesForManager:databaseManager];

        NSError *keyError = nil;
        BOOL keyDeleted = [[RCStorageCipher shared] deleteKeyWithError:&keyError];
        if (!keyDeleted) {
            os_log_error(RCPanicEraseServiceLog(),
                         "Panic: storage key could not be destroyed (%{public}@)",
                         keyError.localizedDescription ?: @"unknown error");
        }

        __block BOOL pasteboardCleared = YES;
        if ([NSThread isMainThread]) {
            pasteboardCleared = [[NSPasteboard generalPasteboard] clearContents];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                pasteboardCleared = [[NSPasteboard generalPasteboard] clearContents];
            });
        }

        [[RCMenuManager shared] clearThumbnailCache];

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSString *bundleIdentifier = [NSBundle mainBundle].bundleIdentifier;
        if (bundleIdentifier.length > 0) {
            [defaults removePersistentDomainForName:bundleIdentifier];
        }
        BOOL defaultsSynchronized = [defaults synchronize];

        BOOL eraseSucceeded = queuesDrained
            && clipFilesDeleted
            && clipsDeleted
            && snippetsDeleted
            && databaseFilesDeleted
            && keyDeleted
            && pasteboardCleared
            && defaultsSynchronized;
        if (!eraseSucceeded) {
            os_log_error(RCPanicEraseServiceLog(),
                         "Panic: erase did not complete successfully (queues=%d, files=%d, clipRows=%d, snippetRows=%d, databaseFiles=%d, key=%d, pasteboard=%d, defaults=%d)",
                         queuesDrained,
                         clipFilesDeleted,
                         clipsDeleted,
                         snippetsDeleted,
                         databaseFilesDeleted,
                         keyDeleted,
                         pasteboardCleared,
                         defaultsSynchronized);
        }

        if (!eraseSucceeded) {
            [self finishPanicEraseFailureWithCompletion:completion];
        } else {
            [self completePanicEraseOnMainWithSuccess:YES completion:completion];
        }
    });
}

- (void)stopProducers {
    dispatch_sync(dispatch_get_main_queue(), ^{
        [[RCClipboardService shared] stopMonitoring];
        [[RCScreenshotMonitorService shared] stopMonitoring];
        [[RCDataCleanService shared] stopCleanupTimer];
        [[RCHotKeyService shared] unregisterAllHotKeys];
    });
}

- (BOOL)drainProducerQueues {
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

    return dispatch_group_wait(flushGroup,
                               dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(5 * NSEC_PER_SEC))) == 0;
}

- (void)completePanicEraseOnMainWithSuccess:(BOOL)success
                                 completion:(nullable void(^)(BOOL success))completion {
    void (^complete)(void) = ^{
        if (completion != nil) {
            completion(success);
        }
        if (success) {
            self.isEraseAttemptActive = NO;
            // The completion runs first so failure UI is never hidden by an
            // unconditional termination request.
            [NSApp terminate:nil];
        }
    };
    if ([NSThread isMainThread]) {
        complete();
    } else {
        dispatch_async(dispatch_get_main_queue(), complete);
    }
}

- (void)finishPanicEraseFailureWithCompletion:(nullable void(^)(BOOL success))completion {
    // Keep isPanicInProgress set: monitoring is stopped and all write entry
    // points must remain behind the barrier. Releasing only the attempt flag
    // makes a later explicit retry safe without allowing writes in between.
    self.isEraseAttemptActive = NO;
    [self completePanicEraseOnMainWithSuccess:NO completion:completion];
}

- (BOOL)overwriteAndDeleteClipFiles {
    return [self overwriteAndDeleteClipFilesAtApplicationSupportPath:[RCUtilities applicationSupportPath]];
}

- (BOOL)overwriteAndDeleteClipFilesAtApplicationSupportPath:(NSString *)applicationSupportPath {
    if (applicationSupportPath.length == 0) {
        return NO;
    }

    BOOL applicationSupportExists = NO;
    if (!RCPanicValidateDirectoryRoot(applicationSupportPath, &applicationSupportExists)) {
        os_log_error(RCPanicEraseServiceLog(),
                     "Panic: refusing to erase through an invalid or symbolic-link application support root");
        return NO;
    }
    if (!applicationSupportExists) {
        return YES;
    }

    NSString *clipsDirectoryPath = [[applicationSupportPath stringByAppendingPathComponent:@"ClipsData"] stringByStandardizingPath];
    BOOL clipsDirectoryExists = NO;
    if (!RCPanicValidateDirectoryRoot(clipsDirectoryPath, &clipsDirectoryExists)) {
        os_log_error(RCPanicEraseServiceLog(),
                     "Panic: refusing to erase through an invalid or symbolic-link clip root");
        return NO;
    }
    if (!clipsDirectoryExists) {
        return YES;
    }

    if (![self validateEntriesInDirectoryAtPath:clipsDirectoryPath
                                    fileManager:[NSFileManager defaultManager]]) {
        return NO;
    }

    return [self overwriteEntriesInDirectoryAtPath:clipsDirectoryPath
                                        fileManager:[NSFileManager defaultManager]];
}

- (BOOL)validatePanicClipStorageAtApplicationSupportPath:(NSString *)applicationSupportPath {
    if (applicationSupportPath.length == 0) {
        return NO;
    }

    BOOL applicationSupportExists = NO;
    if (!RCPanicValidateDirectoryRoot(applicationSupportPath, &applicationSupportExists)) {
        os_log_error(RCPanicEraseServiceLog(),
                     "Panic: refusing storage preflight through an invalid application support root");
        return NO;
    }
    if (!applicationSupportExists) {
        return YES;
    }

    NSString *clipsDirectoryPath = [[applicationSupportPath stringByAppendingPathComponent:@"ClipsData"] stringByStandardizingPath];
    BOOL clipsDirectoryExists = NO;
    if (!RCPanicValidateDirectoryRoot(clipsDirectoryPath, &clipsDirectoryExists)) {
        os_log_error(RCPanicEraseServiceLog(),
                     "Panic: refusing storage preflight through an invalid clip root");
        return NO;
    }
    if (!clipsDirectoryExists) {
        return YES;
    }

    return [self validateEntriesInDirectoryAtPath:clipsDirectoryPath
                                       fileManager:[NSFileManager defaultManager]];
}

- (BOOL)validateEntriesInDirectoryAtPath:(NSString *)directoryPath
                             fileManager:(NSFileManager *)fileManager {
    if (directoryPath.length == 0 || fileManager == nil) {
        return NO;
    }

    NSError *listingError = nil;
    NSArray<NSString *> *entries = [fileManager contentsOfDirectoryAtPath:directoryPath
                                                                      error:&listingError];
    if (entries == nil) {
        os_log_error(RCPanicEraseServiceLog(),
                     "Panic: could not preflight clip directory (%{public}@)",
                     listingError.localizedDescription ?: @"unknown error");
        return NO;
    }

    for (NSString *entryName in entries) {
        NSString *entryPath = [directoryPath stringByAppendingPathComponent:entryName];
        struct stat info;
        if (lstat(entryPath.fileSystemRepresentation, &info) != 0) {
            RCPanicLogFileFailure(@"lstat", entryPath, errno);
            return NO;
        }
        if (S_ISLNK(info.st_mode)) {
            os_log_error(RCPanicEraseServiceLog(),
                         "Panic: refusing symbolic-link clip entry during preflight %{private}@",
                         entryPath);
            return NO;
        }
        if (S_ISDIR(info.st_mode)) {
            if (!RCPanicValidateDirectoryRoot(entryPath, NULL)
                || ![self validateEntriesInDirectoryAtPath:entryPath fileManager:fileManager]) {
                return NO;
            }
            continue;
        }
        if (!S_ISREG(info.st_mode) || info.st_uid != getuid() || info.st_nlink != 1) {
            os_log_error(RCPanicEraseServiceLog(),
                         "Panic: refusing non-private clip entry during preflight %{private}@",
                         entryPath);
            return NO;
        }
    }
    return YES;
}

- (BOOL)overwriteEntriesInDirectoryAtPath:(NSString *)directoryPath
                              fileManager:(NSFileManager *)fileManager {
    if (directoryPath.length == 0 || fileManager == nil) {
        return NO;
    }

    NSError *listingError = nil;
    NSArray<NSString *> *entries = [fileManager contentsOfDirectoryAtPath:directoryPath
                                                                      error:&listingError];
    if (entries == nil) {
        os_log_error(RCPanicEraseServiceLog(),
                     "Panic: could not enumerate clip directory (%{public}@)",
                     listingError.localizedDescription ?: @"unknown error");
        return NO;
    }

    BOOL succeeded = YES;
    for (NSString *entryName in entries) {
        NSString *entryPath = [directoryPath stringByAppendingPathComponent:entryName];
        struct stat info;
        if (lstat(entryPath.fileSystemRepresentation, &info) != 0) {
            RCPanicLogFileFailure(@"lstat", entryPath, errno);
            succeeded = NO;
            continue;
        }

        // Never descend through or overwrite a symbolic link. Returning NO is
        // deliberate: leaving an unhandled entry must not be reported as a
        // successful panic erase.
        if (S_ISLNK(info.st_mode)) {
            os_log_error(RCPanicEraseServiceLog(),
                         "Panic: refusing symbolic-link clip entry %{private}@",
                         entryPath);
            succeeded = NO;
            continue;
        }

        if (S_ISDIR(info.st_mode)) {
            BOOL directorySucceeded = RCPanicValidateDirectoryRoot(entryPath, NULL)
                && [self overwriteEntriesInDirectoryAtPath:entryPath fileManager:fileManager];
            if (directorySucceeded
                && rmdir(entryPath.fileSystemRepresentation) != 0
                && errno != ENOENT) {
                RCPanicLogFileFailure(@"rmdir", entryPath, errno);
                directorySucceeded = NO;
            }
            if (!directorySucceeded) {
                succeeded = NO;
            }
            continue;
        }

        if (!S_ISREG(info.st_mode) || info.st_uid != getuid() || info.st_nlink != 1) {
            os_log_error(RCPanicEraseServiceLog(),
                         "Panic: refusing non-private regular clip entry %{private}@",
                         entryPath);
            succeeded = NO;
            continue;
        }

        if (![self overwriteFileWithZerosAtPath:entryPath fileManager:fileManager]) {
            succeeded = NO;
            continue;
        }

        struct stat currentInfo;
        if (lstat(entryPath.fileSystemRepresentation, &currentInfo) != 0) {
            if (errno != ENOENT) {
                RCPanicLogFileFailure(@"lstat", entryPath, errno);
                succeeded = NO;
            }
        } else if (currentInfo.st_dev != info.st_dev || currentInfo.st_ino != info.st_ino) {
            os_log_error(RCPanicEraseServiceLog(),
                         "Panic: clip entry changed during erase %{private}@",
                         entryPath);
            succeeded = NO;
        } else if (unlink(entryPath.fileSystemRepresentation) != 0 && errno != ENOENT) {
            RCPanicLogFileFailure(@"unlink", entryPath, errno);
            succeeded = NO;
        }
    }

    if (succeeded) {
        NSError *remainingError = nil;
        NSArray<NSString *> *remainingEntries = [fileManager contentsOfDirectoryAtPath:directoryPath
                                                                             error:&remainingError];
        if (remainingEntries == nil || remainingEntries.count != 0) {
            os_log_error(RCPanicEraseServiceLog(),
                         "Panic: clip directory was modified during erase (%{public}@)",
                         remainingError.localizedDescription ?: @"unknown error");
            succeeded = NO;
        }
    }

    return succeeded;
}

- (BOOL)overwriteFileWithZerosAtPath:(NSString *)path fileManager:(NSFileManager *)fileManager {
    (void)fileManager;
    if (path.length == 0) {
        return NO;
    }

    struct stat pathInfo;
    if (lstat(path.fileSystemRepresentation, &pathInfo) != 0) {
        RCPanicLogFileFailure(@"lstat", path, errno);
        return NO;
    }
    if (!S_ISREG(pathInfo.st_mode) || pathInfo.st_uid != getuid() || pathInfo.st_nlink != 1) {
        os_log_error(RCPanicEraseServiceLog(),
                     "Panic: refusing to overwrite non-private regular file %{private}@",
                     path);
        return NO;
    }

    int descriptor = open(path.fileSystemRepresentation,
                          O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (descriptor < 0) {
        RCPanicLogFileFailure(@"open", path, errno);
        return NO;
    }

    BOOL succeeded = NO;
    struct stat info;
    if (fstat(descriptor, &info) != 0) {
        RCPanicLogFileFailure(@"fstat", path, errno);
        close(descriptor);
        return NO;
    }
    if (!S_ISREG(info.st_mode)
        || info.st_uid != getuid()
        || info.st_nlink != 1
        || info.st_size < 0
        || info.st_dev != pathInfo.st_dev
        || info.st_ino != pathInfo.st_ino) {
        os_log_error(RCPanicEraseServiceLog(),
                     "Panic: refusing to overwrite non-private regular file %{private}@",
                     path);
        close(descriptor);
        return NO;
    }

    unsigned long long remaining = (unsigned long long)info.st_size;
    // GCD worker stacks are smaller than the main thread stack. Share an
    // immutable buffer instead of allocating a large array on each worker.
    static const unsigned char zeroBuffer[kRCPanicZeroBufferSize] = {0};
    while (remaining > 0) {
        size_t requested = (size_t)MIN(remaining, (unsigned long long)sizeof(zeroBuffer));
        ssize_t written = write(descriptor, zeroBuffer, requested);
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written <= 0) {
            RCPanicLogFileFailure(@"write", path, written == 0 ? EIO : errno);
            goto close_descriptor;
        }
        remaining -= (unsigned long long)written;
    }

    if (ftruncate(descriptor, info.st_size) != 0) {
        RCPanicLogFileFailure(@"ftruncate", path, errno);
        goto close_descriptor;
    }
    if (fsync(descriptor) != 0) {
        RCPanicLogFileFailure(@"fsync", path, errno);
        goto close_descriptor;
    }
    succeeded = YES;

close_descriptor:
    if (close(descriptor) != 0) {
        RCPanicLogFileFailure(@"close", path, errno);
        succeeded = NO;
    }
    return succeeded;
}

- (BOOL)validateDatabaseFilesForManager:(RCDatabaseManager *)databaseManager
                        databaseExists:(BOOL *)databaseExists {
    if (databaseExists != NULL) {
        *databaseExists = NO;
    }
    if (databaseManager == nil || databaseManager.databasePath.length == 0) {
        return NO;
    }

    NSString *applicationSupportPath = [RCUtilities applicationSupportPath];
    BOOL applicationSupportExists = NO;
    if (!RCPanicValidateDirectoryRoot(applicationSupportPath, &applicationSupportExists)) {
        os_log_error(RCPanicEraseServiceLog(),
                     "Panic: refusing to delete database through an invalid application support root");
        return NO;
    }

    NSString *expectedDatabasePath = [[applicationSupportPath stringByAppendingPathComponent:@"revclip.db"] stringByStandardizingPath];
    NSString *standardizedDatabasePath = [databaseManager.databasePath stringByStandardizingPath];
    if (![standardizedDatabasePath isEqualToString:expectedDatabasePath]) {
        os_log_error(RCPanicEraseServiceLog(),
                     "Panic: refusing to use a database outside the private database path");
        return NO;
    }
    if (!applicationSupportExists) {
        return YES;
    }

    NSError *migrationValidationError = nil;
    if (![RCStorageMigration validateMigrationArtifactsBesideDatabase:standardizedDatabasePath
                                                                  error:&migrationValidationError]) {
        os_log_error(RCPanicEraseServiceLog(),
                     "Panic: refusing database cleanup because migration artifacts are unsafe (%{public}@)",
                     migrationValidationError.localizedDescription ?: @"unknown error");
        return NO;
    }

    for (NSString *suffix in @[@"", @"-journal", @"-wal", @"-shm"]) {
        NSString *path = [standardizedDatabasePath stringByAppendingString:suffix];
        struct stat info;
        if (lstat(path.fileSystemRepresentation, &info) != 0) {
            if (errno == ENOENT) {
                continue;
            }
            RCPanicLogFileFailure(@"lstat", path, errno);
            return NO;
        }
        if (!S_ISREG(info.st_mode) || info.st_uid != getuid() || info.st_nlink != 1) {
            os_log_error(RCPanicEraseServiceLog(),
                         "Panic: refusing non-private database entry %{private}@",
                         path);
            return NO;
        }
        if (suffix.length == 0 && databaseExists != NULL) {
            *databaseExists = YES;
        }
    }
    return YES;
}

- (BOOL)deleteDatabaseFilesForManager:(RCDatabaseManager *)databaseManager {
    // The manager's legacy void helper discards unlink errors. Panic erase
    // needs an aggregate status and a nofollow boundary, so it owns this
    // checked sidecar removal after the manager has closed its queue.
    if (![self validateDatabaseFilesForManager:databaseManager databaseExists:NULL]) {
        return NO;
    }

    NSString *standardizedDatabasePath = [databaseManager.databasePath stringByStandardizingPath];
    NSError *migrationRemovalError = nil;
    BOOL migrationArtifactsDeleted = [RCStorageMigration removeMigrationArtifactsBesideDatabase:standardizedDatabasePath
                                                                                            error:&migrationRemovalError];
    if (!migrationArtifactsDeleted) {
        os_log_error(RCPanicEraseServiceLog(),
                     "Panic: migration artifacts could not be removed (%{public}@)",
                     migrationRemovalError.localizedDescription ?: @"unknown error");
    }

    BOOL succeeded = YES;
    for (NSString *suffix in @[@"", @"-journal", @"-wal", @"-shm"]) {
        NSString *path = [standardizedDatabasePath stringByAppendingString:suffix];
        struct stat info;
        if (lstat(path.fileSystemRepresentation, &info) != 0) {
            if (errno == ENOENT) {
                continue;
            }
            RCPanicLogFileFailure(@"lstat", path, errno);
            succeeded = NO;
            continue;
        }
        if (unlink(path.fileSystemRepresentation) != 0 && errno != ENOENT) {
            RCPanicLogFileFailure(@"unlink", path, errno);
            succeeded = NO;
        }
    }
    return succeeded && migrationArtifactsDeleted;
}

@end
