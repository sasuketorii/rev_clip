//
//  RCClipboardPrivacyGateTests.m
//  RevclipTests
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import <XCTest/XCTest.h>

#import "RCClipboardService.h"
#import "RCClipData.h"
#import "RCPrivacyService.h"

@interface RCPrivacyService (Testing)
- (RCClipboardAccessState)accessStateByMappingPasteboardAccessBehavior:(NSInteger)behavior
                                                 privacyAPIAvailable:(BOOL)privacyAPIAvailable;
- (BOOL)shouldCaptureClipboardContentsForAccessState:(RCClipboardAccessState)state;
- (void)presentClipboardAccessGuidanceIfNeeded;
@end

@interface RCClipboardService (Testing)
- (BOOL)canReadPasteboardContentsUsingPrivacyGate;
- (void)captureCurrentClipboardOnMonitoringQueue;
- (void)processClipDataOnMonitoringQueue:(RCClipData *)clipData
                  sourceBundleIdentifier:(NSString *)sourceBundleIdentifier;
@end

@interface RCStubPrivacyService : RCPrivacyService
@property (nonatomic, assign) BOOL captureAllowed;
@property (nonatomic, assign) NSInteger guidanceCallCount;
@end

@implementation RCStubPrivacyService

- (BOOL)shouldCaptureClipboardContents {
    return self.captureAllowed;
}

- (void)showClipboardAccessGuidance {
}

- (void)presentClipboardAccessGuidanceIfNeeded {
    self.guidanceCallCount += 1;
}

@end

@interface RCTestClipboardService : RCClipboardService
@property (nonatomic, assign) NSInteger processClipCallCount;
@end

@implementation RCTestClipboardService

- (void)processClipDataOnMonitoringQueue:(RCClipData *)clipData
                  sourceBundleIdentifier:(NSString *)sourceBundleIdentifier {
    (void)clipData;
    (void)sourceBundleIdentifier;
    self.processClipCallCount += 1;
}

@end

@interface RCClipboardPrivacyGateTests : XCTestCase
@end

@implementation RCClipboardPrivacyGateTests

- (RCPrivacyService *)makePrivacyService {
    return [[RCPrivacyService alloc] init];
}

- (void)testAccessBehaviorMappingWhenPrivacyAPIUnavailableTreatsAccessAsGranted {
    RCPrivacyService *service = [self makePrivacyService];

    XCTAssertEqual([service accessStateByMappingPasteboardAccessBehavior:NSPasteboardAccessBehaviorAlwaysDeny
                                                   privacyAPIAvailable:NO],
                   RCClipboardAccessStateGranted);
}

- (void)testAccessBehaviorMappingOnMacOS154 {
    RCPrivacyService *service = [self makePrivacyService];

    XCTAssertEqual([service accessStateByMappingPasteboardAccessBehavior:NSPasteboardAccessBehaviorDefault
                                                   privacyAPIAvailable:YES],
                   RCClipboardAccessStateNotDetermined);
    XCTAssertEqual([service accessStateByMappingPasteboardAccessBehavior:NSPasteboardAccessBehaviorAsk
                                                   privacyAPIAvailable:YES],
                   RCClipboardAccessStateNotDetermined);
    XCTAssertEqual([service accessStateByMappingPasteboardAccessBehavior:NSPasteboardAccessBehaviorAlwaysAllow
                                                   privacyAPIAvailable:YES],
                   RCClipboardAccessStateGranted);
    XCTAssertEqual([service accessStateByMappingPasteboardAccessBehavior:NSPasteboardAccessBehaviorAlwaysDeny
                                                   privacyAPIAvailable:YES],
                   RCClipboardAccessStateDenied);
    XCTAssertEqual([service accessStateByMappingPasteboardAccessBehavior:99
                                                   privacyAPIAvailable:YES],
                   RCClipboardAccessStateUnknown);
}

- (void)testShouldCaptureAllowsGrantedAndNotDeterminedButNotDeniedOrUnknown {
    RCPrivacyService *service = [self makePrivacyService];

    XCTAssertTrue([service shouldCaptureClipboardContentsForAccessState:RCClipboardAccessStateGranted]);
    XCTAssertTrue([service shouldCaptureClipboardContentsForAccessState:RCClipboardAccessStateNotDetermined]);
    XCTAssertFalse([service shouldCaptureClipboardContentsForAccessState:RCClipboardAccessStateDenied]);
    XCTAssertFalse([service shouldCaptureClipboardContentsForAccessState:RCClipboardAccessStateUnknown]);
}

- (void)testDeniedPrivacySkipsClipboardCapture {
    RCTestClipboardService *clipboard = [[RCTestClipboardService alloc] init];
    RCStubPrivacyService *privacy = [[RCStubPrivacyService alloc] init];
    privacy.captureAllowed = NO;
    [clipboard setValue:privacy forKey:@"privacyService"];

    XCTAssertFalse([clipboard canReadPasteboardContentsUsingPrivacyGate]);

    [clipboard captureCurrentClipboardOnMonitoringQueue];

    XCTAssertEqual(clipboard.processClipCallCount, 0);
    XCTAssertEqual(privacy.guidanceCallCount, 1);
}

- (void)testAllowedPrivacyOpensPasteboardReadGate {
    RCTestClipboardService *clipboard = [[RCTestClipboardService alloc] init];
    RCStubPrivacyService *privacy = [[RCStubPrivacyService alloc] init];
    privacy.captureAllowed = YES;
    [clipboard setValue:privacy forKey:@"privacyService"];

    XCTAssertTrue([clipboard canReadPasteboardContentsUsingPrivacyGate]);
    XCTAssertEqual(privacy.guidanceCallCount, 0);
}

@end
