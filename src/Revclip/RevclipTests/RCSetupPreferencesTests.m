#import <XCTest/XCTest.h>
#import "RCSetupPreferencesViewController.h"
#import "RCKeyboardShortcutView.h"
#import "RCHotKeyRecorderView.h"
#import "RCHotKeyContractProbe.h"

@interface RCHotKeyAssignmentResult (SetupTesting)
+ (instancetype)resultWithStatus:(RCHotKeyAssignmentStatus)status failedSlot:(NSString *)slot conflictingSlot:(NSString *)conflict osStatus:(OSStatus)statusCode;
@end
@interface RCSetupPreferencesViewController (Testing)
- (RCHotKeyService *)hotKeyService;
- (void)featureChanged:(NSSegmentedControl *)sender;
- (void)refreshShortcuts;
- (void)defaultsChanged:(NSNotification *)notification;
- (NSDictionary *)shortcutState;
@end
@interface RCSetupReadOnlyService : RCHotKeyService
@property RCKeyCombo mainCombo;
@property RCKeyCombo ocrCombo;
@property (copy) NSArray<NSData *> *externalShortcutData;
@end
@implementation RCSetupReadOnlyService
- (NSArray<NSData *> *)rc_cleanShotShortcutData { return self.externalShortcutData ?: @[]; }
- (RCKeyCombo)configuredKeyComboForSlot:(NSString *)slot {
    return [slot isEqualToString:RCHotKeySlotOCR] ? self.ocrCombo : ([slot isEqualToString:RCHotKeySlotMain] ? self.mainCombo : RCInvalidKeyCombo());
}
@end
@interface RCSetupControllerProbe : RCSetupPreferencesViewController
@property (strong) RCSetupReadOnlyService *service;
@end
@implementation RCSetupControllerProbe
- (RCHotKeyService *)hotKeyService { return self.service; }
@end
@interface RCSetupPreferencesTests : XCTestCase
@end
@implementation RCSetupPreferencesTests
- (void)testSetupShowsSavedExternalConflictWhenSelectingClipboardTab {
    RCSetupControllerProbe *controller = [RCSetupControllerProbe new];
    controller.service = [RCSetupReadOnlyService new];
    controller.service.mainCombo = RCMakeKeyCombo(21, cmdKey | shiftKey);
    controller.service.ocrCombo = RCDefaultOCRKeyCombo();
    controller.service.externalShortcutData = @[[@"{\"carbonKey\":21,\"carbonModifiers\":768}" dataUsingEncoding:NSUTF8StringEncoding]];
    (void)controller.view;
    NSSegmentedControl *selector = [controller valueForKey:@"featureSelector"];
    selector.selectedSegment = 1; [controller featureChanged:selector];
    RCHotKeyRecorderView *recorder = [controller valueForKey:@"recorder"];
    XCTAssertTrue([recorder.warningLabel.stringValue containsString:@"CleanShot X"]);
    XCTAssertEqual(recorder.keyCombo.keyCode, 21u);
    selector.selectedSegment = 2; [controller featureChanged:selector];
    XCTAssertEqualObjects(recorder.warningLabel.stringValue, @"");
}
- (void)testSetupStartsWithPermissionsAndSwitchesToSavedShortcuts {
    RCSetupControllerProbe *controller = [RCSetupControllerProbe new];
    controller.service = [RCSetupReadOnlyService new];
    controller.service.mainCombo = [RCHotKeyService defaultKeyComboForSlot:RCHotKeySlotMain];
    controller.service.ocrCombo = [RCHotKeyService defaultKeyComboForSlot:RCHotKeySlotOCR];
    (void)controller.view;
    NSSegmentedControl *selector = [controller valueForKey:@"featureSelector"];
    XCTAssertEqual(selector.segmentCount, 3);
    XCTAssertEqual(selector.selectedSegment, 0);
    NSViewController *permissions = [controller valueForKey:@"permissionsController"];
    XCTAssertEqualObjects([controller valueForKey:@"displayedContent"], permissions.view);
    selector.selectedSegment = 1; [controller featureChanged:selector];
    RCHotKeyRecorderView *recorder = [controller valueForKey:@"recorder"];
    XCTAssertEqual(recorder.keyCombo.keyCode, 9u);
    XCTAssertNil(permissions.view.superview);
    selector.selectedSegment = 2; [controller featureChanged:selector];
    XCTAssertEqual(recorder.keyCombo.keyCode, 19u);
    recorder.warningLabel.stringValue = @"Previous conflict";
    selector.selectedSegment = 0; [controller featureChanged:selector];
    XCTAssertEqualObjects(recorder.warningLabel.stringValue, @"");
    XCTAssertEqualObjects([controller valueForKey:@"permissionsController"], permissions);
    XCTAssertEqualObjects([controller valueForKey:@"displayedContent"], permissions.view);
}
- (void)testDefaultsHighlightVAnd2WithLeftModifiers {
    RCKeyboardShortcutView *view = [RCKeyboardShortcutView new];
    view.keyCombo = [RCHotKeyService defaultKeyComboForSlot:RCHotKeySlotMain];
    XCTAssertEqualObjects(view.highlightedKeyCodes, ([NSSet setWithArray:@[@9,@55,@56]]));
    view.keyCombo = [RCHotKeyService defaultKeyComboForSlot:RCHotKeySlotOCR];
    XCTAssertEqualObjects(view.highlightedKeyCodes, ([NSSet setWithArray:@[@19,@55,@56]]));
}
- (void)testArbitraryCombinationClearedAndExternalKeys {
    RCKeyboardShortcutView *view = [RCKeyboardShortcutView new];
    view.keyCombo = RCMakeKeyCombo(12, controlKey | optionKey);
    XCTAssertEqualObjects(view.highlightedKeyCodes, ([NSSet setWithArray:@[@12,@58,@59]]));
    view.keyCombo = RCInvalidKeyCombo();
    XCTAssertEqual(view.highlightedKeyCodes.count, 0u);
    XCTAssertTrue(NSIsEmptyRect([RCKeyboardShortcutView imageRectForKeyCode:90])); // F20
    XCTAssertTrue(NSIsEmptyRect([RCKeyboardShortcutView imageRectForKeyCode:UINT32_MAX]));
}
- (void)testPhysicalKeyRectanglesStayInsideOriginalImageAndDoNotOverlap {
    NSMutableArray<NSValue *> *rects = [NSMutableArray array];
    for (UInt32 code = 0; code < 128; code++) {
        NSRect rect = [RCKeyboardShortcutView imageRectForKeyCode:code];
        if (NSIsEmptyRect(rect)) continue;
        XCTAssertTrue(NSContainsRect(NSMakeRect(0,0,2546,1046), rect));
        for (NSValue *other in rects) XCTAssertFalse(NSIntersectsRect(rect, other.rectValue));
        [rects addObject:[NSValue valueWithRect:rect]];
    }
    XCTAssertEqual(rects.count, 77u);
    NSURL *url = [NSBundle.mainBundle URLForResource:@"macbook_keyboard" withExtension:@"png"]
        ?: [NSBundle.mainBundle URLForResource:@"macbook_keyboard" withExtension:@"png" subdirectory:@"Keyboard"];
    XCTAssertNotNil(url);
    NSBitmapImageRep *image = [NSBitmapImageRep imageRepWithData:[NSData dataWithContentsOfURL:url]];
    XCTAssertEqual(image.pixelsWide, 2546);
    XCTAssertEqual(image.pixelsHigh, 1046);
}
- (void)testConflictWarningDoesNotFollowUserIntoTheFeatureThatOwnsThoseKeys {
    RCSetupControllerProbe *controller = [RCSetupControllerProbe new];
    controller.service = [RCSetupReadOnlyService new];
    controller.service.mainCombo = [RCHotKeyService defaultKeyComboForSlot:RCHotKeySlotMain];
    controller.service.ocrCombo = [RCHotKeyService defaultKeyComboForSlot:RCHotKeySlotOCR];
    (void)controller.view;
    RCHotKeyRecorderView *recorder = [controller valueForKey:@"recorder"];
    [recorder showAssignmentResult:[RCHotKeyAssignmentResult resultWithStatus:RCHotKeyAssignmentStatusInternalConflict
        failedSlot:RCHotKeySlotMain conflictingSlot:RCHotKeySlotOCR osStatus:0]];
    XCTAssertGreaterThan(recorder.warningLabel.stringValue.length, 0u);
    NSSegmentedControl *selector = [controller valueForKey:@"featureSelector"];
    selector.selectedSegment = 2;
    [controller featureChanged:selector];
    XCTAssertEqual(recorder.keyCombo.keyCode, 19u);
    XCTAssertEqualObjects(recorder.warningLabel.stringValue, @"");
    selector.selectedSegment = 1;
    [controller featureChanged:selector];
    XCTAssertEqualObjects(recorder.warningLabel.stringValue, @"");
}
- (void)testWarningClearsOnReappearanceAndOtherSlotsExternalChange {
    RCSetupControllerProbe *controller = [RCSetupControllerProbe new];
    controller.service = [RCSetupReadOnlyService new];
    controller.service.mainCombo = [RCHotKeyService defaultKeyComboForSlot:RCHotKeySlotMain];
    controller.service.ocrCombo = [RCHotKeyService defaultKeyComboForSlot:RCHotKeySlotOCR];
    (void)controller.view;
    RCHotKeyRecorderView *recorder = [controller valueForKey:@"recorder"];
    recorder.warningLabel.stringValue = @"Old conflict";
    [controller viewWillAppear];
    XCTAssertEqualObjects(recorder.warningLabel.stringValue, @"");
    recorder.warningLabel.stringValue = @"Old conflict";
    [controller setValue:[controller shortcutState] forKey:@"warningShortcutState"];
    [controller defaultsChanged:nil];
    XCTAssertEqualObjects(recorder.warningLabel.stringValue, @"Old conflict");
    controller.service.ocrCombo = RCMakeKeyCombo(12, cmdKey | shiftKey);
    [controller defaultsChanged:nil];
    XCTAssertEqualObjects(recorder.warningLabel.stringValue, @"");
    XCTAssertEqual(recorder.keyCombo.keyCode, 9u);
}
- (void)testSetupReadsSavedValuesAndSwitchesFeatureWithoutChangingThem {
    RCSetupControllerProbe *controller = [RCSetupControllerProbe new];
    controller.service = [RCSetupReadOnlyService new];
    controller.service.mainCombo = RCMakeKeyCombo(12, cmdKey | optionKey);
    controller.service.ocrCombo = RCMakeKeyCombo(3, controlKey | shiftKey);
    (void)controller.view;
    RCKeyboardShortcutView *keyboard = [controller valueForKey:@"keyboard"];
    RCHotKeyRecorderView *recorder = [controller valueForKey:@"recorder"];
    XCTAssertEqual(keyboard.keyCombo.keyCode, 12u);
    XCTAssertEqual(recorder.keyCombo.modifiers, cmdKey | optionKey);
    NSSegmentedControl *selector = [controller valueForKey:@"featureSelector"];
    selector.selectedSegment = 2;
    [controller featureChanged:selector];
    XCTAssertEqual(keyboard.keyCombo.keyCode, 3u);
    XCTAssertEqual(recorder.keyCombo.modifiers, controlKey | shiftKey);
    XCTAssertFalse([[controller valueForKey:@"ocrSettingsButton"] isHidden]);
    controller.service.ocrCombo = RCInvalidKeyCombo();
    [controller refreshShortcuts];
    XCTAssertEqual(keyboard.highlightedKeyCodes.count, 0u);
    selector.selectedSegment = 1;
    [controller featureChanged:selector];
    XCTAssertEqual(keyboard.keyCombo.keyCode, 12u);
    XCTAssertTrue([[controller valueForKey:@"ocrSettingsButton"] isHidden]);
}
@end

@interface RCHotKeyRecorderView (CaptureTesting)
- (BOOL)beginEventCapture;
- (void)endEventCapture;
- (BOOL)recordingContextIsActive;
- (CGEventRef)captureEvent:(CGEventRef)event type:(CGEventType)type;
@end
@interface RCRecordingProbe : RCHotKeyRecorderView <RCHotKeyRecorderViewDelegate>
@property BOOL allowCapture;
@property NSUInteger completed;
@property NSUInteger releases;
@end
@implementation RCRecordingProbe
- (BOOL)beginEventCapture { return self.allowCapture; }
- (void)endEventCapture { self.releases++; [super endEventCapture]; }
- (BOOL)recordingContextIsActive { return YES; }
- (void)hotKeyRecorderView:(RCHotKeyRecorderView *)view didRecordKeyCombo:(RCKeyCombo)combo { self.completed++; }
- (void)hotKeyRecorderViewDidClearKeyCombo:(RCHotKeyRecorderView *)view { self.completed++; }
@end
@interface RCHotKeyRecordingTests : XCTestCase
@end
@implementation RCHotKeyRecordingTests
- (RCRecordingProbe *)recorder {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,300,100)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    RCRecordingProbe *recorder = [[RCRecordingProbe alloc] initWithFrame:NSMakeRect(0,0,180,30)];
    recorder.allowCapture = YES; recorder.delegate = recorder;
    NSTextField *warning = [NSTextField wrappingLabelWithString:@""];
    [window.contentView addSubview:warning]; recorder.warningLabel = warning;
    [window.contentView addSubview:recorder];
    [self addTeardownBlock:^{ [recorder stopRecording]; [window close]; }];
    return recorder;
}
- (void)drain {
    XCTestExpectation *done = [self expectationWithDescription:@"Captured input dispatched"];
    dispatch_async(dispatch_get_main_queue(), ^{ [done fulfill]; });
    [self waitForExpectations:@[done] timeout:2];
}
- (void)sendKey:(UInt16)code down:(BOOL)down to:(RCRecordingProbe *)recorder {
    CGEventRef event = CGEventCreateKeyboardEvent(NULL, code, down);
    CGEventSetFlags(event, kCGEventFlagMaskCommand | kCGEventFlagMaskShift);
    XCTAssertEqual([recorder captureEvent:event type:down ? kCGEventKeyDown : kCGEventKeyUp], NULL);
    CFRelease(event);
}
- (void)testPressAndReleaseAreConsumedAndOnlyOneAssignmentOccurs {
    RCRecordingProbe *recorder = [self recorder];
    [recorder startRecording]; XCTAssertTrue(recorder.isRecording);
    [self sendKey:19 down:YES to:recorder];
    XCTAssertEqual(recorder.completed, 0u);
    [self sendKey:19 down:NO to:recorder];
    XCTAssertEqual(recorder.completed, 0u); // Never validate in the tap callback.
    [self drain];
    XCTAssertEqual(recorder.completed, 1u);
    XCTAssertEqual(recorder.keyCombo.keyCode, 19u);
    XCTAssertFalse(recorder.isRecording);
    XCTAssertGreaterThan(recorder.releases, 0u);
}
- (void)testUnmatchedReleasePassesThroughAndOverlappingKeysFinishTogether {
    RCRecordingProbe *recorder = [self recorder]; [recorder startRecording];
    CGEventRef release = CGEventCreateKeyboardEvent(NULL, 49, false);
    XCTAssertEqual([recorder captureEvent:release type:kCGEventKeyUp], release);
    CFRelease(release);
    CGEventRef repeat = CGEventCreateKeyboardEvent(NULL, 49, true);
    CGEventSetIntegerValueField(repeat, kCGKeyboardEventAutorepeat, 1);
    XCTAssertEqual([recorder captureEvent:repeat type:kCGEventKeyDown], NULL);
    CFRelease(repeat);
    XCTAssertTrue(recorder.isRecording);
    [self sendKey:19 down:YES to:recorder];
    [self sendKey:9 down:YES to:recorder];
    [self sendKey:19 down:NO to:recorder];
    [self drain]; XCTAssertEqual(recorder.completed, 0u);
    [self sendKey:9 down:NO to:recorder];
    [self drain]; XCTAssertEqual(recorder.completed, 1u);
    XCTAssertEqual(recorder.keyCombo.keyCode, 19u);
}
- (void)testAppKitBypassFailsClosedWithoutSaving {
    RCRecordingProbe *recorder = [self recorder];
    recorder.keyCombo = RCMakeKeyCombo(9, cmdKey | shiftKey);
    [recorder startRecording];
    CGEventRef event = CGEventCreateKeyboardEvent(NULL, 19, true);
    CGEventSetFlags(event, kCGEventFlagMaskCommand | kCGEventFlagMaskShift);
    XCTAssertTrue([recorder performKeyEquivalent:[NSEvent eventWithCGEvent:event]]);
    CFRelease(event);
    XCTAssertFalse(recorder.isRecording);
    XCTAssertEqual(recorder.completed, 0u);
    XCTAssertEqual(recorder.keyCombo.keyCode, 9u);
    XCTAssertGreaterThan(recorder.warningLabel.stringValue.length, 0u);
}
- (void)testWarningBelongsToItsPageAndSavedValue {
    RCRecordingProbe *recorder = [self recorder];
    recorder.warningLabel.stringValue = @"Old conflict";
    recorder.keyCombo = RCMakeKeyCombo(9, cmdKey | shiftKey);
    XCTAssertEqualObjects(recorder.warningLabel.stringValue, @"");
    recorder.warningLabel.stringValue = @"Old conflict";
    NSTextField *label = recorder.warningLabel;
    [recorder removeFromSuperview];
    XCTAssertEqualObjects(label.stringValue, @"");
}
- (void)testCancelledQueuedInputCannotChangeANewRecordingSession {
    RCRecordingProbe *recorder = [self recorder];
    [recorder startRecording];
    [self sendKey:19 down:YES to:recorder]; [self sendKey:19 down:NO to:recorder];
    [recorder stopRecording]; [recorder startRecording];
    [self drain];
    XCTAssertEqual(recorder.completed, 0u);
    XCTAssertTrue(recorder.isRecording);
}
- (void)testUnavailableCaptureDoesNotPretendToRecordOrChangeShortcut {
    RCRecordingProbe *recorder = [self recorder];
    recorder.allowCapture = NO; recorder.keyCombo = RCMakeKeyCombo(9, cmdKey | shiftKey);
    [recorder startRecording];
    XCTAssertFalse(recorder.isRecording);
    XCTAssertEqual(recorder.keyCombo.keyCode, 9u);
    XCTAssertGreaterThan(recorder.warningLabel.stringValue.length, 0u);
    XCTAssertNotNil(recorder.warningLabel.textColor);
}
- (void)testFocusLossAndTimeoutReleaseCapture {
    RCRecordingProbe *recorder = [self recorder];
    [recorder startRecording];
    [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidResignKeyNotification object:recorder.window];
    XCTAssertFalse(recorder.isRecording);
    [recorder startRecording];
    [[recorder valueForKey:@"recordingTimeout"] fire];
    XCTAssertFalse(recorder.isRecording);
    XCTAssertNil([recorder valueForKey:@"outsideClickMonitor"]);
}
- (void)testMovingOffPageCancelsAndOnlyOneRecorderCanOwnCapture {
    RCRecordingProbe *first = [self recorder]; RCRecordingProbe *second = [self recorder];
    [first startRecording]; [second startRecording];
    XCTAssertFalse(first.isRecording); XCTAssertTrue(second.isRecording);
    [second removeFromSuperview];
    XCTAssertFalse(second.isRecording);
}
- (void)testDisabledTapIsDestroyedAfterCallbackReturns {
    RCRecordingProbe *recorder = [self recorder]; [recorder startRecording];
    NSUInteger releases = recorder.releases;
    [recorder captureEvent:NULL type:kCGEventTapDisabledByTimeout];
    XCTAssertEqual(recorder.releases, releases);
    [self drain];
    XCTAssertFalse(recorder.isRecording);
    XCTAssertGreaterThan(recorder.releases, releases);
}
- (void)testCarbonActionsAndQueuedCaptureEventsAreSuppressedWithoutReregistering {
    RCHotKeyContractProbe *service = [RCHotKeyContractProbe new];
    __block NSUInteger actions = 0;
    id observer = [NSNotificationCenter.defaultCenter addObserverForName:RCHotKeyMainTriggeredNotification object:service queue:nil usingBlock:^(NSNotification *note) { actions++; }];
    @try {
        NSObject *owner = [NSObject new];
        service.shortcutRecordingOwner = owner;
        [service postNotificationForCarbonHotKeyID:1 eventTime:0];
        XCTAssertEqual(actions, 0u);
        service.shortcutRecordingOwner = nil;
        [service postNotificationForCarbonHotKeyID:1 eventTime:1]; // Old queued press.
        XCTAssertEqual(actions, 0u);
        [service postNotificationForCarbonHotKeyID:1 eventTime:GetCurrentEventTime() + 1];
        XCTAssertEqual(actions, 1u);
        XCTAssertEqual(service.calls.count, 0u);
    } @finally { [NSNotificationCenter.defaultCenter removeObserver:observer]; }
}
@end
