#import <XCTest/XCTest.h>
#import "RCHotKeyService.h"
#import "RCPanicEraseService.h"
#import "RCConstants.h"
#import <objc/runtime.h>
#import "RCHotKeyContractProbe.h"

@interface RCOCRHotKeyProbe : RCHotKeyService
@property NSUInteger registrations;
@property RCKeyCombo lastCombo;
@end
@implementation RCOCRHotKeyProbe
- (void)installHotKeyEventHandlerIfNeeded { }
- (BOOL)registerHotKeyWithCombo:(RCKeyCombo)combo identifier:(UInt32)identifier storeRef:(EventHotKeyRef *)ref {
    self.registrations++; self.lastCombo = combo; return YES;
}
@end
@implementation RCHotKeyContractProbe
- (instancetype)init {
    if ((self = [super init])) {
        _calls = [NSMutableArray array]; _liveCarbonIDs = [NSMutableDictionary dictionary];
        _refused = [NSMutableSet set]; _systemHotKeys = @[]; _folders = @{}; _nextRef = 0x1000;
    }
    return self;
}
+ (NSString *)key:(RCKeyCombo)combo { return [NSString stringWithFormat:@"%u:%u", (unsigned)combo.keyCode, (unsigned)combo.modifiers]; }
- (void)installHotKeyEventHandlerIfNeeded { }
- (OSStatus)rc_registerEventHotKey:(RCKeyCombo)combo carbonID:(UInt32)carbonID ref:(EventHotKeyRef *)outRef {
    NSString *key = [RCHotKeyContractProbe key:combo];
    // Like the OS: one application cannot hold the same combination twice.
    if ([self.refused containsObject:key] || self.liveCarbonIDs[key]) { [self.calls addObject:[@"refuse " stringByAppendingString:key]]; return eventHotKeyExistsErr; }
    self.liveCarbonIDs[key] = @(carbonID);
    [self.calls addObject:[@"register " stringByAppendingString:key]];
    *outRef = (EventHotKeyRef)(self.nextRef += 0x10);
    objc_setAssociatedObject(self, *outRef, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
    return noErr;
}
- (OSStatus)rc_unregisterEventHotKey:(EventHotKeyRef)ref {
    NSString *key = objc_getAssociatedObject(self, ref);
    if (key) { [self.liveCarbonIDs removeObjectForKey:key]; [self.calls addObject:[@"unregister " stringByAppendingString:key]]; }
    return noErr;
}
- (NSArray<NSDictionary *> *)rc_systemSymbolicHotKeys { return self.systemHotKeys; }
- (NSDictionary<NSString *, NSValue *> *)rc_activeFolderKeyCombos { return self.folders; }
- (BOOL)rc_panicInProgress { return self.panic; }
@end

@interface RCHotKeyContractTests : XCTestCase
@property (nonatomic, strong) RCHotKeyContractProbe *service;
@end
@implementation RCHotKeyContractTests
static RCKeyCombo RCCombo(UInt32 code, UInt32 modifiers) { return RCMakeKeyCombo(code, modifiers); }
- (NSArray<NSString *> *)storageKeys {
    return @[kRCHotKeyMainKeyCombo, kRCHotKeyHistoryKeyCombo, kRCHotKeySnippetKeyCombo, kRCClearHistoryKeyCombo, kRCOCRKeyComboKey, kRCOCREnabledKey, kRCFolderKeyCombos];
}
- (void)setUp {
    [super setUp];
    for (NSString *key in [self storageKeys]) [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
    self.service = [RCHotKeyContractProbe new];
    [self.service loadAndRegisterHotKeysFromDefaults];
    [self.service.calls removeAllObjects];
}
- (void)tearDown {
    [self.service unregisterAllHotKeys];
    for (NSString *key in [self storageKeys]) [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
    self.service = nil;
    [super tearDown];
}
- (RCHotKeyAssignmentResult *)set:(NSString *)slot to:(RCKeyCombo)combo {
    return [self.service applyAssignments:@[[RCHotKeyAssignment assignmentSettingSlot:slot combo:combo]]];
}
- (NSString *)stored:(NSString *)slot { return [RCHotKeyContractProbe key:[self.service configuredKeyComboForSlot:slot]]; }

- (void)testStartUpRegistersEverySlotIncludingOCRThroughOneRegistry {
    NSSet *live = [NSSet setWithArray:self.service.liveCarbonIDs.allKeys];
    XCTAssertEqualObjects(live, ([NSSet setWithArray:@[@"9:768", @"9:4352", @"11:768", @"19:768"]]), @"main, history, snippet, faster OCR");
    XCTAssertEqualObjects([self stored:RCHotKeySlotOCR], @"19:768");
}
- (void)testNewCombinationIsRegisteredBeforeTheOldOneIsReleased {
    RCHotKeyAssignmentResult *result = [self set:RCHotKeySlotMain to:RCCombo(8, cmdKey | optionKey)];
    XCTAssertTrue(result.succeeded);
    XCTAssertEqualObjects(self.service.calls, (@[@"register 8:2304", @"unregister 9:768"]));
    XCTAssertEqualObjects([self stored:RCHotKeySlotMain], @"8:2304");
}
- (void)testInternalConflictNamesTheFeatureAndChangesNothing {
    RCHotKeyAssignmentResult *result = [self set:RCHotKeySlotOCR to:RCCombo(9, cmdKey | shiftKey)];
    XCTAssertEqual(result.status, RCHotKeyAssignmentStatusInternalConflict);
    XCTAssertEqualObjects(result.failedSlot, RCHotKeySlotOCR);
    XCTAssertEqualObjects(result.conflictingSlot, RCHotKeySlotMain);
    XCTAssertEqual(self.service.calls.count, 0u, @"No OS call, no release of the working shortcut");
    XCTAssertEqualObjects([self stored:RCHotKeySlotOCR], @"19:768");
    self.service.folders = @{@"folder-1": [NSValue valueWithBytes:&(RCKeyCombo){3, cmdKey | controlKey} objCType:@encode(RCKeyCombo)]};
    result = [self set:RCHotKeySlotOCR to:RCCombo(3, cmdKey | controlKey)];
    XCTAssertEqualObjects(result.conflictingSlot, @"folder:folder-1");
}
- (void)testTwoSlotsExchangeInOneBatchWithoutAnyOSRegistrationAndDeliveryFollowsTheNewOwner {
    UInt32 oldMainID = self.service.liveCarbonIDs[@"9:768"].unsignedIntValue;
    RCHotKeyAssignmentResult *result = [self.service applyAssignments:@[
        [RCHotKeyAssignment assignmentSettingSlot:RCHotKeySlotMain combo:RCCombo(9, cmdKey | controlKey)],
        [RCHotKeyAssignment assignmentSettingSlot:RCHotKeySlotHistory combo:RCCombo(9, cmdKey | shiftKey)]]];
    XCTAssertTrue(result.succeeded);
    XCTAssertEqual(self.service.calls.count, 0u, @"A live registration changes owner; nothing can fail half way");
    XCTAssertEqualObjects([self stored:RCHotKeySlotMain], @"9:4352");
    XCTAssertEqualObjects([self stored:RCHotKeySlotHistory], @"9:768");
    XCTestExpectation *history = [self expectationForNotification:RCHotKeyHistoryTriggeredNotification object:self.service handler:nil];
    [self.service postNotificationForCarbonHotKeyID:oldMainID eventTime:1];
    [self waitForExpectations:@[history] timeout:2];
    // Each alone would collide with the other's current value.
    XCTAssertEqual([self set:RCHotKeySlotSnippet to:RCCombo(9, cmdKey | shiftKey)].status, RCHotKeyAssignmentStatusInternalConflict);
}
- (void)testOSRefusalKeepsOldRegistrationAndStorageAndReleasesOnlyWhatThisBatchPrepared {
    [self.service.refused addObject:@"5:768"];
    RCHotKeyAssignmentResult *result = [self.service applyAssignments:@[
        [RCHotKeyAssignment assignmentSettingSlot:RCHotKeySlotMain combo:RCCombo(4, cmdKey | shiftKey)],
        [RCHotKeyAssignment assignmentSettingSlot:RCHotKeySlotHistory combo:RCCombo(5, cmdKey | shiftKey)]]];
    XCTAssertEqual(result.status, RCHotKeyAssignmentStatusRegistrationFailed);
    XCTAssertEqualObjects(result.failedSlot, RCHotKeySlotHistory);
    XCTAssertEqual(result.osStatus, (OSStatus)eventHotKeyExistsErr);
    XCTAssertEqualObjects(self.service.calls, (@[@"register 4:768", @"refuse 5:768", @"unregister 4:768"]));
    XCTAssertNotNil(self.service.liveCarbonIDs[@"9:768"]); XCTAssertNotNil(self.service.liveCarbonIDs[@"9:4352"]);
    XCTAssertEqualObjects([self stored:RCHotKeySlotMain], @"9:768");
    XCTAssertEqualObjects([self stored:RCHotKeySlotHistory], @"9:4352");
}
- (void)testPrepareCanBeDiscardedForAnotherFallibleStepAndCommitCannotFail {
    id transaction = nil;
    RCHotKeyAssignmentResult *result = [self.service prepareAssignments:@[[RCHotKeyAssignment assignmentSettingSlot:RCHotKeySlotMain combo:RCCombo(6, cmdKey | shiftKey)]]
                                                   ocrEnabledAfterCommit:nil transaction:&transaction];
    XCTAssertTrue(result.succeeded); XCTAssertNotNil(transaction);
    XCTAssertEqualObjects([self stored:RCHotKeySlotMain], @"9:768", @"Nothing is stored by prepare");
    XCTAssertNotNil(self.service.liveCarbonIDs[@"9:768"], @"The working shortcut stays registered");
    [self.service discardPreparedAssignments:transaction];
    XCTAssertEqualObjects(self.service.calls, (@[@"register 6:768", @"unregister 6:768"]));
    [self.service commitPreparedAssignments:transaction];
    XCTAssertEqualObjects([self stored:RCHotKeySlotMain], @"9:768", @"A finished transaction cannot be committed later");
}
- (void)testEnabledSystemShortcutIsRefusedWithoutANameAndDisabledOnesAreNot {
    self.service.systemHotKeys = @[@{@"kHISymbolicHotKeyCode": @20, @"kHISymbolicHotKeyModifiers": @(cmdKey | shiftKey), @"kHISymbolicHotKeyEnabled": @YES},
                                   @{@"kHISymbolicHotKeyCode": @21, @"kHISymbolicHotKeyModifiers": @(cmdKey | shiftKey), @"kHISymbolicHotKeyEnabled": @NO}];
    RCHotKeyAssignmentResult *result = [self set:RCHotKeySlotOCR to:RCCombo(20, cmdKey | shiftKey)];
    XCTAssertEqual(result.status, RCHotKeyAssignmentStatusSystemReserved);
    XCTAssertNil(result.conflictingSlot);
    XCTAssertEqual(self.service.calls.count, 0u);
    XCTAssertTrue([self set:RCHotKeySlotOCR to:RCCombo(21, cmdKey | shiftKey)].succeeded);
    // A value already in use is not taken away by a later system setting.
    self.service.systemHotKeys = @[@{@"kHISymbolicHotKeyCode": @21, @"kHISymbolicHotKeyModifiers": @(cmdKey | shiftKey), @"kHISymbolicHotKeyEnabled": @YES}];
    XCTAssertTrue([self set:RCHotKeySlotOCR to:RCCombo(21, cmdKey | shiftKey)].succeeded);
}
- (void)testClearDefaultInvalidAndPanic {
    XCTAssertTrue([self.service applyAssignments:@[[RCHotKeyAssignment assignmentClearingSlot:RCHotKeySlotMain]]].succeeded);
    XCTAssertFalse(RCIsValidKeyCombo([self.service configuredKeyComboForSlot:RCHotKeySlotMain]), @"Explicitly cleared, not reset to the default");
    XCTAssertNil(self.service.liveCarbonIDs[@"9:768"]);
    XCTAssertTrue([self.service applyAssignments:@[[RCHotKeyAssignment assignmentRestoringDefaultForSlot:RCHotKeySlotMain]]].succeeded);
    XCTAssertNotNil(self.service.liveCarbonIDs[@"9:768"]);
    XCTAssertEqual([self set:RCHotKeySlotMain to:RCCombo(9, 0)].status, RCHotKeyAssignmentStatusInvalid, @"A modifier is required");
    XCTAssertEqual([self set:RCHotKeySlotMain to:RCCombo(200, cmdKey)].status, RCHotKeyAssignmentStatusInvalid);
    XCTAssertEqual([self set:@"panic" to:RCCombo(9, cmdKey)].status, RCHotKeyAssignmentStatusInvalid, @"Unknown slot");
    if (@available(macOS 15.0, *)) XCTAssertEqual([self set:RCHotKeySlotMain to:RCCombo(9, optionKey | shiftKey)].status, RCHotKeyAssignmentStatusInvalid);
    NSArray *twice = @[[RCHotKeyAssignment assignmentClearingSlot:RCHotKeySlotMain], [RCHotKeyAssignment assignmentClearingSlot:RCHotKeySlotMain]];
    XCTAssertEqual([self.service applyAssignments:twice].status, RCHotKeyAssignmentStatusInvalid);
    self.service.panic = YES; [self.service.calls removeAllObjects];
    XCTAssertEqual([self set:RCHotKeySlotMain to:RCCombo(7, cmdKey | shiftKey)].status, RCHotKeyAssignmentStatusUnavailable);
    XCTAssertEqual(self.service.calls.count, 0u);
}
- (void)testFasterOCRSwitchInTheSameRequestDecidesRegistrationNotThePresentSwitch {
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:kRCOCREnabledKey];
    [self.service reloadOCRHotKey];
    XCTAssertNil(self.service.liveCarbonIDs[@"19:768"]); [self.service.calls removeAllObjects];
    // Off and staying off: stored, not registered.
    XCTAssertTrue([self set:RCHotKeySlotOCR to:RCCombo(18, cmdKey | shiftKey)].succeeded);
    XCTAssertEqual(self.service.calls.count, 0u);
    // Off now, on after the request: the new combination is registered by prepare.
    id transaction = nil;
    XCTAssertTrue([self.service prepareAssignments:@[[RCHotKeyAssignment assignmentSettingSlot:RCHotKeySlotOCR combo:RCCombo(17, cmdKey | shiftKey)]]
                              ocrEnabledAfterCommit:@YES transaction:&transaction].succeeded);
    XCTAssertEqualObjects(self.service.calls, (@[@"register 17:768"]));
    [self.service commitPreparedAssignments:transaction];
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:kRCOCREnabledKey];
    // The observer of that write re-evaluates the hot key: already final, so untouched.
    [self.service reloadOCRHotKey];
    XCTAssertEqualObjects(self.service.calls, (@[@"register 17:768"]));
    // On now, off after the request: released, and nothing new is registered.
    [self.service.calls removeAllObjects];
    XCTAssertTrue([self.service prepareAssignments:@[[RCHotKeyAssignment assignmentKeepingSlot:RCHotKeySlotOCR]]
                              ocrEnabledAfterCommit:@NO transaction:&transaction].succeeded);
    [self.service commitPreparedAssignments:transaction];
    XCTAssertEqualObjects(self.service.calls, (@[@"unregister 17:768"]));
    XCTAssertEqualObjects([self stored:RCHotKeySlotOCR], @"17:768", @"Keeping a slot never rewrites its stored value");
}
- (void)testStorageObserverReenteringDuringCommitCannotDisturbTheNewRegistrations {
    id token = [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        [self.service reloadOCRHotKey];
    }];
    NSArray *exchange = @[[RCHotKeyAssignment assignmentSettingSlot:RCHotKeySlotOCR combo:RCCombo(9, cmdKey | shiftKey)],
                          [RCHotKeyAssignment assignmentSettingSlot:RCHotKeySlotMain combo:RCCombo(19, cmdKey | shiftKey)]];
    RCHotKeyAssignmentResult *result = nil;
    @try { result = [self.service applyAssignments:exchange]; }
    @finally { [NSNotificationCenter.defaultCenter removeObserver:token]; }
    XCTAssertTrue(result.succeeded);
    XCTAssertEqual(self.service.calls.count, 0u, @"An exchange, and the re-entrant reload found the final state");
    XCTAssertEqualObjects([self stored:RCHotKeySlotOCR], @"9:768");
}
- (void)testDuplicateStoredByAnOlderVersionCanAlwaysBeLeftBySwitchingOffOrClearing {
    [RCHotKeyService saveKeyCombo:RCCombo(9, cmdKey | shiftKey) toUserDefaults:kRCOCRKeyComboKey]; // same as Main
    id transaction = nil;
    // Switching on would register the duplicate: refused, by name.
    RCHotKeyAssignmentResult *on = [self.service prepareAssignments:@[[RCHotKeyAssignment assignmentKeepingSlot:RCHotKeySlotOCR]]
                                               ocrEnabledAfterCommit:@YES transaction:&transaction];
    XCTAssertEqual(on.status, RCHotKeyAssignmentStatusInternalConflict); XCTAssertNil(transaction);
    // Switching off is never refused.
    RCHotKeyAssignmentResult *off = [self.service prepareAssignments:@[[RCHotKeyAssignment assignmentKeepingSlot:RCHotKeySlotOCR]]
                                                ocrEnabledAfterCommit:@NO transaction:&transaction];
    XCTAssertTrue(off.succeeded);
    [self.service commitPreparedAssignments:transaction];
    XCTAssertNotNil(self.service.liveCarbonIDs[@"9:768"], @"Main keeps working");
    // Neither is clearing, nor choosing a free combination.
    XCTAssertTrue([self.service applyAssignments:@[[RCHotKeyAssignment assignmentClearingSlot:RCHotKeySlotOCR]]].succeeded);
    XCTAssertTrue([self set:RCHotKeySlotOCR to:RCCombo(19, cmdKey | shiftKey)].succeeded);
    XCTAssertEqual([self set:RCHotKeySlotOCR to:RCCombo(9, cmdKey | shiftKey)].status, RCHotKeyAssignmentStatusInternalConflict,
                   @"A newly chosen value is still checked");
}
- (void)testLegacyDuplicateAtStartUpIsReportedByFeatureNameAndFoldersYieldToFixedSlots {
    [RCHotKeyService saveKeyCombo:RCCombo(9, cmdKey | shiftKey) toUserDefaults:kRCOCRKeyComboKey];
    [self.service unregisterAllHotKeys]; [self.service.calls removeAllObjects];
    XCTestExpectation *reported = [self expectationForNotification:RCHotKeyRegistrationDidFailNotification object:self.service handler:^BOOL(NSNotification *note) {
        return [note.userInfo[RCHotKeyRegistrationFailureIdentifierUserInfoKey] isEqual:@5]
            && [note.userInfo[RCHotKeyRegistrationFailureConflictingSlotUserInfoKey] isEqual:RCHotKeySlotMain];
    }];
    [self.service loadAndRegisterHotKeysFromDefaults];
    [self waitForExpectations:@[reported] timeout:2];
    XCTAssertFalse([self.service.calls containsObject:@"refuse 9:768"], @"Found in Revclip's own registry, never sent to the OS twice");
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kRCOCRKeyComboKey];
    [self.service reloadOCRHotKey];
    XCTAssertFalse([self.service registerSnippetFolderHotKey:RCCombo(19, cmdKey | shiftKey) forFolderIdentifier:@"folder-2"], @"faster OCR holds it");
    XCTAssertNil([NSUserDefaults.standardUserDefaults dictionaryForKey:kRCFolderKeyCombos][@"folder-2"]);
}
@end

@interface RCOCRHotKeyTests : XCTestCase
@end
@implementation RCOCRHotKeyTests
- (void)testPanicDefaultsResetCannotReregisterOCRAndExplicitUnsetIsRespected {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    RCOCRHotKeyProbe *service = RCOCRHotKeyProbe.new;
    @try {
        [defaults removeObjectForKey:@"RCOCRKeyCombo"];
        [defaults setBool:NO forKey:@"RCOCREnabled"];
        [service reloadOCRHotKey]; XCTAssertEqual(service.registrations,0u);
        [service unregisterAllHotKeys];
        [RCPanicEraseService.shared setValue:@YES forKey:@"isPanicInProgress"];
        // Panic removes the defaults domain; the enabled fallback must not
        // reopen the producer while a failed Panic retains its write barrier.
        [defaults removeObjectForKey:@"RCOCREnabled"];
        [service reloadOCRHotKey]; XCTAssertEqual(service.registrations,0u);
        [RCPanicEraseService.shared setValue:@NO forKey:@"isPanicInProgress"];
        [service reloadOCRHotKey]; XCTAssertEqual(service.registrations,1u);
        XCTAssertEqual(service.lastCombo.keyCode,19u);
        XCTAssertEqual(service.lastCombo.modifiers,(UInt32)(cmdKey | shiftKey));
        [defaults setObject:@{@"keyCode":@0,@"modifiers":@0} forKey:@"RCOCRKeyCombo"];
        [service reloadOCRHotKey]; XCTAssertEqual(service.registrations,1u);
    } @finally {
        [RCPanicEraseService.shared setValue:@NO forKey:@"isPanicInProgress"];
        [defaults removeObjectForKey:@"RCOCREnabled"];
        [defaults removeObjectForKey:@"RCOCRKeyCombo"];
    }
}
@end
