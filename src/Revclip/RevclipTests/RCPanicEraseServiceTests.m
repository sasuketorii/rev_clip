#import <XCTest/XCTest.h>

#import "RCPanicEraseService.h"
#import "RCStorageMigration.h"

@interface RCPanicEraseService (Testing)
- (void)stopProducers;
- (BOOL)drainProducerQueues;
- (BOOL)overwriteAndDeleteClipFilesAtApplicationSupportPath:(NSString *)applicationSupportPath;
- (BOOL)validatePanicClipStorageAtApplicationSupportPath:(NSString *)applicationSupportPath;
@end

@interface RCPanicEraseTimeoutTestDouble : RCPanicEraseService
@property (atomic, assign) NSUInteger drainCallCount;
@end

@implementation RCPanicEraseTimeoutTestDouble

- (void)stopProducers {
}

- (BOOL)drainProducerQueues {
    self.drainCallCount += 1;
    return NO;
}

- (BOOL)validatePanicClipStorageAtApplicationSupportPath:(NSString *)applicationSupportPath {
    (void)applicationSupportPath;
    XCTFail(@"queue timeout must return before storage preflight");
    return NO;
}

@end

@interface RCPanicEraseServiceTests : XCTestCase
@property (nonatomic, copy) NSString *fixtureRoot;
@end

@implementation RCPanicEraseServiceTests

- (void)setUp {
    [super setUp];

    self.fixtureRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSError *error = nil;
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:self.fixtureRoot
                                            withIntermediateDirectories:YES
                                                             attributes:@{ NSFilePosixPermissions: @0700 }
                                                                  error:&error],
                  @"fixture directory: %@", error.localizedDescription);
}

- (void)tearDown {
    [[NSFileManager defaultManager] removeItemAtPath:self.fixtureRoot error:nil];
    [super tearDown];
}

- (void)testSecureOverwriteRefusesSymbolicLinkWithoutTouchingTarget {
    NSString *targetPath = [self.fixtureRoot stringByAppendingPathComponent:@"target.data"];
    NSString *linkPath = [self.fixtureRoot stringByAppendingPathComponent:@"link.data"];
    NSData *sentinel = [@"do not overwrite" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([sentinel writeToFile:targetPath atomically:YES]);
    XCTAssertTrue([[NSFileManager defaultManager] createSymbolicLinkAtPath:linkPath
                                                          withDestinationPath:targetPath
                                                                         error:nil]);

    XCTAssertFalse([RCPanicEraseService secureOverwriteFileAtPath:linkPath]);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:targetPath], sentinel);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:linkPath]);
}

- (void)testSecureOverwriteZeroFillsRegularFixtureWithoutDeletingIt {
    NSString *path = [self.fixtureRoot stringByAppendingPathComponent:@"clip.data"];
    NSData *source = [@"sensitive clipboard payload" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([source writeToFile:path atomically:YES]);

    XCTAssertTrue([RCPanicEraseService secureOverwriteFileAtPath:path]);
    NSData *overwritten = [NSData dataWithContentsOfFile:path];
    XCTAssertNotNil(overwritten);
    XCTAssertEqual(overwritten.length, source.length);
    const unsigned char *bytes = overwritten.bytes;
    for (NSUInteger index = 0; index < overwritten.length; index++) {
        XCTAssertEqual(bytes[index], 0, @"byte %lu was not zeroed", (unsigned long)index);
    }
}

- (void)testClipRootSymbolicLinkIsRefusedWithoutTouchingOutsideData {
    NSString *outsideRoot = [self.fixtureRoot stringByAppendingPathComponent:@"outside"];
    NSString *outsideFile = [outsideRoot stringByAppendingPathComponent:@"clip.data"];
    NSString *applicationSupport = [self.fixtureRoot stringByAppendingPathComponent:@"application"];
    NSString *clipRoot = [applicationSupport stringByAppendingPathComponent:@"ClipsData"];
    NSData *sentinel = [@"outside payload" dataUsingEncoding:NSUTF8StringEncoding];

    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:outsideRoot
                                            withIntermediateDirectories:YES
                                                             attributes:@{ NSFilePosixPermissions: @0700 }
                                                                  error:nil]);
    XCTAssertTrue([sentinel writeToFile:outsideFile atomically:YES]);
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:applicationSupport
                                            withIntermediateDirectories:YES
                                                             attributes:@{ NSFilePosixPermissions: @0700 }
                                                                  error:nil]);
    XCTAssertTrue([[NSFileManager defaultManager] createSymbolicLinkAtPath:clipRoot
                                                          withDestinationPath:outsideRoot
                                                                         error:nil]);

    RCPanicEraseService *service = [RCPanicEraseService shared];
    XCTAssertFalse([service overwriteAndDeleteClipFilesAtApplicationSupportPath:applicationSupport]);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:outsideFile], sentinel);
}

- (void)testApplicationSupportRootSymbolicLinkIsRefusedWithoutTouchingOutsideData {
    NSString *outsideRoot = [self.fixtureRoot stringByAppendingPathComponent:@"outside"];
    NSString *outsideClipRoot = [outsideRoot stringByAppendingPathComponent:@"ClipsData"];
    NSString *outsideFile = [outsideClipRoot stringByAppendingPathComponent:@"clip.data"];
    NSString *applicationSupport = [self.fixtureRoot stringByAppendingPathComponent:@"application"];
    NSData *sentinel = [@"outside payload" dataUsingEncoding:NSUTF8StringEncoding];

    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:outsideClipRoot
                                            withIntermediateDirectories:YES
                                                             attributes:@{ NSFilePosixPermissions: @0700 }
                                                                  error:nil]);
    XCTAssertTrue([sentinel writeToFile:outsideFile atomically:YES]);
    XCTAssertTrue([[NSFileManager defaultManager] createSymbolicLinkAtPath:applicationSupport
                                                          withDestinationPath:outsideRoot
                                                                         error:nil]);

    RCPanicEraseService *service = [RCPanicEraseService shared];
    XCTAssertFalse([service overwriteAndDeleteClipFilesAtApplicationSupportPath:applicationSupport]);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:outsideFile], sentinel);
}

- (void)testClipEntrySymbolicLinkIsRefusedWithoutTouchingOutsideData {
    NSString *outsideFile = [self.fixtureRoot stringByAppendingPathComponent:@"outside.data"];
    NSString *applicationSupport = [self.fixtureRoot stringByAppendingPathComponent:@"application"];
    NSString *clipRoot = [applicationSupport stringByAppendingPathComponent:@"ClipsData"];
    NSString *linkPath = [clipRoot stringByAppendingPathComponent:@"clip.data"];
    NSData *sentinel = [@"outside payload" dataUsingEncoding:NSUTF8StringEncoding];

    XCTAssertTrue([sentinel writeToFile:outsideFile atomically:YES]);
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:clipRoot
                                            withIntermediateDirectories:YES
                                                             attributes:@{ NSFilePosixPermissions: @0700 }
                                                                  error:nil]);
    XCTAssertTrue([[NSFileManager defaultManager] createSymbolicLinkAtPath:linkPath
                                                          withDestinationPath:outsideFile
                                                                         error:nil]);

    RCPanicEraseService *service = [RCPanicEraseService shared];
    XCTAssertFalse([service overwriteAndDeleteClipFilesAtApplicationSupportPath:applicationSupport]);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:outsideFile], sentinel);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:linkPath]);
}

- (void)testRegularClipFixtureIsZeroedThenDeleted {
    NSString *applicationSupport = [self.fixtureRoot stringByAppendingPathComponent:@"application"];
    NSString *clipRoot = [applicationSupport stringByAppendingPathComponent:@"ClipsData"];
    NSString *nestedRoot = [clipRoot stringByAppendingPathComponent:@"nested"];
    NSString *clipPath = [nestedRoot stringByAppendingPathComponent:@"clip.data"];

    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:nestedRoot
                                            withIntermediateDirectories:YES
                                                             attributes:@{ NSFilePosixPermissions: @0700 }
                                                                  error:nil]);
    NSData *payload = [@"sensitive payload" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([payload writeToFile:clipPath atomically:YES]);

    RCPanicEraseService *service = [RCPanicEraseService shared];
    XCTAssertTrue([service overwriteAndDeleteClipFilesAtApplicationSupportPath:applicationSupport]);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:clipPath]);
}

- (void)testFlushTimeoutFailsOnMainKeepsBarrierAndAllowsRetry {
    RCPanicEraseTimeoutTestDouble *service = [RCPanicEraseTimeoutTestDouble new];

    XCTestExpectation *firstCompletion = [self expectationWithDescription:@"first timeout completion"];
    __block BOOL firstCompletionOnMain = NO;
    [service executePanicEraseWithCompletion:^(BOOL success) {
        firstCompletionOnMain = [NSThread isMainThread];
        XCTAssertFalse(success);
        [firstCompletion fulfill];
    }];
    [self waitForExpectations:@[firstCompletion] timeout:1.0];

    XCTAssertTrue(firstCompletionOnMain);
    XCTAssertTrue(service.isPanicInProgress);
    XCTAssertFalse(service.isEraseAttemptActive);

    XCTestExpectation *retryCompletion = [self expectationWithDescription:@"retry timeout completion"];
    __block BOOL retryCompletionOnMain = NO;
    [service executePanicEraseWithCompletion:^(BOOL success) {
        retryCompletionOnMain = [NSThread isMainThread];
        XCTAssertFalse(success);
        [retryCompletion fulfill];
    }];
    [self waitForExpectations:@[retryCompletion] timeout:1.0];

    XCTAssertTrue(retryCompletionOnMain);
    XCTAssertTrue(service.isPanicInProgress);
    XCTAssertFalse(service.isEraseAttemptActive);
    XCTAssertEqual(service.drainCallCount, (NSUInteger)2);
}

- (void)testMigrationArtifactsAreRemovedFromFixtureBesideDatabase {
    NSString *databasePath = [self.fixtureRoot stringByAppendingPathComponent:@"revclip.db"];
    NSString *stagePath = [self.fixtureRoot stringByAppendingPathComponent:@".encrypted-11111111-1111-1111-1111-111111111111.db"];
    NSArray<NSString *> *paths = @[
        stagePath,
        [stagePath stringByAppendingString:@"-journal"],
        [stagePath stringByAppendingString:@"-wal"],
        [stagePath stringByAppendingString:@"-shm"]
    ];
    for (NSString *path in paths) {
        XCTAssertTrue([[NSFileManager defaultManager] createFileAtPath:path
                                                              contents:[NSData data]
                                                            attributes:@{ NSFilePosixPermissions: @0600 }]);
    }

    NSError *error = nil;
    XCTAssertTrue([RCStorageMigration validateMigrationArtifactsBesideDatabase:databasePath error:&error],
                  @"validation error: %@", error.localizedDescription);
    error = nil;
    XCTAssertTrue([RCStorageMigration removeMigrationArtifactsBesideDatabase:databasePath error:&error],
                  @"cleanup error: %@", error.localizedDescription);
    for (NSString *path in paths) {
        XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:path]);
    }
}

- (void)testMigrationArtifactSymlinkFailsPreflightWithoutTouchingTarget {
    NSString *databasePath = [self.fixtureRoot stringByAppendingPathComponent:@"revclip.db"];
    NSString *outsidePath = [self.fixtureRoot stringByAppendingPathComponent:@"outside.data"];
    NSString *stagePath = [self.fixtureRoot stringByAppendingPathComponent:@".encrypted-22222222-2222-2222-2222-222222222222.db"];
    NSString *safeStagePath = [self.fixtureRoot stringByAppendingPathComponent:@".encrypted-33333333-3333-3333-3333-333333333333.db"];
    NSData *sentinel = [@"outside payload" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([sentinel writeToFile:outsidePath atomically:YES]);
    XCTAssertTrue([[NSFileManager defaultManager] createFileAtPath:safeStagePath
                                                          contents:[NSData data]
                                                        attributes:@{ NSFilePosixPermissions: @0600 }]);
    XCTAssertTrue([[NSFileManager defaultManager] createSymbolicLinkAtPath:stagePath
                                                          withDestinationPath:outsidePath
                                                                         error:nil]);

    NSError *error = nil;
    XCTAssertFalse([RCStorageMigration validateMigrationArtifactsBesideDatabase:databasePath error:&error]);
    XCTAssertFalse([RCStorageMigration removeMigrationArtifactsBesideDatabase:databasePath error:&error]);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:outsidePath], sentinel);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:safeStagePath]);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:stagePath]);
}

- (void)testAcceptedPanicRequestSetsBarrierBeforeWorkerStarts {
    RCPanicEraseTimeoutTestDouble *service = [RCPanicEraseTimeoutTestDouble new];
    dispatch_queue_t queue = [service valueForKey:@"panicQueue"];
    dispatch_suspend(queue);
    XCTestExpectation *completion = [self expectationWithDescription:@"isolated timeout"];
    @try {
        [service executePanicEraseWithCompletion:^(BOOL success) {
            XCTAssertFalse(success);
            [completion fulfill];
        }];
        XCTAssertTrue(service.isPanicInProgress);
        XCTAssertTrue(service.isEraseAttemptActive);
        XCTAssertEqual(service.drainCallCount,0u);
    } @finally { dispatch_resume(queue); }
    [self waitForExpectations:@[completion] timeout:1.0];
}
- (void)testOverwriteRunsSafelyOnBackgroundWorkerStack {
    NSString *file = [self.fixtureRoot stringByAppendingPathComponent:@"background-fixture"];
    NSMutableData *original = [NSMutableData dataWithLength:256 * 1024];
    memset(original.mutableBytes,0x7f,original.length);
    XCTAssertTrue([original writeToFile:file atomically:YES]);
    XCTestExpectation *finished = [self expectationWithDescription:@"background overwrite"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        XCTAssertTrue([RCPanicEraseService secureOverwriteFileAtPath:file]);
        NSData *result = [NSData dataWithContentsOfFile:file];
        XCTAssertEqualObjects(result,[NSMutableData dataWithLength:original.length]);
        [finished fulfill];
    });
    [self waitForExpectations:@[finished] timeout:5];
}
@end
