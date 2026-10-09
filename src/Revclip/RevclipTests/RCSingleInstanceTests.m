#import <XCTest/XCTest.h>
#import "RCSingleInstanceLock.h"
#import "RCMoveToApplicationsService.h"

@interface RCSingleInstanceTests : XCTestCase
@property(nonatomic, copy) NSString *directory;
@end

@implementation RCSingleInstanceTests

- (void)setUp {
    [super setUp];
    self.directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:self.directory
                                            withIntermediateDirectories:YES
                                                             attributes:nil
                                                                  error:NULL]);
}

- (void)tearDown {
    [[NSFileManager defaultManager] removeItemAtPath:self.directory error:NULL];
    [super tearDown];
}

- (void)testLockIsExclusiveUntilReleased {
    NSString *path = [self.directory stringByAppendingPathComponent:@"instance.lock"];
    int first = -1;
    int second = -1;
    XCTAssertEqual(RCSingleInstanceLockTryAcquire(path, &first), RCSingleInstanceLockResultAcquired);
    XCTAssertGreaterThanOrEqual(first, 0);
    XCTAssertTrue(fcntl(first, F_GETFD) & FD_CLOEXEC, @"The lock must not leak into child processes.");

    XCTAssertEqual(RCSingleInstanceLockTryAcquire(path, &second), RCSingleInstanceLockResultHeld);
    XCTAssertEqual(second, -1);

    RCSingleInstanceLockRelease(first);
    XCTAssertEqual(RCSingleInstanceLockTryAcquire(path, &second), RCSingleInstanceLockResultAcquired);
    RCSingleInstanceLockRelease(second);
}

- (void)testUnopenableLockFileReportsError {
    NSString *path = [[self.directory stringByAppendingPathComponent:@"missing"] stringByAppendingPathComponent:@"instance.lock"];
    int fd = 0;
    XCTAssertEqual(RCSingleInstanceLockTryAcquire(path, &fd), RCSingleInstanceLockResultError);
    XCTAssertEqual(fd, -1);
}

- (void)testXCTestEnvironmentPredicate {
    XCTAssertTrue(RCSingleInstanceLockIsXCTestEnvironment(@{@"XCTestConfigurationFilePath": @"/tmp/x.xctestconfiguration"}));
    XCTAssertTrue(RCSingleInstanceLockIsXCTestEnvironment(@{@"XCTestBundlePath": @"/tmp/x.xctest"}));
    XCTAssertTrue(RCSingleInstanceLockIsXCTestEnvironment(@{@"XCTestSessionIdentifier": @"ABC"}));
    XCTAssertTrue(RCSingleInstanceLockIsXCTestEnvironment(@{@"DYLD_INSERT_LIBRARIES": @"/a/libXCTestBundleInject.dylib"}));
    XCTAssertFalse(RCSingleInstanceLockIsXCTestEnvironment(@{}));
    XCTAssertFalse(RCSingleInstanceLockIsXCTestEnvironment(@{@"HOME": @"/Users/x", @"DYLD_INSERT_LIBRARIES": @"/a/other.dylib"}));
}

- (void)testHostedTestEnvironmentIsRecognised {
    XCTAssertTrue(RCSingleInstanceLockIsXCTestEnvironment(NSProcessInfo.processInfo.environment));
    // The process-wide entry point must not take the real lock in a test host.
    XCTAssertEqual(RCSingleInstanceLockAcquireForProcess(), RCSingleInstanceLockResultAcquired);
}

- (void)testBuildProductBundlePaths {
    NSArray<NSString *> *buildProducts = @[
        @"/Users/x/dev/rev_clip/src/Revclip/build/Debug/Revclip.app",
        @"/Users/x/dev/rev_clip/src/Revclip/build/Release/Revclip.app",
        @"/Users/x/dev/rev_clip/src/Revclip/Build/Release/Revclip.app",
        @"/Users/x/dev/rev_clip/src/Revclip/build-demo/Demo/revclip-demo.app",
        @"/Users/x/dev/rev_clip/src/Revclip/build/Demo/revclip-demo.app",
        @"/Users/x/dd/Build/Products/Debug/Revclip.app",
        @"/Users/x/rev_clip/.local/quality/recheck/Build/Products/Release/Revclip.app",
        @"/Users/x/orca/workspaces/rev_clip/wt/src/Revclip/build/Release/Revclip.app",
        @"/Users/x/Library/Developer/Xcode/DerivedData/Revclip-abc/Build/Products/Debug/Revclip.app",
        @"/Users/x/Library/Developer/Xcode/Archives/2026-10-09/Revclip.xcarchive/Products/Applications/Revclip.app",
        @"/tmp/DerivedData/Revclip.app",
    ];
    for (NSString *path in buildProducts) {
        XCTAssertTrue([RCMoveToApplicationsService isBuildProductBundlePath:path], @"%@", path);
    }

    NSArray<NSString *> *installs = @[
        @"/Applications/Revclip.app",
        @"/Applications/Build/Revclip.app",
        @"/Users/build/Applications/Revclip.app",
        @"/Users/x/build/Revclip.app",
        @"/Users/x/Products/Debug/Revclip.app",
        @"/Users/x/Xcode/Revclip.app",
        @"/Users/x/Applications/Revclip.app",
        @"/Users/x/Downloads/Revclip.app",
        @"/Volumes/Revclip 0.2.7/Revclip.app",
    ];
    for (NSString *path in installs) {
        XCTAssertFalse([RCMoveToApplicationsService isBuildProductBundlePath:path], @"%@", path);
    }
}

@end
