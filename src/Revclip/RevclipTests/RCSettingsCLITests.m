#import <XCTest/XCTest.h>
#import "RCSettingsCLIService.h"
#import "RCConstants.h"
#import "RCHotKeyService.h"
#import "RCHotKeyContractProbe.h"

@interface RCSettingsCLIService (Testing)
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
- (BOOL)loginEnabled;
- (NSInteger)loginStatus;
- (BOOL)setLoginEnabled:(BOOL)enabled;
- (NSString *)language;
- (void)applyLanguage:(NSString *)language;
- (BOOL)saveEditor;
- (NSArray *)excludedApplications;
- (void)applyExcludedApplications:(NSArray *)values;
- (void)applyUpdaterValues:(NSDictionary *)values;
- (void)applyAppearance;
- (void)scheduleCleanup;
- (void)performUIAction:(NSString *)action;
- (NSArray<NSString *> *)ocrSupportedLanguages;
- (NSString *)ocrEnableRefusalForLanguage:(NSString *)language;
- (RCKeyCombo)configuredShortcutForSlot:(NSString *)slot;
- (RCHotKeyAssignmentResult *)prepareShortcuts:(NSArray<RCHotKeyAssignment *> *)assignments ocrEnabled:(NSNumber *)ocrEnabled transaction:(id *)transaction;
- (void)commitShortcuts:(id)transaction;
- (void)discardShortcuts:(id)transaction;
@end

// Never mutate standard defaults, real history, login registration, updater or UI.
@interface RCSettingsCLIProbe : RCSettingsCLIService
@property (nonatomic, strong) NSUserDefaults *testDefaults;
@property BOOL loginSucceeds;
@property BOOL editorSaves;
@property BOOL effectsOnMain;
@property NSInteger loginCalls;
@property NSInteger cleanupCalls;
@property NSInteger appearanceCalls;
@property NSInteger languageCalls;
@property NSInteger saveCalls;
@property NSInteger updaterCalls;
@property NSInteger actionCalls;
@property (nonatomic, strong) NSString *selectedLanguage;
@property (nonatomic, strong) NSDictionary *retentionAtCleanup;
@property (nonatomic, strong) XCTestExpectation *actionExpectation;
@property (nonatomic, copy) NSString *lastAction;
// Hot key seam: the real service validates, a fake OS registers. Nothing real is touched.
@property (nonatomic, strong) RCHotKeyService *hotKeys;
@property (nonatomic, strong) NSArray<NSString *> *visionLanguages;
@property BOOL osSupportsOCR;
@property NSInteger prepareCalls;
@property NSInteger commitCalls;
@property NSInteger discardCalls;
@property (nonatomic, strong) NSArray<RCHotKeyAssignment *> *lastAssignments;
@property (nonatomic, strong) NSNumber *lastOCREnabled;
@property (nonatomic, strong) id ocrEnabledStoredAtCommit;
@end
@implementation RCSettingsCLIProbe
- (NSArray<NSString *> *)ocrSupportedLanguages { return self.visionLanguages; }
- (NSString *)ocrEnableRefusalForLanguage:(NSString *)language {
    if (!self.osSupportsOCR) return @"OCR OS Unsupported";
    return [@[@"auto", @"ja-en"] containsObject:language] || [self.visionLanguages containsObject:language] ? nil : @"OCR Enable Unsupported Language";
}
- (RCKeyCombo)configuredShortcutForSlot:(NSString *)slot { return [self.hotKeys configuredKeyComboForSlot:slot]; }
- (RCHotKeyAssignmentResult *)prepareShortcuts:(NSArray<RCHotKeyAssignment *> *)assignments ocrEnabled:(NSNumber *)ocrEnabled transaction:(id *)transaction {
    [self recordThread]; self.prepareCalls++; self.lastAssignments = assignments; self.lastOCREnabled = ocrEnabled;
    return [self.hotKeys prepareAssignments:assignments ocrEnabledAfterCommit:ocrEnabled transaction:transaction];
}
- (void)commitShortcuts:(id)transaction {
    [self recordThread]; self.commitCalls++;
    self.ocrEnabledStoredAtCommit = [self.testDefaults objectForKey:kRCOCREnabledKey] ?: NSNull.null;
    [self.hotKeys commitPreparedAssignments:transaction];
}
- (void)discardShortcuts:(id)transaction { [self recordThread]; self.discardCalls++; [self.hotKeys discardPreparedAssignments:transaction]; }
- (void)recordThread { self.effectsOnMain = self.effectsOnMain && NSThread.isMainThread; }
- (BOOL)loginEnabled { return [self.testDefaults boolForKey:kRCLoginItem]; }
- (NSInteger)loginStatus { return [self loginEnabled] ? 0 : 2; }
- (BOOL)setLoginEnabled:(BOOL)enabled { [self recordThread]; self.loginCalls++; return self.loginSucceeds; }
- (NSString *)language { return self.selectedLanguage ?: @""; }
- (void)applyLanguage:(NSString *)language { [self recordThread]; self.languageCalls++; self.selectedLanguage = language; }
- (BOOL)saveEditor { [self recordThread]; self.saveCalls++; return self.editorSaves; }
- (NSArray *)excludedApplications { return [self.testDefaults arrayForKey:kRCExcludeApplications] ?: @[]; }
- (void)applyExcludedApplications:(NSArray *)values { [self recordThread]; [self.testDefaults setObject:values forKey:kRCExcludeApplications]; }
- (void)applyUpdaterValues:(NSDictionary *)values {
    [self recordThread];
    if (values[@"automatic_update_check"]) { self.updaterCalls++; [self.testDefaults setObject:values[@"automatic_update_check"] forKey:kRCEnableAutomaticCheckKey]; }
    if (values[@"update_check_interval"]) { self.updaterCalls++; [self.testDefaults setObject:values[@"update_check_interval"] forKey:kRCUpdateCheckIntervalKey]; }
}
- (void)applyAppearance { [self recordThread]; self.appearanceCalls++; }
- (void)scheduleCleanup {
    [self recordThread]; self.cleanupCalls++;
    self.retentionAtCleanup = @{@"enabled":[self.testDefaults objectForKey:kRCPrefAutoExpiryEnabledKey] ?: @NO,
        @"value":[self.testDefaults objectForKey:kRCPrefAutoExpiryValueKey] ?: @30,
        @"unit":[self.testDefaults objectForKey:kRCPrefAutoExpiryUnitKey] ?: @0};
}
- (void)performUIAction:(NSString *)action { [self recordThread]; self.lastAction = action; self.actionCalls++; [self.actionExpectation fulfill]; }
@end

@interface RCSettingsCLITests : XCTestCase
@property (nonatomic, strong) NSString *suite;
@property (nonatomic, strong) NSUserDefaults *defaults;
@property (nonatomic, strong) RCSettingsCLIProbe *api;
@end
@implementation RCSettingsCLITests
- (void)setUp {
    [super setUp];
    self.suite = [@"RCSettingsCLITests." stringByAppendingString:NSUUID.UUID.UUIDString];
    self.defaults = [[NSUserDefaults alloc] initWithSuiteName:self.suite];
    self.api = [[RCSettingsCLIProbe alloc] initWithDefaults:self.defaults];
    self.api.testDefaults = self.defaults;
    self.api.loginSucceeds = YES; self.api.editorSaves = YES;
    self.api.effectsOnMain = YES;
    for (NSString *key in [self hotKeyStorageKeys]) [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
    RCHotKeyContractProbe *hotKeys = [RCHotKeyContractProbe new];
    [hotKeys loadAndRegisterHotKeysFromDefaults]; [hotKeys.calls removeAllObjects];
    self.api.hotKeys = hotKeys;
    self.api.visionLanguages = @[@"en-US", @"ja-JP", @"fr-FR"]; self.api.osSupportsOCR = YES;
}
- (NSArray<NSString *> *)hotKeyStorageKeys {
    return @[kRCHotKeyMainKeyCombo, kRCHotKeyHistoryKeyCombo, kRCHotKeySnippetKeyCombo, kRCClearHistoryKeyCombo, kRCOCRKeyComboKey, kRCOCREnabledKey];
}
- (RCHotKeyContractProbe *)hotKeys { return (RCHotKeyContractProbe *)self.api.hotKeys; }
- (void)tearDown {
    [self.api.hotKeys unregisterAllHotKeys];
    for (NSString *key in [self hotKeyStorageKeys]) [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
    [self.defaults removePersistentDomainForName:self.suite];
    self.api = nil; self.defaults = nil;
    [super tearDown];
}
- (NSDictionary *)setValues:(NSDictionary *)values { return [self.api executeRequest:@{@"op":@"settings-set", @"values":values}]; }
- (NSDictionary *)getValues { return [self.api executeRequest:@{@"op":@"settings-get"}][@"result"][@"values"]; }
- (void)testSchemaAndDefaultsCoverEveryPreferencesPageExceptExcludedGroups {
    NSDictionary *response = [self.api executeRequest:@{@"op":@"settings-schema"}];
    XCTAssertEqualObjects(response[@"ok"], @YES);
    XCTAssertNotNil([NSJSONSerialization dataWithJSONObject:response options:0 error:nil]);
    NSDictionary *schema = response[@"result"];
    NSDictionary *settings = schema[@"settings"];
    XCTAssertEqual(settings.count, 44u, @"35 + four faster OCR settings + five shortcuts");
    XCTAssertEqualObjects(schema[@"excluded_groups"], (@[@"panic"]));
    XCTAssertEqualObjects(schema[@"ocr_boundary"], (@{@"capture_operation":@NO, @"result_readable":@NO}));
    XCTAssertEqualObjects(schema[@"operations"], (@[@"settings-schema",@"settings-get",@"settings-set",@"app-action"]), @"No OCR capture or result operation");
    XCTAssertEqualObjects(settings[@"ocr_language"][@"allowed_values"], (@[@"auto", @"ja-en", @"en-US", @"ja-JP", @"fr-FR"]));
    XCTAssertNotNil(schema[@"unsupported_actions"][@"restart"]);
    NSDictionary *values = [self getValues];
    XCTAssertEqualObjects(values[@"max_history_size"], @30);
    XCTAssertEqualObjects(values[@"max_tooltip_length"], @10000);
    XCTAssertEqualObjects(values[@"store_types"][@"HTML"], @YES);
    XCTAssertEqualObjects(values[@"appearance"], @"system");
    XCTAssertEqualObjects(values[@"language"], @"");
    XCTAssertEqualObjects(values[@"menu_custom_colors_light"][@"background"], @"#F2F2F2");
    XCTAssertEqualObjects(values[@"menu_custom_colors_dark"][@"background"], @"#171717");
    XCTAssertEqual([self.defaults persistentDomainForName:self.suite].count, 0u);
}
- (void)testSingleKeyReadAndSettingsChangeNotificationContainsAppliedKeys {
    NSDictionary *read = [self.api executeRequest:@{@"op":@"settings-get",@"key":@"appearance"}];
    XCTAssertEqualObjects(read[@"result"][@"values"], (@{@"appearance":@"system"}));
    __block NSInteger notifications = 0;
    __block NSDictionary *reentrant;
    id observer = [NSNotificationCenter.defaultCenter addObserverForName:RCSettingsDidChangeNotification object:self.api queue:nil usingBlock:^(NSNotification *note) {
        notifications++;
        XCTAssertTrue(NSThread.isMainThread);
        XCTAssertEqualObjects(note.userInfo[@"keys"], (@[@"appearance",@"paste_command"]));
        XCTAssertEqualObjects([self.defaults objectForKey:@"RCAppAppearance"], @"dark");
        XCTAssertEqualObjects([self.defaults objectForKey:kRCPrefInputPasteCommandKey], @NO);
        reentrant = [self.api executeRequest:@{@"op":@"settings-get"}];
    }];
    @try {
        XCTAssertEqualObjects(([self setValues:@{@"appearance":@"dark",@"paste_command":@NO}][@"ok"]), @YES);
        XCTAssertEqualObjects(([self setValues:@{@"appearance":@"invalid"}][@"ok"]), @NO);
    } @finally { [NSNotificationCenter.defaultCenter removeObserver:observer]; }
    XCTAssertEqual(notifications, 1);
    XCTAssertEqualObjects(reentrant[@"ok"], @NO);
}
- (void)testAllValidationHappensBeforeAnyMutationOrServiceCall {
    NSArray *invalid = @[
        @{@"max_history_size":@0}, @{@"max_history_size":@10000}, @{@"max_history_size":@1.5},
        @{@"max_history_size":@YES}, @{@"show_tooltip":@1}, @{@"show_tooltip":@"true"},
        @{@"show_status_item":@2}, @{@"auto_expiry_unit":@3}, @{@"update_check_interval":@3600},
        @{@"appearance":@"blue"}, @{@"language":@"es"}, @{@"store_types":@{@"HTML":@1}},
        @{@"store_types":@{@"unknown":@YES}}, @{@"excluded_applications":@[@"com..bad"]},
        @{@"excluded_applications":@[@23]}, @{@"menu_custom_colors_dark":@{@"text":@"#123"}},
        @{@"menu_custom_colors_light":@{@"typo":@"#123456"}}, @{@"kRCPanicButtonKeyCombo":@{}},
        @{@"kRCPrefMaxHistorySizeKey":@3}, @{@"max_history_size":NSNull.null},
        @{@"thumbnail_width":@513}, @{@"icon_size":@7}, @{@"number_of_items_inline":@100}
    ];
    for (NSDictionary *bad in invalid) {
        NSMutableDictionary *batch = [@{@"paste_command":@NO, @"login_at_startup":@YES, @"auto_expiry_value":@5} mutableCopy];
        [batch addEntriesFromDictionary:bad];
        NSDictionary *response = [self setValues:batch];
        XCTAssertEqualObjects(response[@"ok"], @NO, @"%@", bad);
        XCTAssertEqual([self.defaults persistentDomainForName:self.suite].count, 0u);
    }
    XCTAssertEqual(self.api.loginCalls, 0); XCTAssertEqual(self.api.cleanupCalls, 0);
}
- (void)testRejectsMalformedRequestsAndUnsupportedActions {
    for (id request in @[@[], @{}, @{@"op":@4}, @{@"op":@"settings-get", @"key":@42},
        @{@"op":@"settings-get", @"key":@"shortcuts"}, @{@"op":@"settings-set", @"values":@{}},
        @{@"op":@"settings-schema", @"extra":@YES}, @{@"op":@"settings-set", @"values":@{@"appearance":@"dark"}, @"dry_run":@YES},
        @{@"op":@"app-action", @"action":@"restart"}, @{@"op":@"app-action", @"action":@42}]) {
        XCTAssertEqualObjects(([self.api executeRequest:request][@"ok"]), @NO);
    }
    XCTAssertEqual([self.defaults persistentDomainForName:self.suite].count, 0u);
}
- (void)testRetentionUsesFinalBatchAndRunsOnceWithoutConfirmation {
    NSDictionary *response = [self setValues:@{@"max_history_size":@5, @"auto_expiry_enabled":@YES, @"auto_expiry_value":@2, @"auto_expiry_unit":@1}];
    XCTAssertEqualObjects(response[@"ok"], @YES);
    XCTAssertEqualObjects(response[@"result"][@"cleanup_scheduled"], @YES);
    XCTAssertEqual(self.api.cleanupCalls, 1);
    XCTAssertEqualObjects(self.api.retentionAtCleanup, (@{@"enabled":@YES,@"value":@2,@"unit":@1}));
    [self setValues:@{@"max_history_size":@6}];
    XCTAssertEqual(self.api.cleanupCalls, 1);
}
- (void)testNestedTypeMergePaletteReplacementAndExclusionNormalization {
    [self setValues:@{@"store_types":@{@"HTML":@NO}}];
    [self setValues:@{@"store_types":@{@"String":@NO}}];
    NSDictionary *values = [self getValues];
    XCTAssertEqualObjects(values[@"store_types"][@"HTML"], @NO);
    XCTAssertEqualObjects(values[@"store_types"][@"String"], @NO);
    XCTAssertEqualObjects(values[@"store_types"][@"TIFF"], @YES);
    NSDictionary *response = [self setValues:@{@"menu_custom_colors_dark":@{@"text":@" abcdef "}, @"excluded_applications":@[@" Com.Example.App ",@"com.example.app",@"org.example.App"]}];
    XCTAssertEqualObjects(response[@"ok"], @YES);
    XCTAssertEqualObjects(response[@"result"][@"values"][@"excluded_applications"], (@[@"com.example.app",@"org.example.app"]));
    XCTAssertEqualObjects([self getValues][@"menu_custom_colors_dark"][@"text"], @"#ABCDEF");
    [self setValues:@{@"menu_custom_colors_dark":@{}}];
    XCTAssertEqualObjects([self getValues][@"menu_custom_colors_dark"][@"text"], @"#FFFFFF");
}
- (void)testPaletteReplacementPersistsAllDefaultsForBothThemes {
    NSDictionary *dark = @{@"primary":@"#007AFF", @"text":@"#FFFFFF", @"background":@"#171717", @"hoverText":@"#FFFFFF", @"hoverBackground":@"#3478F6"};
    NSDictionary *light = @{@"primary":@"#007AFF", @"text":@"#1A1A1A", @"background":@"#F2F2F2", @"hoverText":@"#FFFFFF", @"hoverBackground":@"#3478F6"};
    for (NSString *key in @[@"menu_custom_colors_dark", @"menu_custom_colors_light"]) {
        BOOL isDark = [key hasSuffix:@"dark"];
        NSString *storageKey = isDark ? @"RCMenuCustomColors" : @"RCMenuCustomColorsLight";
        NSDictionary *fallback = isDark ? dark : light;
        // An old custom color must not survive a replacement that omits it.
        [self.defaults setObject:@{@"background":@"#123456"} forKey:storageKey];
        NSDictionary *response = [self setValues:@{key:@{@"text":@" abcdef "}}];
        NSMutableDictionary *expected = [fallback mutableCopy];
        expected[@"text"] = @"#ABCDEF";
        XCTAssertEqualObjects(response[@"ok"], @YES);
        XCTAssertEqualObjects([self.defaults dictionaryForKey:storageKey], expected);
        XCTAssertEqualObjects(response[@"result"][@"values"][key], expected);

        response = [self setValues:@{key:@{}}];
        XCTAssertEqualObjects(response[@"ok"], @YES);
        XCTAssertEqualObjects([self.defaults dictionaryForKey:storageKey], fallback);
        XCTAssertEqualObjects(response[@"result"][@"values"][key], fallback);
        XCTAssertEqualObjects([self getValues][key], fallback);
    }
}
- (void)testLoginFailureAndUnsavedEditorPreventDefaultsMutation {
    self.api.loginSucceeds = NO;
    XCTAssertEqualObjects(([self setValues:@{@"login_at_startup":@YES,@"max_history_size":@1}][@"ok"]), @NO);
    XCTAssertEqual([self.defaults persistentDomainForName:self.suite].count, 0u);
    XCTAssertEqual(self.api.cleanupCalls, 0);
    self.api.editorSaves = NO;
    XCTAssertEqualObjects(([self setValues:@{@"language":@"ja",@"paste_command":@NO}][@"ok"]), @NO);
    XCTAssertEqual(self.api.languageCalls, 0);
    XCTAssertEqual([self.defaults persistentDomainForName:self.suite].count, 0u);
}
- (void)testWorkerRequestAppliesCrossEffectsOnMainAndNotifiesStatusItem {
    XCTestExpectation *done = [self expectationWithDescription:@"worker completed"];
    __block BOOL statusObserved = NO;
    id observer = [NSNotificationCenter.defaultCenter addObserverForName:@"RCStatusItemPreferenceDidChangeNotification" object:nil queue:nil usingBlock:^(NSNotification *note) {
        statusObserved = NSThread.isMainThread && [note.userInfo[@"showStatusItem"] isEqual:@0];
    }];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *response = [self setValues:@{@"appearance":@"dark",@"language":@"ja",@"show_status_item":@0,@"automatic_update_check":@NO,@"update_check_interval":@604800,@"login_at_startup":@YES}];
        XCTAssertEqualObjects(response[@"ok"], @YES);
        [done fulfill];
    });
    [self waitForExpectations:@[done] timeout:3];
    [NSNotificationCenter.defaultCenter removeObserver:observer];
    XCTAssertTrue(statusObserved); XCTAssertTrue(self.api.effectsOnMain);
    XCTAssertEqual(self.api.appearanceCalls, 1); XCTAssertEqual(self.api.languageCalls, 1);
    XCTAssertEqual(self.api.saveCalls, 1); XCTAssertEqual(self.api.updaterCalls, 2);
    XCTAssertEqual(self.api.loginCalls, 1);
}
- (void)testActionsReturnQueuedAndRunNormalServiceSeamOnMain {
    for (NSString *action in @[@"permissions",@"update-check"]) {
        self.api.actionExpectation = [self expectationWithDescription:action];
        NSDictionary *response = [self.api executeRequest:@{@"op":@"app-action",@"action":action}];
        XCTAssertEqualObjects(response[@"result"][@"status"], @"queued");
        [self waitForExpectations:@[self.api.actionExpectation] timeout:3];
    }
    XCTAssertEqual(self.api.actionCalls, 2); XCTAssertTrue(self.api.effectsOnMain);
}
- (void)testQueuedActionRejectsDuplicateAndSnapshotsActionName {
    self.api.actionExpectation = [self expectationWithDescription:@"queued permission action"];
    void (^enqueue)(void) = ^{
        NSMutableString *action = [@"permissions" mutableCopy];
        NSDictionary *first = [self.api executeRequest:@{@"op":@"app-action", @"action":action}];
        [action setString:@"restart"];
        NSDictionary *second = [self.api executeRequest:@{@"op":@"app-action", @"action":@"update-check"}];
        XCTAssertEqualObjects(first[@"result"][@"action"], @"permissions");
        XCTAssertEqualObjects(second[@"ok"], @NO);
        XCTAssertEqual(self.api.actionCalls, 0);
    };
    if (NSThread.isMainThread) enqueue();
    else dispatch_sync(dispatch_get_main_queue(), enqueue);
    [self waitForExpectations:@[self.api.actionExpectation] timeout:3];
    XCTAssertEqual(self.api.actionCalls, 1);
    XCTAssertEqualObjects(self.api.lastAction, @"permissions");
    XCTAssertTrue(self.api.effectsOnMain);
}
- (void)testFasterOCRSettingsReadDefaultsValidateBeforeMutationAndNotifyThePreferences {
    NSDictionary *values = [self getValues];
    XCTAssertEqualObjects(values[@"ocr_enabled"], @YES); XCTAssertEqualObjects(values[@"ocr_save_history"], @YES);
    XCTAssertEqualObjects(values[@"ocr_language_correction"], @NO); XCTAssertEqualObjects(values[@"ocr_language"], @"auto");
    XCTestExpectation *notified = [self expectationForNotification:RCSettingsDidChangeNotification object:self.api handler:^BOOL(NSNotification *note) {
        return [note.userInfo[@"keys"] containsObject:@"ocr_language"];
    }];
    NSDictionary *response = [self setValues:@{@"ocr_language":@"fr-FR", @"ocr_save_history":@NO, @"ocr_language_correction":@YES}];
    XCTAssertEqualObjects(response[@"ok"], @YES);
    [self waitForExpectations:@[notified] timeout:2];
    XCTAssertEqualObjects([self.defaults stringForKey:kRCOCRLanguageKey], @"fr-FR");
    XCTAssertEqualObjects([self.defaults objectForKey:kRCOCRSaveHistoryKey], @NO);
    XCTAssertEqual(self.api.prepareCalls, 0, @"No shortcut or switch in the request: the hot key service is not involved");
    // A language this macOS does not report is rejected with everything else in the batch.
    response = [self setValues:@{@"ocr_language":@"xx-XX", @"ocr_save_history":@YES}];
    XCTAssertEqualObjects(response[@"ok"], @NO);
    XCTAssertEqualObjects([self.defaults objectForKey:kRCOCRSaveHistoryKey], @NO);
    XCTAssertEqualObjects([self setValues:@{@"ocr_language":@""}][@"ok"], @NO);
    XCTAssertEqualObjects([self setValues:@{@"ocr_enabled":@1}][@"ok"], @NO, @"Booleans only");
}
- (void)testSwitchingFasterOCROnIsRefusedWhenTheOSOrTheStoredLanguageCannotRunIt {
    [self.defaults setObject:@"de-DE" forKey:kRCOCRLanguageKey]; // stored by another OS version
    XCTAssertEqualObjects([self getValues][@"ocr_language"], @"de-DE", @"Reported as stored, never replaced");
    NSDictionary *response = [self setValues:@{@"ocr_enabled":@YES}];
    XCTAssertEqualObjects(response[@"ok"], @NO);
    XCTAssertTrue([response[@"error"] containsString:@"ocr_language"]);
    XCTAssertNil([self.defaults persistentDomainForName:self.suite][kRCOCREnabledKey]); XCTAssertEqual(self.api.prepareCalls, 0);
    // Fixing the language in the same request is accepted; switching off always is.
    XCTAssertEqualObjects(([self setValues:@{@"ocr_enabled":@YES, @"ocr_language":@"ja-en"}][@"ok"]), @YES);
    [self.defaults setObject:@"de-DE" forKey:kRCOCRLanguageKey];
    XCTAssertEqualObjects([self setValues:@{@"ocr_enabled":@NO}][@"ok"], @YES);
    self.api.osSupportsOCR = NO;
    response = [self setValues:@{@"ocr_enabled":@YES, @"ocr_language":@"auto"}];
    XCTAssertEqualObjects(response[@"ok"], @NO); XCTAssertTrue([response[@"error"] containsString:@"macOS version"]);
}
- (void)testShortcutReadbackCanBeWrittenBackAndClearAndDefaultHaveOneShape {
    NSDictionary *ocr = [self getValues][@"shortcut_ocr"];
    XCTAssertEqualObjects(ocr, (@{@"key_code":@19, @"modifiers":@[@"shift", @"command"], @"display":@"⇧⌘2"}));
    XCTAssertEqualObjects([self getValues][@"shortcut_clear_history"], @{}, @"No shortcut is an empty object");
    XCTAssertEqualObjects([self setValues:@{@"shortcut_ocr":ocr}][@"ok"], @YES, @"display is read-only: accepted and ignored");
    XCTAssertEqual([self hotKeys].calls.count, 0u, @"Same value: nothing re-registered");
    NSDictionary *response = [self setValues:@{@"shortcut_ocr":@{@"key_code":@18, @"modifiers":@[@"command", @"control"], @"display":@"ignored"}}];
    XCTAssertEqualObjects(response[@"ok"], @YES);
    XCTAssertEqualObjects(response[@"result"][@"values"][@"shortcut_ocr"][@"display"], @"⌃⌘1");
    XCTAssertEqualObjects(([self hotKeys].calls), (@[@"register 18:4352", @"unregister 19:768"]));
    XCTAssertEqualObjects([self setValues:@{@"shortcut_ocr":@{}}][@"ok"], @YES);
    XCTAssertEqualObjects([self getValues][@"shortcut_ocr"], @{});
    XCTAssertEqualObjects([self setValues:@{@"shortcut_ocr":@{@"default":@YES}}][@"ok"], @YES);
    XCTAssertEqualObjects([self getValues][@"shortcut_ocr"][@"key_code"], @19);
    for (id bad in @[@{@"key_code":@19}, @{@"modifiers":@[@"command"]}, @{@"key_code":@19, @"modifiers":@[]}, @{@"key_code":@19, @"modifiers":@[@"command", @"command"]},
                     @{@"key_code":@19, @"modifiers":@[@"cmd"]}, @{@"key_code":@19.5, @"modifiers":@[@"command"]}, @{@"key_code":@200, @"modifiers":@[@"command"]},
                     @{@"key_code":@YES, @"modifiers":@[@"command"]}, @{@"default":@YES, @"key_code":@19}, @{@"default":@NO}, @{@"key_code":@19, @"modifiers":@[@"command"], @"extra":@1},
                     @"⇧⌘2", @[@19]]) {
        XCTAssertEqualObjects(([self setValues:@{@"shortcut_ocr":bad}][@"ok"]), @NO, @"%@", bad);
    }
    XCTAssertEqualObjects([self getValues][@"shortcut_ocr"][@"key_code"], @19);
}
- (void)testShortcutConflictIsNamedExchangeIsOneRequestAndFailureChangesNothing {
    NSDictionary *mainValue = [self getValues][@"shortcut_main"], *historyValue = [self getValues][@"shortcut_history"];
    // The contract is "a refused request writes nothing": compare what is stored, since
    // the process-wide registration domain supplies defaults for unwritten keys.
    NSDictionary *storedBefore = [self.defaults persistentDomainForName:self.suite] ?: @{};
    NSDictionary *response = [self setValues:@{@"shortcut_ocr":mainValue, @"max_history_size":@77}];
    XCTAssertEqualObjects(response[@"ok"], @NO);
    XCTAssertTrue([response[@"error"] containsString:@"shortcut_ocr"] && [response[@"error"] containsString:@"shortcut_main"], @"%@", response[@"error"]);
    XCTAssertEqualObjects([self.defaults persistentDomainForName:self.suite] ?: @{}, storedBefore, @"The rest of the request is not applied either");
    XCTAssertEqual(self.api.commitCalls, 0); XCTAssertEqual([self hotKeys].calls.count, 0u);
    // Each alone collides with the other; together they are an exchange.
    response = [self setValues:@{@"shortcut_main":historyValue, @"shortcut_history":mainValue}];
    XCTAssertEqualObjects(response[@"ok"], @YES);
    XCTAssertEqual([self hotKeys].calls.count, 0u, @"Live registrations changed owner without an OS call");
    XCTAssertEqualObjects([self getValues][@"shortcut_main"][@"display"], historyValue[@"display"]);
    // The OS refuses: old registrations, stored shortcuts and the other settings stay.
    [[self hotKeys].refused addObject:@"7:768"];
    storedBefore = [self.defaults persistentDomainForName:self.suite] ?: @{};
    response = [self setValues:@{@"shortcut_snippet":@{@"key_code":@7, @"modifiers":@[@"command", @"shift"]}, @"max_history_size":@88}];
    XCTAssertEqualObjects(response[@"ok"], @NO);
    XCTAssertTrue([response[@"error"] containsString:@"OSStatus"] && [response[@"error"] containsString:@"cannot be detected"], @"%@", response[@"error"]);
    XCTAssertEqualObjects([self getValues][@"shortcut_snippet"][@"key_code"], @11);
    XCTAssertEqualObjects([self.defaults persistentDomainForName:self.suite] ?: @{}, storedBefore);
}
- (void)testPreparedShortcutsAreDiscardedWhenTheLoginItemFailsAndCommittedBeforeTheSwitchIsStored {
    self.api.loginSucceeds = NO;
    NSDictionary *response = [self setValues:@{@"login_at_startup":@NO, @"shortcut_main":@{@"key_code":@18, @"modifiers":@[@"command", @"shift"]}}];
    XCTAssertEqualObjects(response[@"ok"], @NO);
    XCTAssertEqual(self.api.prepareCalls, 1); XCTAssertEqual(self.api.discardCalls, 1); XCTAssertEqual(self.api.commitCalls, 0);
    XCTAssertEqualObjects(([self hotKeys].calls), (@[@"register 18:768", @"unregister 18:768"]), @"Only what this request prepared is released");
    XCTAssertEqualObjects([self getValues][@"shortcut_main"][@"key_code"], @9);
    self.api.loginSucceeds = YES; [[self hotKeys].calls removeAllObjects];
    // The switch alone re-evaluates the faster OCR registration, for the state it will have.
    response = [self setValues:@{@"ocr_enabled":@NO}];
    XCTAssertEqualObjects(response[@"ok"], @YES);
    XCTAssertEqual(self.api.lastAssignments.count, 1u);
    XCTAssertEqual(self.api.lastAssignments.firstObject.kind, RCHotKeyAssignmentKindKeep);
    XCTAssertEqualObjects(self.api.lastOCREnabled, @NO);
    XCTAssertEqualObjects(self.api.ocrEnabledStoredAtCommit, NSNull.null, @"Registrations are final before the switch is stored");
    XCTAssertEqualObjects(([self hotKeys].calls), (@[@"unregister 19:768"]));
    XCTAssertTrue(self.api.effectsOnMain);
}
@end

// Async CLI report bridge tests share this writer-owned test file. The report
// service's own HTTP/UI tests remain owned by its author.
#import "RCSnippetCLIService.h"
@interface RCSnippetCLIService (BugReportTesting)
- (dispatch_queue_t)makeClientQueue;
- (NSTimeInterval)bugReportWaitTimeout;
- (NSDictionary *)executeBugReportRequest:(NSDictionary *)request;
- (void)submitBugReportRequest:(NSDictionary *)request completion:(void (^)(NSDictionary *))completion;
@end
@interface RCBugReportCLIProbe : RCSnippetCLIService
@property (nonatomic, copy) NSDictionary *reply;
@property (nonatomic, copy) NSDictionary *submitted;
@property (nonatomic, copy) void (^pendingCompletion)(NSDictionary *);
@property (nonatomic) BOOL submitOnMain;
@property (nonatomic) NSTimeInterval waitTimeout;
@end
@implementation RCBugReportCLIProbe
- (NSTimeInterval)bugReportWaitTimeout { return self.waitTimeout ?: 1.0; }
- (void)submitBugReportRequest:(NSDictionary *)request completion:(void (^)(NSDictionary *))completion {
    self.submitOnMain = NSThread.isMainThread;
    self.submitted = request;
    self.pendingCompletion = completion;
    if (self.reply) dispatch_async(dispatch_get_main_queue(), ^{ completion(self.reply); });
}
@end
@interface RCBugReportCLITransportTests : XCTestCase
@end
@implementation RCBugReportCLITransportTests
- (NSDictionary *)request {
    return @{@"op":@"bug-report", @"title":@" Title ", @"description":@" Description ", @"contact":@"", @"source_info_consent":@YES};
}
- (NSDictionary *)runRequest:(NSDictionary *)request probe:(RCBugReportCLIProbe *)probe {
    XCTestExpectation *done = [self expectationWithDescription:@"report bridge result"];
    __block NSDictionary *response;
    dispatch_async([probe makeClientQueue], ^{
        response = [probe executeBugReportRequest:request];
        [done fulfill];
    });
    [self waitForExpectations:@[done] timeout:3];
    return response;
}
- (void)testRejectsNonBooleanOrMissingConsentAndTypedFieldsBeforeSubmission {
    RCBugReportCLIProbe *probe = [RCBugReportCLIProbe new];
    for (id consent in @[@NO, @1, @"true", NSNull.null]) {
        NSMutableDictionary *request = [[self request] mutableCopy];
        request[@"source_info_consent"] = consent;
        NSDictionary *response = [self runRequest:request probe:probe];
        XCTAssertEqualObjects(response[@"ok"], @NO);
    }
    for (NSString *key in @[@"source_info_consent", @"title", @"description", @"contact"]) {
        NSMutableDictionary *request = [[self request] mutableCopy];
        [request removeObjectForKey:key];
        NSDictionary *response = [self runRequest:request probe:probe];
        XCTAssertEqualObjects(response[@"ok"], @NO);
    }
    for (NSDictionary *invalid in @[@{@"title":@42}, @{@"description":@" "}, @{@"contact":@[]}, @{@"unknown":@YES},
        @{@"clipboard":@"do not collect"}, @{@"history":@[]}, @{@"logs":@"do not collect"}, @{@"source_info":@{}}]) {
        NSMutableDictionary *request = [[self request] mutableCopy];
        [request addEntriesFromDictionary:invalid];
        NSDictionary *response = [self runRequest:request probe:probe];
        XCTAssertEqualObjects(response[@"ok"], @NO);
    }
    XCTAssertNil(probe.submitted);
}
- (void)testOnlySentCallbackProducesSuccessAndSubmissionStartsOnMain {
    RCBugReportCLIProbe *probe = [RCBugReportCLIProbe new];
    probe.reply = @{@"ok":@YES, @"result":@{@"status":@"sent"}};
    NSDictionary *response = [self runRequest:[self request] probe:probe];
    XCTAssertEqualObjects(response, probe.reply);
    XCTAssertTrue(probe.submitOnMain);
    XCTAssertEqualObjects([NSSet setWithArray:probe.submitted.allKeys], ([NSSet setWithArray:@[@"title", @"description", @"contact"]]));
    XCTAssertEqualObjects(probe.submitted[@"title"], @"Title");
    XCTAssertEqualObjects(probe.submitted[@"description"], @"Description");
    probe.reply = @{@"ok":@NO, @"error":@"service failure"};
    response = [self runRequest:[self request] probe:probe];
    XCTAssertEqualObjects(response[@"ok"], @NO);
    probe.reply = @{@"ok":@YES, @"result":@{@"status":@"queued"}};
    response = [self runRequest:[self request] probe:probe];
    XCTAssertEqualObjects(response[@"ok"], @NO);
}
- (void)testTimeoutReturnsFailureAndLateCompletionCannotRewriteIt {
    RCBugReportCLIProbe *probe = [RCBugReportCLIProbe new];
    probe.waitTimeout = 0.05;
    NSDictionary *response = [self runRequest:[self request] probe:probe];
    XCTAssertEqualObjects(response[@"ok"], @NO);
    NSDictionary *snapshot = [response copy];
    if (probe.pendingCompletion) {
        void (^late)(void) = ^{ probe.pendingCompletion(@{@"ok":@YES, @"result":@{@"status":@"sent"}}); };
        if (NSThread.isMainThread) late(); else dispatch_sync(dispatch_get_main_queue(), late);
    }
    XCTAssertEqualObjects(response, snapshot);
}
- (void)testMainThreadAndGeneralExecuteNeverWaitOrPretendToSend {
    RCBugReportCLIProbe *probe = [RCBugReportCLIProbe new];
    void (^check)(void) = ^{
        NSDictionary *response = [probe executeBugReportRequest:[self request]];
        XCTAssertEqualObjects(response[@"ok"], @NO);
        response = [probe executeRequest:[self request]];
        XCTAssertEqualObjects(response[@"ok"], @NO);
    };
    if (NSThread.isMainThread) check(); else dispatch_sync(dispatch_get_main_queue(), check);
    XCTAssertNil(probe.submitted);
}
@end
