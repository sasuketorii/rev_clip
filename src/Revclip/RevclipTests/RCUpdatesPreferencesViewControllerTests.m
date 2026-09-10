//
//  RCUpdatesPreferencesViewControllerTests.m
//  RevclipTests
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <XCTest/XCTest.h>

#import "RCUpdateService.h"
#import "RCUpdatesPreferencesViewController.h"

@interface RCUpdatesPreferencesViewController (Testing)
- (BOOL)shouldShowFailureAlertForUpdateCheck:(NSInteger)updateCheck;
- (void)handleUpdateServiceFailureNotification:(NSNotification *)notification;
- (IBAction)checkNowClicked:(id)sender;
- (void)cancelCheckCompletionTimer;
- (RCUpdateServiceUpdateCheck)normalizedUpdateCheckFromNotification:(NSNotification *)notification;
@property (nonatomic, strong, nullable) dispatch_source_t checkCompletionTimer;
@end

@interface RCUpdatesPreferencesViewControllerTests : XCTestCase
@end

@interface RCUpdatesPreferencesViewControllerProbe : RCUpdatesPreferencesViewController
@property (nonatomic, assign) NSInteger receivedFailureNotificationCount;
@end

@implementation RCUpdatesPreferencesViewControllerProbe

- (void)handleUpdateServiceFailureNotification:(NSNotification *)notification {
    self.receivedFailureNotificationCount += 1;
    [super handleUpdateServiceFailureNotification:notification];
}

@end

static BOOL RCMockCheckForUpdatesReturnNO(__unused id self, __unused SEL _cmd) {
    return NO;
}

static BOOL RCMockCheckForUpdatesPostsFailureAndReturnsNO(id self, __unused SEL _cmd) {
    NSError *error = [NSError errorWithDomain:@"SUSparkleErrorDomain"
                                         code:55
                                     userInfo:@{ NSLocalizedDescriptionKey: @"manual failure" }];
    NSDictionary<NSString *, id> *userInfo = @{
        RCUpdateServiceErrorUserInfoKey: error,
        RCUpdateServiceFailureReasonUserInfoKey: @"Update check failed.",
        RCUpdateServiceUpdateCheckUserInfoKey: @(RCUpdateServiceUpdateCheckUpdates),
    };
    [[NSNotificationCenter defaultCenter] postNotificationName:RCUpdateServiceDidFailNotification
                                                        object:self
                                                      userInfo:userInfo];
    return NO;
}

@implementation RCUpdatesPreferencesViewControllerTests

- (IMP)replaceCheckForUpdatesImplementation:(IMP)newImplementation {
    Method method = class_getInstanceMethod([RCUpdateService class], @selector(checkForUpdates));
    IMP originalImplementation = method_getImplementation(method);
    method_setImplementation(method, newImplementation);
    return originalImplementation;
}

- (void)restoreCheckForUpdatesImplementation:(IMP)originalImplementation {
    Method method = class_getInstanceMethod([RCUpdateService class], @selector(checkForUpdates));
    method_setImplementation(method, originalImplementation);
}

- (RCUpdatesPreferencesViewController *)controllerWithManualCheckUIInProgress {
    RCUpdatesPreferencesViewController *controller = [[RCUpdatesPreferencesViewController alloc] init];
    controller.view = [[NSView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 120.0, 80.0)];

    NSButton *checkNowButton = [[NSButton alloc] initWithFrame:NSMakeRect(0.0, 0.0, 80.0, 24.0)];
    [controller.view addSubview:checkNowButton];
    checkNowButton.enabled = NO;
    [controller setValue:checkNowButton forKey:@"checkNowButton"];

    NSProgressIndicator *indicator = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(0.0, 0.0, 20.0, 20.0)];
    [controller.view addSubview:indicator];
    indicator.hidden = NO;
    [indicator startAnimation:nil];
    [controller setValue:indicator forKey:@"checkProgressIndicator"];

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, 0);
    controller.checkCompletionTimer = timer;
    dispatch_resume(timer);
    [controller viewDidLoad];
    return controller;
}

- (NSNotification *)failureNotificationWithSender:(id)sender
                                updateCheckObject:(nullable id)updateCheckObject {
    NSError *error = [NSError errorWithDomain:@"SUSparkleErrorDomain"
                                         code:55
                                     userInfo:@{NSLocalizedDescriptionKey: @"manual failure"}];
    NSMutableDictionary<NSString *, id> *userInfo = [NSMutableDictionary dictionary];
    userInfo[RCUpdateServiceErrorUserInfoKey] = error;
    userInfo[RCUpdateServiceFailureReasonUserInfoKey] = @"Update check failed.";
    if (updateCheckObject != nil) {
        userInfo[RCUpdateServiceUpdateCheckUserInfoKey] = updateCheckObject;
    }
    return [NSNotification notificationWithName:RCUpdateServiceDidFailNotification
                                         object:sender
                                       userInfo:userInfo];
}

- (void)testFailureAlertPolicyIsOnlyForManualChecks {
    RCUpdatesPreferencesViewController *controller = [[RCUpdatesPreferencesViewController alloc] init];

    XCTAssertTrue([controller shouldShowFailureAlertForUpdateCheck:RCUpdateServiceUpdateCheckUpdates]);
    XCTAssertFalse([controller shouldShowFailureAlertForUpdateCheck:RCUpdateServiceUpdateCheckUnknown]);
    XCTAssertFalse([controller shouldShowFailureAlertForUpdateCheck:RCUpdateServiceUpdateCheckUpdatesInBackground]);
    XCTAssertFalse([controller shouldShowFailureAlertForUpdateCheck:RCUpdateServiceUpdateCheckUpdateInformation]);
}

- (void)testHandleFailureWithNoWindowReturnsImmediately {
    RCUpdatesPreferencesViewController *controller = [[RCUpdatesPreferencesViewController alloc] init];
    controller.view = [[NSView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 120.0, 80.0)];

    NSError *error = [NSError errorWithDomain:@"SUSparkleErrorDomain"
                                         code:55
                                     userInfo:@{NSLocalizedDescriptionKey: @"manual failure"}];
    NSDictionary<NSString *, id> *userInfo = @{
        RCUpdateServiceErrorUserInfoKey: error,
        RCUpdateServiceFailureReasonUserInfoKey: @"Update check failed.",
        RCUpdateServiceUpdateCheckUserInfoKey: @(RCUpdateServiceUpdateCheckUpdates),
    };
    NSNotification *notification = [NSNotification notificationWithName:RCUpdateServiceDidFailNotification
                                                                 object:[RCUpdateService shared]
                                                               userInfo:userInfo];

    NSDate *started = [NSDate date];
    [controller handleUpdateServiceFailureNotification:notification];
    NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:started];
    XCTAssertLessThan(elapsed, 0.5);
}

- (void)testCheckNowDoesNotStartPollingWhenCheckForUpdatesReturnsNO {
    IMP originalImplementation = [self replaceCheckForUpdatesImplementation:(IMP)RCMockCheckForUpdatesReturnNO];
    @try {
        RCUpdatesPreferencesViewController *controller = [self controllerWithManualCheckUIInProgress];
        [controller checkNowClicked:nil];

        NSButton *checkNowButton = [controller valueForKey:@"checkNowButton"];
        NSProgressIndicator *indicator = [controller valueForKey:@"checkProgressIndicator"];

        XCTAssertNil(controller.checkCompletionTimer);
        XCTAssertTrue(checkNowButton.enabled);
        XCTAssertTrue(indicator.hidden);
    } @finally {
        [self restoreCheckForUpdatesImplementation:originalImplementation];
    }
}

- (void)testSynchronousFailureNotificationInsideCheckForUpdatesDoesNotStartPolling {
    IMP originalImplementation = [self replaceCheckForUpdatesImplementation:(IMP)RCMockCheckForUpdatesPostsFailureAndReturnsNO];
    @try {
        RCUpdatesPreferencesViewController *controller = [self controllerWithManualCheckUIInProgress];
        [controller checkNowClicked:nil];

        NSButton *checkNowButton = [controller valueForKey:@"checkNowButton"];
        NSProgressIndicator *indicator = [controller valueForKey:@"checkProgressIndicator"];

        XCTAssertNil(controller.checkCompletionTimer);
        XCTAssertTrue(checkNowButton.enabled);
        XCTAssertTrue(indicator.hidden);
    } @finally {
        [self restoreCheckForUpdatesImplementation:originalImplementation];
    }
}

- (void)testUpdateCheckNormalizationTreatsMissingNonNumericOutOfRangeAsUnknown {
    RCUpdatesPreferencesViewController *controller = [[RCUpdatesPreferencesViewController alloc] init];

    NSNotification *missing = [self failureNotificationWithSender:[RCUpdateService shared] updateCheckObject:nil];
    NSNotification *nonNumeric = [self failureNotificationWithSender:[RCUpdateService shared] updateCheckObject:@"invalid"];
    NSNotification *outOfRange = [self failureNotificationWithSender:[RCUpdateService shared] updateCheckObject:@(999)];
    NSNotification *manual = [self failureNotificationWithSender:[RCUpdateService shared] updateCheckObject:@(RCUpdateServiceUpdateCheckUpdates)];

    XCTAssertEqual([controller normalizedUpdateCheckFromNotification:missing], RCUpdateServiceUpdateCheckUnknown);
    XCTAssertEqual([controller normalizedUpdateCheckFromNotification:nonNumeric], RCUpdateServiceUpdateCheckUnknown);
    XCTAssertEqual([controller normalizedUpdateCheckFromNotification:outOfRange], RCUpdateServiceUpdateCheckUnknown);
    XCTAssertEqual([controller normalizedUpdateCheckFromNotification:manual], RCUpdateServiceUpdateCheckUpdates);
}

- (void)testUnknownUpdateCheckDoesNotShowFailureAlert {
    RCUpdatesPreferencesViewController *controller = [[RCUpdatesPreferencesViewController alloc] init];
    XCTAssertFalse([controller shouldShowFailureAlertForUpdateCheck:RCUpdateServiceUpdateCheckUnknown]);
}

- (void)testUnknownUpdateCheckRestoresManualCheckUIStateWithoutAlert {
    RCUpdatesPreferencesViewController *controller = [self controllerWithManualCheckUIInProgress];
    NSNotification *notification = [self failureNotificationWithSender:[RCUpdateService shared] updateCheckObject:nil];

    [controller handleUpdateServiceFailureNotification:notification];

    NSButton *checkNowButton = [controller valueForKey:@"checkNowButton"];
    NSProgressIndicator *indicator = [controller valueForKey:@"checkProgressIndicator"];

    XCTAssertTrue(checkNowButton.enabled);
    XCTAssertTrue(indicator.hidden);
    XCTAssertNil(controller.checkCompletionTimer);
}

- (void)testViewDidLoadSubscribesToFailureNotificationFromUpdateServiceOnly {
    RCUpdatesPreferencesViewControllerProbe *controller = [[RCUpdatesPreferencesViewControllerProbe alloc] init];
    controller.view = [[NSView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 120.0, 80.0)];
    [controller viewDidLoad];

    NSDictionary<NSString *, id> *userInfo = @{
        RCUpdateServiceErrorUserInfoKey: [NSError errorWithDomain:@"SUSparkleErrorDomain"
                                                             code:55
                                                         userInfo:@{NSLocalizedDescriptionKey: @"manual failure"}],
        RCUpdateServiceFailureReasonUserInfoKey: @"Update check failed.",
        RCUpdateServiceUpdateCheckUserInfoKey: @(RCUpdateServiceUpdateCheckUpdates),
    };

    [[NSNotificationCenter defaultCenter] postNotificationName:RCUpdateServiceDidFailNotification
                                                        object:[NSObject new]
                                                      userInfo:userInfo];
    XCTAssertEqual(controller.receivedFailureNotificationCount, 0);

    [[NSNotificationCenter defaultCenter] postNotificationName:RCUpdateServiceDidFailNotification
                                                        object:[RCUpdateService shared]
                                                      userInfo:userInfo];
    XCTAssertEqual(controller.receivedFailureNotificationCount, 1);
}

- (void)testHandleFailureFromUnexpectedObjectDoesNotRestoreManualCheckUIState {
    RCUpdatesPreferencesViewController *controller = [self controllerWithManualCheckUIInProgress];
    NSNotification *notification = [self failureNotificationWithSender:[NSObject new]
                                                     updateCheckObject:@(RCUpdateServiceUpdateCheckUpdates)];

    [controller handleUpdateServiceFailureNotification:notification];

    NSButton *checkNowButton = [controller valueForKey:@"checkNowButton"];
    NSProgressIndicator *indicator = [controller valueForKey:@"checkProgressIndicator"];

    XCTAssertFalse(checkNowButton.enabled);
    XCTAssertFalse(indicator.hidden);
    XCTAssertNotNil(controller.checkCompletionTimer);
    [controller cancelCheckCompletionTimer];
}

@end
