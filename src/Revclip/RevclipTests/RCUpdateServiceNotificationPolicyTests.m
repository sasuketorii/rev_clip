//
//  RCUpdateServiceNotificationPolicyTests.m
//  RevclipTests
//
//  Copyright (c) 2024-2026 Revclip. Current project: AGPL-3.0-only; legacy portions: MIT. See THIRD_PARTY_NOTICES.md.
//

#import <XCTest/XCTest.h>
#import <UserNotifications/UserNotifications.h>

#import "RCUpdateService.h"

@interface RCUpdateService (Testing)
- (void)updater:(id)updater didFinishUpdateCycleForUpdateCheck:(NSInteger)updateCheck error:(nullable NSError *)error;
- (void)applyStoredPreferencesToUpdater;
- (id)createUpdaterControllerWithClass:(Class)controllerClass;
- (BOOL)supportsGentleScheduledUpdateReminders;
- (BOOL)standardUserDriverShouldHandleShowingScheduledUpdate:(id)update andInImmediateFocus:(BOOL)focus;
- (void)standardUserDriverWillHandleShowingUpdate:(BOOL)handle forUpdate:(id)update state:(id)state;
- (void)standardUserDriverDidReceiveUserAttentionForUpdate:(id)update;
- (void)standardUserDriverWillFinishUpdateSession;
- (void)showUpdateReminder;
- (void)deliverUpdateNotificationForGeneration:(NSUInteger)generation;
- (void)removeUpdateNotification;
- (void)openUpdateReminder:(id)sender;
- (UNUserNotificationCenter *)updateNotificationCenter;
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

@interface RCReminderTestService : RCUpdateService
@property NSUInteger remindersShown;
@property NSUInteger notificationsRequested;
@property NSUInteger notificationsRemoved;
@end
@implementation RCReminderTestService
- (void)showUpdateReminder { self.remindersShown++; }
- (void)deliverUpdateNotificationForGeneration:(NSUInteger)generation { self.notificationsRequested++; }
- (void)removeUpdateNotification { self.notificationsRemoved++; }
@end

@interface RCReminderTestState : NSObject
@property BOOL userInitiated;
@end
@implementation RCReminderTestState
@end

@interface RCDelegateTestController : RCUpdateServiceTestUpdaterController
@property (weak) id userDriverDelegate;
@end
@implementation RCDelegateTestController
- (instancetype)initWithStartingUpdater:(BOOL)start updaterDelegate:(id)updater userDriverDelegate:(id)driver {
    if ((self = [super init])) { self.userDriverDelegate = driver; }
    return self;
}
@end

@interface RCNotificationCenterFixture : NSObject
@property (weak) id delegate;
@property (copy) void (^authorizationReply)(BOOL, NSError *);
@property (copy) void (^deliveryReply)(NSError *);
@property (strong) UNNotificationRequest *request;
@property (strong) NSMutableArray<NSString *> *removedIdentifiers;
@end
@implementation RCNotificationCenterFixture
- (instancetype)init { if ((self = [super init])) { _removedIdentifiers = [NSMutableArray new]; } return self; }
- (void)requestAuthorizationWithOptions:(UNAuthorizationOptions)options completionHandler:(void (^)(BOOL, NSError *))reply { self.authorizationReply = reply; }
- (void)addNotificationRequest:(UNNotificationRequest *)request withCompletionHandler:(void (^)(NSError *))reply { self.request = request; self.deliveryReply = reply; }
- (void)removePendingNotificationRequestsWithIdentifiers:(NSArray *)identifiers { [self.removedIdentifiers addObjectsFromArray:identifiers]; }
- (void)removeDeliveredNotificationsWithIdentifiers:(NSArray *)identifiers { [self.removedIdentifiers addObjectsFromArray:identifiers]; }
@end
@interface RCNotificationTestService : RCUpdateService
@property (strong) RCNotificationCenterFixture *center;
@property NSUInteger remindersShown;
@end
@implementation RCNotificationTestService
- (NSString *)updateFeedURL { return @"https://example.invalid/appcast.xml"; }
- (void)showUpdateReminder { self.remindersShown++; }
- (UNUserNotificationCenter *)updateNotificationCenter { return (id)self.center; }
@end

@interface RCNotificationResponseFixture : NSObject
@property NSString *actionIdentifier;
@property id notification;
@property id request;
@property NSString *identifier;
@end
@implementation RCNotificationResponseFixture @end

@interface RCUpdateServiceNotificationPolicyTests : XCTestCase
@end

@implementation RCUpdateServiceNotificationPolicyTests

- (void)drainMainQueue {
    XCTestExpectation *drained = [self expectationWithDescription:@"main queue drained"];
    dispatch_async(dispatch_get_main_queue(), ^{ [drained fulfill]; });
    [self waitForExpectations:@[drained] timeout:1];
}

- (void)testNotificationFromPreviousProcessOpensUpdateAndCompletesOnMainQueue {
    RCNotificationTestService *service = [RCNotificationTestService new];
    service.center = [RCNotificationCenterFixture new];
    RCUpdateServiceTestUpdaterController *controller = [RCUpdateServiceTestUpdaterController new];
    [service setValue:controller forKey:@"updaterController"];
    RCNotificationResponseFixture *request = [RCNotificationResponseFixture new];
    request.identifier = @"com.revclip.update-reminder.previous-process";
    RCNotificationResponseFixture *notification = [RCNotificationResponseFixture new];
    notification.request = request;
    RCNotificationResponseFixture *response = [RCNotificationResponseFixture new];
    response.notification = notification;
    response.actionIdentifier = UNNotificationDefaultActionIdentifier;
    XCTestExpectation *completed = [self expectationWithDescription:@"notification handled"];
    [(id<UNUserNotificationCenterDelegate>)service userNotificationCenter:(id)service.center didReceiveNotificationResponse:(id)response withCompletionHandler:^{
        XCTAssertTrue(NSThread.isMainThread);
        [completed fulfill];
    }];
    [self waitForExpectations:@[completed] timeout:1];
    XCTAssertEqual(controller.checkForUpdatesInvocationCount, 1);
    XCTAssertTrue([service.center.removedIdentifiers containsObject:request.identifier]);
}

- (void)testLaunchRegistersNotificationDelegateBeforeAnyUpdateIsFound {
    RCNotificationTestService *service = [RCNotificationTestService new];
    service.center = [RCNotificationCenterFixture new];
    RCUpdateServiceTestUpdaterController *controller = [RCUpdateServiceTestUpdaterController new];
    [service setValue:controller forKey:@"updaterController"];
    [service setupUpdater];
    XCTAssertEqual(service.center.delegate, service);
    XCTAssertNil(service.center.authorizationReply);
}

- (void)testDeniedNotificationPermissionRetainsVisibleReminder {
    RCNotificationTestService *service = [RCNotificationTestService new];
    service.center = [RCNotificationCenterFixture new];
    [service standardUserDriverWillHandleShowingUpdate:NO forUpdate:nil state:[RCReminderTestState new]];
    service.center.authorizationReply(NO, nil);
    [self drainMainQueue];
    XCTAssertEqual(service.remindersShown, 1u);
    XCTAssertTrue([[service valueForKey:@"awaitingUpdateAttention"] boolValue]);
    XCTAssertNil(service.center.request);
    [service standardUserDriverWillFinishUpdateSession];
}

- (void)testDelayedAuthorizationDoesNotNotifyAfterSessionFinishes {
    RCNotificationTestService *service = [RCNotificationTestService new];
    service.center = [RCNotificationCenterFixture new];
    [service standardUserDriverWillHandleShowingUpdate:NO forUpdate:nil state:[RCReminderTestState new]];
    [service standardUserDriverWillFinishUpdateSession];
    service.center.authorizationReply(YES, nil);
    [self drainMainQueue];
    XCTAssertNil(service.center.request);
}

- (void)testLateDeliveryRemovesOldNotificationWithoutRemovingNewSession {
    RCNotificationTestService *service = [RCNotificationTestService new];
    service.center = [RCNotificationCenterFixture new];
    [service standardUserDriverWillHandleShowingUpdate:NO forUpdate:nil state:[RCReminderTestState new]];
    service.center.authorizationReply(YES, nil);
    [self drainMainQueue];
    NSString *oldIdentifier = service.center.request.identifier;
    void (^oldReply)(NSError *) = service.center.deliveryReply;
    [service standardUserDriverWillFinishUpdateSession];
    [service standardUserDriverWillHandleShowingUpdate:NO forUpdate:nil state:[RCReminderTestState new]];
    service.center.authorizationReply(YES, nil);
    [self drainMainQueue];
    NSString *newIdentifier = service.center.request.identifier;
    XCTAssertNotEqualObjects(oldIdentifier, newIdentifier);
    [service.center.removedIdentifiers removeAllObjects];
    oldReply(nil);
    [self drainMainQueue];
    XCTAssertTrue([service.center.removedIdentifiers containsObject:oldIdentifier]);
    XCTAssertFalse([service.center.removedIdentifiers containsObject:newIdentifier]);
    [service standardUserDriverWillFinishUpdateSession];
}

- (void)testRealControllerFactoryWiresGentleReminderDelegate {
    RCUpdateService *service = [RCUpdateService new];
    RCDelegateTestController *controller = [service createUpdaterControllerWithClass:RCDelegateTestController.class];
    XCTAssertEqual(controller.userDriverDelegate, service);
    XCTAssertTrue(service.supportsGentleScheduledUpdateReminders);
    XCTAssertFalse([service standardUserDriverShouldHandleShowingScheduledUpdate:nil andInImmediateFocus:NO]);
    XCTAssertTrue([service standardUserDriverShouldHandleShowingScheduledUpdate:nil andInImmediateFocus:YES]);
}

- (void)testScheduledUpdatePersistsReminderUntilAttentionAndCanRemindNextSession {
    RCReminderTestService *service = [RCReminderTestService new];
    RCReminderTestState *state = [RCReminderTestState new];
    [service standardUserDriverWillHandleShowingUpdate:NO forUpdate:nil state:state];
    [service standardUserDriverWillHandleShowingUpdate:NO forUpdate:nil state:state];
    XCTAssertEqual(service.remindersShown, 1u);
    XCTAssertEqual(service.notificationsRequested, 1u);
    XCTAssertTrue([[service valueForKey:@"awaitingUpdateAttention"] boolValue]);
    [service standardUserDriverDidReceiveUserAttentionForUpdate:nil];
    XCTAssertFalse([[service valueForKey:@"awaitingUpdateAttention"] boolValue]);
    XCTAssertEqual(service.notificationsRemoved, 1u);
    [service standardUserDriverWillHandleShowingUpdate:NO forUpdate:nil state:state];
    XCTAssertEqual(service.remindersShown, 2u);
    [service standardUserDriverWillFinishUpdateSession];
    XCTAssertFalse([[service valueForKey:@"awaitingUpdateAttention"] boolValue]);
}

- (void)testManualUpdateDoesNotCreateExtraReminder {
    RCReminderTestService *service = [RCReminderTestService new];
    RCReminderTestState *state = [RCReminderTestState new];
    state.userInitiated = YES;
    [service standardUserDriverWillHandleShowingUpdate:YES forUpdate:nil state:state];
    state.userInitiated = NO;
    [service standardUserDriverWillHandleShowingUpdate:YES forUpdate:nil state:state];
    XCTAssertEqual(service.remindersShown, 0u);
    XCTAssertEqual(service.notificationsRequested, 0u);
}

- (void)testReminderBringsExistingSessionForwardEvenWhileNewCheckIsUnavailable {
    RCReminderTestService *service = [RCReminderTestService new];
    RCUpdateServiceTestUpdaterController *controller = [RCUpdateServiceTestUpdaterController new];
    controller.updater = [RCUpdateServiceTestUpdater new];
    controller.updater.canCheckForUpdates = NO;
    [service setValue:controller forKey:@"updaterController"];
    [service openUpdateReminder:nil];
    XCTAssertEqual(controller.checkForUpdatesInvocationCount, 1);
}

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
    XCTAssertEqualObjects(service.lastError, error);
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
