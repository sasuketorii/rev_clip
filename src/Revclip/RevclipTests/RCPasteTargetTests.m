#import <XCTest/XCTest.h>
#import "RCPasteService.h"
#import "RCClipData.h"
#import "RCClipboardService.h"
#import "RCConstants.h"

// In-memory boundaries only: no general/named clipboard, workspace, AX, defaults,
// singleton initialization, application activation, event tap or Keychain access.
@interface RCPasteBoardProbe : NSObject
@property NSInteger changeCount;
@property BOOL failWrite;
@property(copy) NSString *text;
@end
@implementation RCPasteBoardProbe
- (NSInteger)clearContents { self.text = nil; return ++self.changeCount; }
- (BOOL)setString:(NSString *)value forType:(NSString *)type {
    if (self.failWrite) return NO;
    self.text = value; ++self.changeCount; return YES;
}
@end
@interface RCPasteRecorder : NSObject
@property(strong) NSMutableArray<NSNumber *> *counts;
@property BOOL recordedOnMain;
@end
@implementation RCPasteRecorder
- (instancetype)init { if ((self = [super init])) _counts = [NSMutableArray array]; return self; }
- (void)recordInternalPasteboardChangeCount:(NSInteger)count {
    [self.counts addObject:@(count)]; self.recordedOnMain = NSThread.isMainThread;
}
@end
@interface RCTargetProbe : NSObject
@property(getter=isActive) BOOL active;
@property(getter=isTerminated) BOOL terminated;
@property pid_t processIdentifier;
@property(copy) NSString *bundleIdentifier;
@property(strong) id focus;
@end
@implementation RCTargetProbe
@end
@interface RCPasteProbe : RCPasteService
@property NSUInteger sent;
@property NSUInteger activations;
@property NSUInteger focusReads;
@property BOOL sendEnabled;
@property BOOL plainModifier;
@property BOOL activationSucceeds;
@property BOOL activationBecomesReady;
@property NSTimeInterval now;
@property(strong) RCPasteBoardProbe *board;
@property(strong) RCPasteRecorder *recorder;
@property(strong) RCTargetProbe *front;
@property(strong) NSMutableArray<dispatch_block_t> *work;
@property(copy) dispatch_block_t focusReadHook;
@end
@implementation RCPasteProbe
- (instancetype)init {
    if ((self = [super init])) {
        _board = [RCPasteBoardProbe new]; _board.changeCount = 10;
        _recorder = [RCPasteRecorder new]; _work = [NSMutableArray array];
        _sendEnabled = YES; _activationSucceeds = YES; _activationBecomesReady = YES;
    }
    return self;
}
- (NSPasteboard *)pasteboard { return (id)self.board; }
- (RCClipboardService *)clipboardService { return (id)self.recorder; }
- (NSRunningApplication *)frontmostApplication { return (id)self.front; }
- (id)focusedElementForApplication:(NSRunningApplication *)application {
    self.focusReads++;
    if (self.focusReadHook) self.focusReadHook();
    return ((RCTargetProbe *)(id)application).focus;
}
- (BOOL)activateApplication:(NSRunningApplication *)application {
    self.activations++;
    if (self.activationSucceeds && self.activationBecomesReady) {
        ((RCTargetProbe *)(id)application).active = YES; self.front = (id)application;
    }
    return self.activationSucceeds;
}
- (NSTimeInterval)pasteClock { return self.now; }
- (void)scheduleAfterDelay:(NSTimeInterval)delay block:(dispatch_block_t)block {
    [self.work addObject:^{ self.now += delay; block(); }];
}
- (void)sendPasteKeyStroke { self.sent++; }
- (BOOL)boolPreferenceForKey:(NSString *)key defaultValue:(BOOL)value {
    return [key isEqual:kRCPrefInputPasteCommandKey] ? self.sendEnabled : value;
}
- (NSInteger)integerPreferenceForKey:(NSString *)key defaultValue:(NSInteger)value { return value; }
- (BOOL)isPressedModifier:(NSInteger)flag { return self.plainModifier; }
- (void)runNext {
    if (!self.work.count) return;
    dispatch_block_t block = self.work.firstObject; [self.work removeObjectAtIndex:0]; block();
}
- (void)drain {
    NSUInteger limit = 100;
    while (self.work.count && limit--) [self runNext];
    NSAssert(self.work.count == 0, @"Paste scheduling must be bounded");
}
@end
@interface RCPasteClipProbe : RCClipData
@property NSUInteger writes;
@end
@implementation RCPasteClipProbe
- (BOOL)writeToPasteboard:(NSPasteboard *)board {
    self.writes++; [board clearContents]; return [board setString:@"synthetic-rich" forType:NSPasteboardTypeString];
}
@end
@interface RCPasteTargetTests : XCTestCase
@end
@implementation RCPasteTargetTests
- (void)onMain:(void (^)(void))block {
    if (NSThread.isMainThread) block(); else dispatch_sync(dispatch_get_main_queue(), block);
}
- (RCTargetProbe *)targetWithPID:(pid_t)pid {
    RCTargetProbe *target = [RCTargetProbe new];
    target.active = YES; target.processIdentifier = pid;
    target.bundleIdentifier = [NSString stringWithFormat:@"test.synthetic.%d", pid];
    target.focus = @"synthetic-field-A";
    return target;
}
- (RCPasteProbe *)service {
    RCPasteProbe *service = [RCPasteProbe new]; service.front = [self targetWithPID:1234567]; return service;
}
- (void)testMatchingGenerationClipboardAndFrontmostTargetSendOnce {
    [self onMain:^{
        RCPasteProbe *s = [self service]; [s pastePlainText:@"synthetic" toApplication:(id)s.front];
        XCTAssertEqualObjects(s.recorder.counts, (@[@12])); XCTAssertTrue(s.recorder.recordedOnMain);
        XCTAssertEqual(s.sent, 0u); [s drain]; XCTAssertEqual(s.sent, 1u); XCTAssertEqual(s.activations, 0u);
    }];
}
- (void)testExternalClipboardChangeCancelsPendingPaste {
    [self onMain:^{
        RCPasteProbe *s = [self service]; [s pastePlainText:@"internal" toApplication:(id)s.front];
        s.board.changeCount++; s.board.text = @"external"; [s drain];
        XCTAssertEqual(s.sent, 0u); XCTAssertEqualObjects(s.board.text, @"external");
        XCTAssertEqualObjects(s.recorder.counts, (@[@12]));
    }];
}
- (void)testDifferentFrontmostApplicationCancelsEvenIfTargetReportsActive {
    [self onMain:^{
        RCPasteProbe *s = [self service]; [s pastePlainText:@"synthetic" toApplication:(id)s.front];
        s.front = [self targetWithPID:1234568]; [s drain];
        XCTAssertEqual(s.sent, 0u); XCTAssertEqual(s.activations, 0u);
    }];
}
- (void)testNewGenerationSupersedesOldWithoutCancellingNewRequest {
    [self onMain:^{
        RCPasteProbe *s = [self service]; [s pastePlainText:@"first"]; [s pastePlainText:@"second"];
        [s drain]; XCTAssertEqual(s.sent, 1u); XCTAssertEqualObjects(s.board.text, @"second");
        XCTAssertEqualObjects(s.recorder.counts, (@[@12, @14]));
    }];
}
- (void)testTerminatedExplicitTargetNeverFallsBackToAnotherApplication {
    [self onMain:^{
        RCPasteProbe *s = [self service]; RCTargetProbe *target = s.front;
        [s pastePlainText:@"synthetic" toApplication:(id)target]; target.terminated = YES;
        s.front = [self targetWithPID:1234568]; [s drain]; XCTAssertEqual(s.sent, 0u);
        [s pastePlainText:@"again" toApplication:(id)target]; [s drain]; XCTAssertEqual(s.sent, 0u);
    }];
}
- (void)testNilTargetIsResolvedOnceAndMissingOrOwnTargetIsCopyOnly {
    [self onMain:^{
        RCPasteProbe *s = [self service]; [s pastePlainText:@"resolved"]; [s drain]; XCTAssertEqual(s.sent, 1u);
        s.front = nil; [s pastePlainText:@"missing"]; [s drain]; XCTAssertEqual(s.sent, 1u);
        s.front = [self targetWithPID:NSProcessInfo.processInfo.processIdentifier];
        [s pastePlainText:@"own"]; [s drain]; XCTAssertEqual(s.sent, 1u);
        XCTAssertEqualObjects(s.board.text, @"own");
    }];
}
- (void)testStaleMenuTargetDoesNotStealOtherExternalApplicationFocus {
    [self onMain:^{
        RCPasteProbe *s = [self service]; RCTargetProbe *old = s.front;
        s.front = [self targetWithPID:1234568]; [s pastePlainText:@"synthetic" toApplication:(id)old];
        [s drain]; XCTAssertEqual(s.sent, 0u); XCTAssertEqual(s.activations, 0u);
    }];
}
- (void)testChangedOrLostPreviouslyKnownFocusedElementCancels {
    [self onMain:^{
        RCPasteProbe *s = [self service]; [s pastePlainText:@"synthetic"];
        s.front.focus = @"different-field"; [s drain]; XCTAssertEqual(s.sent, 0u);
        [s pastePlainText:@"known-field"]; s.front.focus = nil; [s drain]; XCTAssertEqual(s.sent, 0u);
        XCTAssertEqualObjects(s.board.text, @"known-field");
    }];
}
- (void)testApplicationWithoutAXFocusedElementRetainsAppLevelPaste {
    [self onMain:^{
        RCPasteProbe *s = [self service]; s.front.focus = nil;
        [s pastePlainText:@"non-AX"]; [s drain]; XCTAssertEqual(s.sent, 1u);
    }];
}
- (void)testClipboardChangeDuringFocusValidationCancels {
    [self onMain:^{
        RCPasteProbe *s = [self service]; [s pastePlainText:@"synthetic"];
        __weak RCPasteProbe *weak = s;
        s.focusReadHook = ^{ weak.board.changeCount++; };
        [s drain]; XCTAssertEqual(s.sent, 0u);
    }];
}
- (void)testCopyOnlyStillRegistersActualCountWithoutFocusWork {
    [self onMain:^{
        RCPasteProbe *s = [self service]; s.sendEnabled = NO; [s pastePlainText:@"copy-only"];
        [s drain]; XCTAssertEqualObjects(s.recorder.counts, (@[@12]));
        XCTAssertEqual(s.sent, 0u); XCTAssertEqual(s.focusReads, 0u);
    }];
}
- (void)testFailedWriteRegistersClearedCountButNeverSends {
    [self onMain:^{
        RCPasteProbe *s = [self service]; s.board.failWrite = YES; [s pastePlainText:@"failure"];
        [s drain]; XCTAssertEqual(s.sent, 0u); XCTAssertEqualObjects(s.recorder.counts, (@[@11]));
    }];
}
- (void)testRichAndModifierPlainPathsUseSameInjectedBoardAndCountRegistration {
    [self onMain:^{
        RCPasteProbe *s = [self service]; RCPasteClipProbe *clip = [RCPasteClipProbe new]; clip.stringValue = @"plain";
        [s pasteClipData:clip]; [s drain]; XCTAssertEqual(clip.writes, 1u); XCTAssertEqualObjects(s.board.text, @"synthetic-rich");
        s.plainModifier = YES; [s pasteClipData:clip]; [s drain];
        XCTAssertEqual(clip.writes, 1u); XCTAssertEqualObjects(s.board.text, @"plain");
        XCTAssertEqualObjects(s.recorder.counts, (@[@12, @14])); XCTAssertEqual(s.sent, 2u);
    }];
}
- (void)testActivationFromOwnAppOccursOnceAndWaitIsBounded {
    [self onMain:^{
        RCPasteProbe *s = [self service]; RCTargetProbe *target = s.front; target.active = NO;
        s.front = [self targetWithPID:NSProcessInfo.processInfo.processIdentifier];
        [s pastePlainText:@"activate" toApplication:(id)target]; [s drain];
        XCTAssertEqual(s.sent, 1u); XCTAssertEqual(s.activations, 1u);
        target.active = NO; s.front = [self targetWithPID:NSProcessInfo.processInfo.processIdentifier];
        s.activationBecomesReady = NO; [s pastePlainText:@"timeout" toApplication:(id)target]; [s drain];
        XCTAssertEqual(s.sent, 1u); XCTAssertEqual(s.activations, 2u); XCTAssertLessThan(s.now, 1.0);
    }];
}
- (void)testFocusSwitchDuringActivationWaitCancelsWithoutReactivation {
    [self onMain:^{
        RCPasteProbe *s = [self service]; RCTargetProbe *target = s.front; target.active = NO;
        s.front = [self targetWithPID:NSProcessInfo.processInfo.processIdentifier]; s.activationBecomesReady = NO;
        [s pastePlainText:@"wait" toApplication:(id)target]; [s runNext];
        s.front = [self targetWithPID:1234568]; [s drain];
        XCTAssertEqual(s.sent, 0u); XCTAssertEqual(s.activations, 1u);
    }];
}
- (void)testDelayedFirstCallbackDoesNotRenewDeadlineOrActivate {
    [self onMain:^{
        RCPasteProbe *s = [self service]; RCTargetProbe *target = s.front; target.active = NO;
        s.front = [self targetWithPID:NSProcessInfo.processInfo.processIdentifier];
        [s pastePlainText:@"delayed" toApplication:(id)target];
        s.now = 1.0; [s drain];
        XCTAssertEqual(s.activations, 0u); XCTAssertEqual(s.sent, 0u);
        XCTAssertEqual(s.focusReads, 1u, @"Expired callbacks must not start another AX query");
        XCTAssertEqualObjects(s.board.text, @"delayed");
    }];
}
- (void)testAXCrossingRequestDeadlineCancelsPreparationAndReadiness {
    [self onMain:^{
        // Cross the deadline in initial preparation, pre-activation validation,
        // or readiness validation. No real AX call or wall-clock wait occurs.
        for (NSUInteger crossingRead = 1; crossingRead <= 3; crossingRead++) {
            RCPasteProbe *s = [self service];
            __weak RCPasteProbe *weak = s;
            s.focusReadHook = ^{ if (weak.focusReads == crossingRead) weak.now = 1.0; };
            [s pastePlainText:@"slow-AX"]; [s drain];
            XCTAssertEqual(s.sent, 0u); XCTAssertEqual(s.activations, 0u);
            XCTAssertEqual(s.focusReads, crossingRead);
            XCTAssertEqualObjects(s.recorder.counts, (@[@12]));
        }
    }];
}
- (void)testTargetBecomingActiveAfterDeadlineDoesNotSend {
    [self onMain:^{
        RCPasteProbe *s = [self service]; RCTargetProbe *target = s.front; target.active = NO;
        s.front = [self targetWithPID:NSProcessInfo.processInfo.processIdentifier];
        s.activationBecomesReady = NO;
        [s pastePlainText:@"late-active" toApplication:(id)target]; [s runNext];
        XCTAssertEqual(s.activations, 1u);
        NSUInteger readsBeforeExpiry = s.focusReads;
        s.now = 0.55; target.active = YES; s.front = target;
        [s drain];
        XCTAssertEqual(s.sent, 0u); XCTAssertEqual(s.activations, 1u);
        XCTAssertEqual(s.focusReads, readsBeforeExpiry);
    }];
}
@end
