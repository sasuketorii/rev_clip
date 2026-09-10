//
//  RCUpdateServiceNotificationPolicyTests.m
//  RevclipTests
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import <XCTest/XCTest.h>

#import "RCUpdateService.h"

@interface RCUpdateService (Testing)
- (void)updater:(id)updater didFinishUpdateCycleForUpdateCheck:(NSInteger)updateCheck error:(nullable NSError *)error;
- (void)applyStoredPreferencesToUpdater;
@end

@interface RCUpdateServiceTestUpdater : NSObject
@property (nonatomic, assign) BOOL automaticallyChecksForUpdates;
@property (nonatomic, assign) NSTimeInterval updateCheckInterval;
@property (nonatomic, assign) BOOL automaticallyDownloadsUpdates;
@property (nonatomic, assign) BOOL canCheckForUpdates;
@end

@implementation RCUpdateServiceTestUpdater
@end

@interface RCUpdateServiceTestUpdaterController : NSObject
@property (nonatomic, strong) RCUpdateServiceTestUpdater *updater;
@property (nonatomic, assign) NSInteger checkForUpdatesInvocationCount;
- (void)checkForUpdates:(id)sender;
@end

@implementation RCUpdateServiceTestUpdaterController

- (void)checkForUpdates:(__unused id)sender {
    self.checkForUpdatesInvocationCount += 1;
}

@end

@interface RCUpdateServiceNotificationPolicyTests : XCTestCase
@end

@implementation RCUpdateServiceNotificationPolicyTests

- (RCUpdateService *)makeUpdateServiceForTest {
    return [[RCUpdateService alloc] init];
}

- (void)testCheckForUpdatesReturnsNOWhenManualCheckCannotStart {
    RCUpdateService *service = [self makeUpdateServiceForTest];
    id originalController = [service valueForKey:@"updaterController"];
    @try {
        RCUpdateServiceTestUpdater *mockUpdater = [[RCUpdateServiceTestUpdater alloc] init];
        mockUpdater.canCheckForUpdates = NO;

        RCUpdateServiceTestUpdaterController *mockController = [[RCUpdateServiceTestUpdaterController alloc] init];
        mockController.updater = mockUpdater;
        [service setValue:mockController forKey:@"updaterController"];

        BOOL didStart = [service checkForUpdates];

        XCTAssertFalse(didStart);
        XCTAssertEqual(mockController.checkForUpdatesInvocationCount, 0);
    } @finally {
        [service setValue:originalController forKey:@"updaterController"];
    }
}

- (void)testCheckForUpdatesOffMainThreadReturnsNOAndDoesNotStartPolling {
    RCUpdateService *service = [self makeUpdateServiceForTest];
    id originalController = [service valueForKey:@"updaterController"];
    @try {
        RCUpdateServiceTestUpdater *mockUpdater = [[RCUpdateServiceTestUpdater alloc] init];
        mockUpdater.canCheckForUpdates = YES;

        RCUpdateServiceTestUpdaterController *mockController = [[RCUpdateServiceTestUpdaterController alloc] init];
        mockController.updater = mockUpdater;
        [service setValue:mockController forKey:@"updaterController"];

        XCTestExpectation *expectation = [self expectationWithDescription:@"Off-main invocation finished"];
        __block BOOL didRunOnMainThread = YES;
        __block BOOL didStart = YES;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            didRunOnMainThread = [NSThread isMainThread];
            didStart = [service checkForUpdates];
            [expectation fulfill];
        });
        [self waitForExpectations:@[expectation] timeout:1.0];

        XCTAssertFalse(didRunOnMainThread);
        XCTAssertFalse(didStart);
        XCTAssertEqual(mockController.checkForUpdatesInvocationCount, 0);
    } @finally {
        [service setValue:originalController forKey:@"updaterController"];
    }
}

- (void)testManualUpdateFailurePostsNotificationWithUpdateCheck {
    RCUpdateService *service = [self makeUpdateServiceForTest];
    XCTestExpectation *expectation = [self expectationWithDescription:@"Manual failure should notify UI"];

    id token = [[NSNotificationCenter defaultCenter] addObserverForName:RCUpdateServiceDidFailNotification
                                                                  object:service
                                                                   queue:[NSOperationQueue mainQueue]
                                                              usingBlock:^(NSNotification * _Nonnull notification) {
        NSNumber *updateCheck = notification.userInfo[RCUpdateServiceUpdateCheckUserInfoKey];
        NSError *error = notification.userInfo[RCUpdateServiceErrorUserInfoKey];
        XCTAssertEqual(updateCheck.integerValue, RCUpdateServiceUpdateCheckUpdates);
        XCTAssertNotNil(error);
        [expectation fulfill];
    }];

    NSError *error = [NSError errorWithDomain:@"SUSparkleErrorDomain"
                                         code:42
                                     userInfo:@{NSLocalizedDescriptionKey: @"manual failure"}];
    [service updater:nil didFinishUpdateCycleForUpdateCheck:RCUpdateServiceUpdateCheckUpdates error:error];

    [self waitForExpectations:@[expectation] timeout:1.0];
    [[NSNotificationCenter defaultCenter] removeObserver:token];
}

- (void)testBackgroundUpdateFailureDoesNotPostNotification {
    RCUpdateService *service = [self makeUpdateServiceForTest];
    XCTestExpectation *expectation = [self expectationWithDescription:@"Background failure must not notify UI"];
    expectation.inverted = YES;

    id token = [[NSNotificationCenter defaultCenter] addObserverForName:RCUpdateServiceDidFailNotification
                                                                  object:service
                                                                   queue:[NSOperationQueue mainQueue]
                                                              usingBlock:^(__unused NSNotification * _Nonnull notification) {
        [expectation fulfill];
    }];

    NSError *error = [NSError errorWithDomain:@"SUSparkleErrorDomain"
                                         code:77
                                     userInfo:@{NSLocalizedDescriptionKey: @"background failure"}];
    [service updater:nil didFinishUpdateCycleForUpdateCheck:RCUpdateServiceUpdateCheckUpdatesInBackground error:error];

    [self waitForExpectations:@[expectation] timeout:0.3];
    [[NSNotificationCenter defaultCenter] removeObserver:token];
}

- (void)testAppcastFetchErrorStillNotifiesManualCheck {
    RCUpdateService *service = [self makeUpdateServiceForTest];
    XCTestExpectation *expectation = [self expectationWithDescription:@"Appcast fetch failure should notify UI"];

    id token = [[NSNotificationCenter defaultCenter] addObserverForName:RCUpdateServiceDidFailNotification
                                                                  object:service
                                                                   queue:[NSOperationQueue mainQueue]
                                                              usingBlock:^(NSNotification * _Nonnull notification) {
        NSError *error = notification.userInfo[RCUpdateServiceErrorUserInfoKey];
        XCTAssertEqual(error.code, 1002);
        [expectation fulfill];
    }];

    NSError *error = [NSError errorWithDomain:@"SUSparkleErrorDomain"
                                         code:1002
                                     userInfo:@{NSLocalizedDescriptionKey: @"appcast fetch failed"}];
    [service updater:nil didFinishUpdateCycleForUpdateCheck:RCUpdateServiceUpdateCheckUpdates error:error];

    [self waitForExpectations:@[expectation] timeout:1.0];
    [[NSNotificationCenter defaultCenter] removeObserver:token];
}

- (void)testNoUpdateErrorIsIgnoredForManualCheck {
    RCUpdateService *service = [self makeUpdateServiceForTest];
    XCTestExpectation *expectation = [self expectationWithDescription:@"No update should not notify UI"];
    expectation.inverted = YES;

    id token = [[NSNotificationCenter defaultCenter] addObserverForName:RCUpdateServiceDidFailNotification
                                                                  object:service
                                                                   queue:[NSOperationQueue mainQueue]
                                                              usingBlock:^(__unused NSNotification * _Nonnull notification) {
        [expectation fulfill];
    }];

    NSError *error = [NSError errorWithDomain:@"SUSparkleErrorDomain"
                                         code:1001
                                     userInfo:@{NSLocalizedDescriptionKey: @"no update"}];
    [service updater:nil didFinishUpdateCycleForUpdateCheck:RCUpdateServiceUpdateCheckUpdates error:error];

    [self waitForExpectations:@[expectation] timeout:0.3];
    [[NSNotificationCenter defaultCenter] removeObserver:token];
}

- (void)testApplyStoredPreferencesForcesAutomaticDownloadOff {
    RCUpdateService *service = [self makeUpdateServiceForTest];
    id originalController = [service valueForKey:@"updaterController"];
    @try {
        RCUpdateServiceTestUpdater *mockUpdater = [[RCUpdateServiceTestUpdater alloc] init];
        mockUpdater.automaticallyDownloadsUpdates = YES;

        RCUpdateServiceTestUpdaterController *mockController = [[RCUpdateServiceTestUpdaterController alloc] init];
        mockController.updater = mockUpdater;
        [service setValue:mockController forKey:@"updaterController"];

        [service applyStoredPreferencesToUpdater];

        XCTAssertFalse(mockUpdater.automaticallyDownloadsUpdates);
    } @finally {
        [service setValue:originalController forKey:@"updaterController"];
    }
}

@end
