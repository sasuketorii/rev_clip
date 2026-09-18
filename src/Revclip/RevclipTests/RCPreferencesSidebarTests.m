#import <XCTest/XCTest.h>
#import "RCPreferencesPage.h"
#import "RCPreferencesWindowController.h"
#import "RCSettingsCLIService.h"
#import "RCConstants.h"
#import "RCLocalization.h"
#import "RCGeneralPreferencesViewController.h"
#import "RCExcludePreferencesViewController.h"
#import "RCBugReportPreferencesViewController.h"
#import "RCBugReportService.h"

@interface RCPreferencesExclusionRefreshProbe : RCExcludePreferencesViewController
@property NSInteger reloadCount;
@end
@implementation RCPreferencesExclusionRefreshProbe
- (void)viewDidLoad { /* This probe has no application-list UI or service. */ }
- (void)reloadExcludedApplications { self.reloadCount++; }
@end

@interface RCPreferencesRefreshProbe : RCPreferencesWindowController
@property (strong) NSUserDefaults *testDefaults;
@end
@implementation RCPreferencesRefreshProbe
- (NSUserDefaults *)settingsDefaults { return self.testDefaults; }
@end

@interface RCPreferencesSwitchProbe : NSViewController
@property (strong) NSButton *setting;
@property NSInteger actionCount;
@end
@implementation RCPreferencesSwitchProbe
- (void)changed:(id)sender { self.actionCount++; }
@end

@interface RCPreferencesSidebarTests : XCTestCase
@end
@implementation RCPreferencesSidebarTests

- (void)assertNoSharedReportSubmissionDuring:(void (^)(void))actions {
    RCBugReportService *service = RCBugReportService.shared;
    XCTAssertFalse(service.isSubmitting);
    NSDictionary *draft = service.draft;
    NSDictionary *lastResponse = service.lastResponse;
    __block NSUInteger submissionStarts = 0;
    // The service posts synchronously before starting its transport. This also
    // catches a submission that finishes before the final idle-state assertion.
    id observer = [NSNotificationCenter.defaultCenter addObserverForName:RCBugReportServiceDidChangeNotification
        object:service queue:nil usingBlock:^(NSNotification *notification) {
            if (service.isSubmitting) submissionStarts++;
        }];
    @try {
        actions();
        XCTAssertEqual(submissionStarts, 0u);
        XCTAssertFalse(service.isSubmitting);
        XCTAssertEqualObjects(service.draft, draft);
        XCTAssertEqualObjects(service.lastResponse, lastResponse);
    } @finally {
        [NSNotificationCenter.defaultCenter removeObserver:observer];
    }
}

- (void)testBugReportSidebarOrderTitleIconAndLazyFactory {
    RCPreferencesRefreshProbe *controller = [self refreshController];
    NSArray *tabs = [controller valueForKey:@"tabIdentifiers"];
    XCTAssertEqual(tabs.count, 9u);
    XCTAssertFalse([tabs containsObject:RCPreferencesTabBugReport]);
    XCTAssertTrue([tabs containsObject:@"advanced"]);
    XCTAssertTrue([[controller valueForKey:@"advancedTabIdentifiers"] containsObject:RCPreferencesTabBugReport]);
    XCTAssertNil([controller valueForKey:@"bugReportViewController"]);
    [controller showTab:RCPreferencesTabBugReport];
    NSViewController *report = [controller valueForKey:@"bugReportViewController"];
    XCTAssertTrue([report isKindOfClass:RCBugReportPreferencesViewController.class]);
    XCTAssertEqualObjects([(NSTextField *)[controller valueForKey:@"pageTitle"] stringValue], RCLocalizedString(@"Advanced Settings", nil));
    [controller showTab:RCPreferencesTabGeneral];
    [controller showTab:RCPreferencesTabBugReport];
    XCTAssertEqual([controller valueForKey:@"bugReportViewController"], report);
    NSTableView *sidebar = [controller valueForKey:@"sidebar"];
    XCTAssertEqual(sidebar.selectedRow, (NSInteger)[tabs indexOfObject:@"advanced"]);
}

- (void)testBugReportDraftSurvivesCLIRefreshWithoutSending {
    [self assertNoSharedReportSubmissionDuring:^{
        RCPreferencesRefreshProbe *controller = [self refreshController];
        [controller showTab:RCPreferencesTabBugReport];
        NSViewController *report = [controller valueForKey:@"bugReportViewController"];
        NSTextField *title = [report valueForKey:@"titleField"];
        NSTextView *description = [report valueForKey:@"descriptionField"];
        title.stringValue = @"Unsent report";
        description.string = @"Unfinished description";
        [controller.window makeFirstResponder:description];
        [self notifySettings:@[@"paste_command", @"update_check_interval", @"excluded_applications"]];
        XCTAssertEqual([controller valueForKey:@"bugReportViewController"], report);
        XCTAssertEqual(controller.window.firstResponder, description);
        XCTAssertEqualObjects(title.stringValue, @"Unsent report");
        XCTAssertEqualObjects(description.string, @"Unfinished description");
    }];
}

- (void)testLanguageRefreshRecreatesBugReportAndKeepsItsSelection {
    [self assertNoSharedReportSubmissionDuring:^{
        RCPreferencesRefreshProbe *controller = [self refreshController];
        [controller showTab:RCPreferencesTabBugReport];
        NSViewController *report = [controller valueForKey:@"bugReportViewController"];
        [NSNotificationCenter.defaultCenter postNotificationName:RCLanguageDidChangeNotification object:nil];
        [self notifySettings:@[@"language"]];
        NSViewController *replacement = [controller valueForKey:@"bugReportViewController"];
        XCTAssertNotEqual(replacement, report);
        XCTAssertTrue([replacement isKindOfClass:RCBugReportPreferencesViewController.class]);
        XCTAssertEqualObjects([controller valueForKey:@"selectedTab"], RCPreferencesTabBugReport);
    }];
}

- (RCPreferencesRefreshProbe *)refreshController {
    NSString *suite = [@"RevclipTests.SidebarRefresh." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [defaults registerDefaults:@{kRCPrefMaxHistorySizeKey:@30, kRCPrefAutoExpiryValueKey:@30,
        kRCPrefInputPasteCommandKey:@YES, kRCEnableAutomaticCheckKey:@YES, kRCUpdateCheckIntervalKey:@86400}];
    RCPreferencesRefreshProbe *controller = [RCPreferencesRefreshProbe new];
    controller.testDefaults = defaults;
    (void)controller.window;
    [self addTeardownBlock:^{
        [NSNotificationCenter.defaultCenter removeObserver:controller];
        [controller.window orderOut:nil];
        [defaults removePersistentDomainForName:suite];
    }];
    return controller;
}

- (void)notifySettings:(NSArray<NSString *> *)keys {
    [NSNotificationCenter.defaultCenter postNotificationName:RCSettingsDidChangeNotification object:nil userInfo:@{@"keys":keys}];
    // Include the next main-queue turn: the old implementation rebuilt there.
    [self drainMainQueue];
}

- (void)drainMainQueue {
    XCTestExpectation *drained = [self expectationWithDescription:@"Pending main-queue work drained"];
    dispatch_async(dispatch_get_main_queue(), ^{ [drained fulfill]; });
    [self waitForExpectations:@[drained] timeout:2];
}

- (void)testUnrelatedCLIWritePreservesGeneralFieldEditorAndShell {
    RCPreferencesRefreshProbe *controller = [self refreshController];
    NSView *shell = controller.window.contentView;
    NSScrollView *scroll = [controller valueForKey:@"pageScrollView"];
    RCGeneralPreferencesViewController *general = [controller valueForKey:@"generalViewController"];
    NSTextField *field = [general valueForKey:@"maxHistorySizeTextField"];
    [field selectText:nil];
    NSText *editor = field.currentEditor;
    XCTAssertNotNil(editor);
    editor.string = @"123";
    [controller.testDefaults setBool:NO forKey:kRCPrefInputPasteCommandKey];
    [self notifySettings:@[@"paste_command"]];
    XCTAssertEqual(controller.window.contentView, shell);
    XCTAssertEqual([controller valueForKey:@"pageScrollView"], scroll);
    XCTAssertEqual([controller valueForKey:@"generalViewController"], general);
    XCTAssertEqual(field.currentEditor, editor);
    XCTAssertEqualObjects(editor.string, @"123");
    XCTAssertEqual([(NSSwitch *)[general valueForKey:@"pasteCommandButton"] state], NSControlStateValueOff);
    XCTAssertEqual([controller.testDefaults integerForKey:kRCPrefMaxHistorySizeKey], 30);
}

- (void)testGeneralCLIRefreshUpdatesOnlyRequestedValuesAndDependentControls {
    RCPreferencesRefreshProbe *controller = [self refreshController];
    RCGeneralPreferencesViewController *general = [controller valueForKey:@"generalViewController"];
    NSTextField *history = [general valueForKey:@"maxHistorySizeTextField"];
    history.stringValue = @"unfinished";
    [controller.testDefaults setInteger:7 forKey:kRCPrefAutoExpiryValueKey];
    [controller.testDefaults setInteger:2 forKey:kRCPrefAutoExpiryUnitKey];
    [controller.testDefaults setBool:YES forKey:kRCPrefAutoExpiryEnabledKey];
    [self notifySettings:@[@"auto_expiry_value", @"auto_expiry_unit", @"auto_expiry_enabled"]];
    XCTAssertEqualObjects(history.stringValue, @"unfinished");
    XCTAssertEqual(general.autoExpiryValueTextField.integerValue, 7);
    XCTAssertEqual(general.autoExpiryValueStepper.integerValue, 7);
    XCTAssertEqual(general.autoExpiryUnitPopUpButton.indexOfSelectedItem, 2);
    XCTAssertEqual(general.autoExpiryEnabledButton.state, NSControlStateValueOn);
    XCTAssertTrue(general.autoExpiryValueTextField.enabled);
    [controller.testDefaults setBool:NO forKey:kRCPrefAutoExpiryEnabledKey];
    [self notifySettings:@[@"auto_expiry_enabled"]];
    XCTAssertFalse(general.autoExpiryValueTextField.enabled);
    XCTAssertFalse(general.autoExpiryValueStepper.enabled);
    XCTAssertFalse(general.autoExpiryUnitPopUpButton.enabled);
    XCTAssertEqualObjects(history.stringValue, @"unfinished");
}

- (void)testLoadedTypeAndUpdateControlsRefreshWithoutReplacingPages {
    RCPreferencesRefreshProbe *controller = [self refreshController];
    [controller showTab:@"type"];
    NSViewController *type = [controller valueForKey:@"typeViewController"];
    [controller showTab:@"updates"];
    NSViewController *updates = [controller valueForKey:@"updatesViewController"];
    NSButton *checkNow = [updates valueForKey:@"checkNowButton"];
    checkNow.enabled = NO; // An in-flight check's UI must not be reset.
    [controller.testDefaults setObject:@{@"HTML":@NO, @"String":@NO} forKey:kRCPrefStoreTypesKey];
    [controller.testDefaults setBool:NO forKey:kRCEnableAutomaticCheckKey];
    [controller.testDefaults setInteger:604800 forKey:kRCUpdateCheckIntervalKey];
    [self notifySettings:@[@"store_types", @"automatic_update_check", @"update_check_interval"]];
    XCTAssertEqual([controller valueForKey:@"typeViewController"], type);
    XCTAssertEqual([controller valueForKey:@"updatesViewController"], updates);
    XCTAssertEqual([(NSSwitch *)[type valueForKey:@"htmlCheckbox"] state], NSControlStateValueOff);
    XCTAssertEqual([(NSSwitch *)[type valueForKey:@"plainTextCheckbox"] state], NSControlStateValueOff);
    XCTAssertEqual([(NSSwitch *)[type valueForKey:@"richTextCheckbox"] state], NSControlStateValueOn);
    NSPopUpButton *interval = [updates valueForKey:@"checkIntervalPopUpButton"];
    XCTAssertEqual(interval.selectedTag, 604800);
    XCTAssertFalse(interval.enabled);
    XCTAssertFalse(checkNow.enabled);
}

- (void)testMenuKeepsActualBindingsAndUnrelatedDraftOnCLINotification {
    // Menu binds directly to the shared controller, not the refresh probe's defaults.
    // Supply its missing-value fixture before binding, without writing persistent preferences.
    NSUserDefaultsController *bindingOwner = NSUserDefaultsController.sharedUserDefaultsController;
    NSDictionary *originalInitialValues = [bindingOwner.initialValues copy];
    NSMutableDictionary *initialValues = [originalInitialValues mutableCopy] ?: [NSMutableDictionary dictionary];
    initialValues[kRCPrefMaxMenuItemTitleLengthKey] = @40;
    bindingOwner.initialValues = initialValues;
    NSTextField *title = nil;
    @try {
        RCPreferencesRefreshProbe *controller = [self refreshController];
        [controller showTab:@"menu"];
        NSViewController *menu = [controller valueForKey:@"menuViewController"];
        title = [menu valueForKey:@"maxTitleLengthTextField"];
        NSDictionary *binding = [title infoForBinding:NSValueBinding];
        XCTAssertNotNil(binding);
        XCTAssertEqual(binding[NSObservedObjectKey], bindingOwner);
        XCTAssertEqualObjects(binding[NSObservedKeyPathKey], [@"values." stringByAppendingString:kRCPrefMaxMenuItemTitleLengthKey]);
        [controller.window.contentView layoutSubtreeIfNeeded];
        [self drainMainQueue];
        XCTAssertNotNil([bindingOwner valueForKeyPath:binding[NSObservedKeyPathKey]]);
        XCTAssertNotNil(title.objectValue);
        [title selectText:nil];
        [controller.window.contentView layoutSubtreeIfNeeded];
        [self drainMainQueue];
        NSText *editor = title.currentEditor;
        XCTAssertNotNil(editor);
        XCTAssertEqual(controller.window.firstResponder, editor);
        editor.string = @"-";
        XCTAssertEqualObjects(editor.string, @"-");
        [self notifySettings:@[@"update_check_interval", @"show_icon"]];
        XCTAssertEqual([controller valueForKey:@"menuViewController"], menu);
        XCTAssertEqual(title.currentEditor, editor);
        XCTAssertEqual(controller.window.firstResponder, editor);
        XCTAssertEqualObjects(editor.string, @"-");
        XCTAssertEqualObjects([title infoForBinding:NSValueBinding], binding);
    } @finally {
        // Discard the deliberately incomplete test draft before restoring the shared fixture.
        [title abortEditing];
        bindingOwner.initialValues = originalInitialValues;
    }
}

- (void)testUnrelatedSettingsKeepAppearanceHostAndUnvisitedPagesLazy {
    RCPreferencesRefreshProbe *controller = [self refreshController];
    [controller showTab:@"appearance"];
    NSViewController *appearance = [controller valueForKey:@"appearanceViewController"];
    NSView *shell = controller.window.contentView;
    [self notifySettings:@[@"update_check_interval", @"paste_command", @"store_types", @"excluded_applications"]];
    XCTAssertEqual([controller valueForKey:@"appearanceViewController"], appearance);
    XCTAssertEqual(controller.window.contentView, shell);
    XCTAssertNil([controller valueForKey:@"updatesViewController"]);
    XCTAssertNil([controller valueForKey:@"typeViewController"]);
    XCTAssertNil([controller valueForKey:@"excludeViewController"]);
}

- (void)testLanguageNotificationStillRebuildsAndKeepsSelectedTab {
    RCPreferencesRefreshProbe *controller = [self refreshController];
    [controller showTab:@"menu"];
    NSView *shell = controller.window.contentView;
    NSViewController *menu = [controller valueForKey:@"menuViewController"];
    [NSNotificationCenter.defaultCenter postNotificationName:RCLanguageDidChangeNotification object:nil];
    [self notifySettings:@[@"language", @"paste_command"]];
    XCTAssertNotEqual(controller.window.contentView, shell);
    XCTAssertNotEqual([controller valueForKey:@"menuViewController"], menu);
    XCTAssertEqualObjects([controller valueForKey:@"selectedTab"], @"menu");
}

- (void)testExclusionsReloadOnlyForTheirOwnSetting {
    RCPreferencesRefreshProbe *controller = [self refreshController];
    RCPreferencesExclusionRefreshProbe *exclude = [RCPreferencesExclusionRefreshProbe new];
    exclude.view = [NSView new];
    [controller setValue:exclude forKey:@"excludeViewController"];
    NSInteger initialCount = exclude.reloadCount;
    [self notifySettings:@[@"paste_command"]];
    XCTAssertEqual(exclude.reloadCount, initialCount);
    [self notifySettings:@[@"excluded_applications"]];
    XCTAssertEqual(exclude.reloadCount, initialCount + 1);
    XCTAssertEqual([controller valueForKey:@"excludeViewController"], exclude);
}

- (void)testPaletteRefreshPreservesActiveEditorUntilNextAppearanceVisit {
    RCPreferencesRefreshProbe *controller = [self refreshController];
    [controller showTab:@"appearance"];
    NSViewController *appearance = [controller valueForKey:@"appearanceViewController"];
    NSView *shell = controller.window.contentView;
    // A native field editor exercises the same focus guard as SwiftUI's HEX field: the
    // guard looks at the window's first responder only. The field goes into the window's
    // own content view, not under NSHostingController.view. SwiftUI reports that as a
    // runtime issue, and XCTest then symbolicates on the main thread, where a slow dSYM
    // lookup (Spotlight) held the thread past this test's two-second drain.
    NSTextField *field = [NSTextField textFieldWithString:@"#"];
    field.frame = NSMakeRect(0, 0, 100, 24);
    [controller.window.contentView addSubview:field];
    [self addTeardownBlock:^{ [field removeFromSuperview]; }];
    [field selectText:nil];
    NSText *editor = field.currentEditor;
    XCTAssertNotNil(editor);
    BOOL dark = [[NSApp.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
    [self notifySettings:@[dark ? @"menu_custom_colors_light" : @"menu_custom_colors_dark"]];
    XCTAssertFalse([[controller valueForKey:@"appearancePaletteNeedsRefresh"] boolValue]);
    [self notifySettings:@[dark ? @"menu_custom_colors_dark" : @"menu_custom_colors_light"]];
    XCTAssertEqual([controller valueForKey:@"appearanceViewController"], appearance);
    XCTAssertEqual(field.currentEditor, editor);
    XCTAssertEqualObjects(editor.string, @"#");
    XCTAssertTrue([[controller valueForKey:@"appearancePaletteNeedsRefresh"] boolValue]);
    [controller.window makeFirstResponder:nil];
    [controller showTab:@"general"];
    [controller showTab:@"appearance"];
    XCTAssertNotEqual([controller valueForKey:@"appearanceViewController"], appearance);
    XCTAssertFalse([[controller valueForKey:@"appearancePaletteNeedsRefresh"] boolValue]);
    XCTAssertEqual(controller.window.contentView, shell);
}

- (void)testSwitchKeepsActionAndDisabledState {
    RCPreferencesSwitchProbe *probe = [RCPreferencesSwitchProbe new];
    probe.setting = [NSButton checkboxWithTitle:@"Setting" target:probe action:@selector(changed:)];
    probe.setting.state = NSControlStateValueOn;
    NSSwitch *control = [RCPreferencesPage switchForController:probe key:@"setting"];
    XCTAssertEqual(control.state, NSControlStateValueOn);
    [control performClick:nil];
    XCTAssertEqual(control.state, NSControlStateValueOff);
    XCTAssertEqual(probe.actionCount, 1);
    probe.setting = [NSButton checkboxWithTitle:@"Unavailable" target:probe action:@selector(changed:)];
    probe.setting.enabled = NO;
    NSSwitch *disabled = [RCPreferencesPage switchForController:probe key:@"setting"];
    XCTAssertFalse(disabled.enabled);
}

- (void)testSwitchKeepsTwoWayBindingAndDependentEnabledBinding {
    NSString *suite = [@"RevclipTests.Settings." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    NSUserDefaultsController *bindingController = [[NSUserDefaultsController alloc] initWithDefaults:defaults initialValues:@{@"flag": @NO, @"available": @YES}];
    bindingController.appliesImmediately = YES;
    RCPreferencesSwitchProbe *probe = [RCPreferencesSwitchProbe new];
    probe.setting = [NSButton checkboxWithTitle:@"Setting" target:nil action:nil];
    [probe.setting bind:NSValueBinding toObject:bindingController withKeyPath:@"values.flag" options:nil];
    [probe.setting bind:NSEnabledBinding toObject:bindingController withKeyPath:@"values.available" options:nil];
    NSSwitch *control = [RCPreferencesPage switchForController:probe key:@"setting"];
    @try {
        [control performClick:nil];
        XCTAssertTrue([defaults boolForKey:@"flag"]);
        [bindingController setValue:@NO forKeyPath:@"values.flag"];
        XCTAssertEqual(control.state, NSControlStateValueOff);
        [bindingController setValue:@NO forKeyPath:@"values.available"];
        XCTAssertFalse(control.enabled);
    } @finally {
        [control unbind:NSValueBinding];
        [control unbind:NSEnabledBinding];
        [defaults removePersistentDomainForName:suite];
    }
}

- (void)assertModernControls:(NSView *)view {
    if ([view isKindOfClass:NSButton.class]) {
        // Explicit source-information consent is required to remain a checkbox.
        if ([view.identifier isEqualToString:@"bugReportSourceConsent"]) {
            XCTAssertEqualObjects(view.accessibilityRole, NSAccessibilityCheckBoxRole);
        } else {
            XCTAssertNotEqualObjects(view.accessibilityRole, NSAccessibilityCheckBoxRole);
        }
    }
    for (NSView *child in view.subviews) { [self assertModernControls:child]; }
}

- (void)testBrandFooterIsProportionalPinnedAndSeparateFromNavigation {
    RCPreferencesRefreshProbe *controller = [self refreshController];
    NSWindow *window = controller.window;
    NSImageView *footer = [controller valueForKey:@"brandFooter"];
    NSTableView *sidebar = [controller valueForKey:@"sidebar"];
    NSScrollView *navigation = sidebar.enclosingScrollView;
    XCTAssertNotNil(footer.image);
    XCTAssertTrue(footer.image.isTemplate);
    XCTAssertEqualObjects(footer.accessibilityLabel, @"Built by RevC");
    XCTAssertEqualObjects(footer.contentTintColor, [NSColor.secondaryLabelColor colorWithAlphaComponent:0.25]);
    XCTAssertEqual(footer.superview, navigation.superview);
    XCTAssertFalse([footer isDescendantOf:navigation]);
    NSArray<NSValue *> *sizes = @[[NSValue valueWithSize:NSMakeSize(860, 520)], [NSValue valueWithSize:NSMakeSize(1200, 800)]];
    for (NSValue *value in sizes) {
        [window setContentSize:value.sizeValue];
        [window.contentView layoutSubtreeIfNeeded];
        XCTAssertEqualWithAccuracy(NSMinX(footer.frame), 20, 0.5);
        XCTAssertEqualWithAccuracy(NSMinY(footer.frame), 20, 0.5);
        XCTAssertGreaterThan(NSHeight(footer.frame), 0);
        XCTAssertLessThanOrEqual(NSHeight(footer.frame), 20.0 * 2.0 / 3.0 + 0.5);
        XCTAssertLessThanOrEqual(NSWidth(footer.frame), (NSWidth(footer.superview.bounds) - 40) * 2.0 / 3.0 + 0.5);
        XCTAssertEqual(footer.imageScaling, NSImageScaleProportionallyUpOrDown);
        XCTAssertEqualWithAccuracy(footer.image.size.width / footer.image.size.height, 2089.0 / 200.0, 0.001);
        // The view frame is pixel-aligned; proportional image scaling preserves artwork aspect.
        CGFloat pixel = 1.0 / MAX(window.backingScaleFactor, 1.0);
        XCTAssertEqualWithAccuracy(NSHeight(footer.frame), NSWidth(footer.frame) / (2089.0 / 200.0), pixel);
        XCTAssertGreaterThanOrEqual(NSMinY(navigation.frame), NSMaxY(footer.frame) + 15.5);
        NSRect pinnedFrame = footer.frame;
        NSInteger panicRow = [[controller valueForKey:@"tabIdentifiers"] indexOfObject:RCPreferencesTabPanic];
        [sidebar scrollRowToVisible:panicRow];
        [window.contentView layoutSubtreeIfNeeded];
        XCTAssertTrue(NSIntersectsRect([sidebar rectOfRow:panicRow], sidebar.visibleRect));
        XCTAssertTrue(NSEqualRects(pinnedFrame, footer.frame));
    }
}

- (void)testBrandHeaderHasLargerIconAndCenteredPoppinsWordmark {
    RCPreferencesRefreshProbe *controller = [self refreshController];
    [controller.window setContentSize:NSMakeSize(860, 520)];
    [controller.window.contentView layoutSubtreeIfNeeded];
    NSTextField *wordmark = [controller valueForKey:@"brandWordmark"];
    NSView *icon = nil;
    for (NSView *view in wordmark.superview.subviews) {
        if ([view.identifier isEqualToString:@"preferencesBrandIcon"]) { icon = view; break; }
    }
    XCTAssertNotNil(icon);
    XCTAssertEqualObjects(wordmark.stringValue, @"revclip");
    XCTAssertEqualObjects(wordmark.font.fontName, @"Poppins-SemiBold");
    XCTAssertEqualWithAccuracy(wordmark.font.pointSize, 22, 0.01);
    XCTAssertEqualWithAccuracy(NSWidth(icon.frame), 42, 0.5);
    XCTAssertEqualWithAccuracy(NSHeight(icon.frame), 42, 0.5);
    XCTAssertLessThan(wordmark.font.pointSize, NSHeight(icon.frame));
    // AppKit text-field frames extend beyond their alignment rect (2pt horizontally).
    NSRect wordmarkAlignment = [wordmark alignmentRectForFrame:wordmark.frame];
    NSRect iconAlignment = [icon alignmentRectForFrame:icon.frame];
    XCTAssertEqualWithAccuracy(NSMidY(wordmarkAlignment), NSMidY(iconAlignment), 0.5);
    XCTAssertEqualWithAccuracy(NSMinX(wordmarkAlignment), NSMaxX(iconAlignment) + 10, 0.5);
    XCTAssertLessThanOrEqual(NSMaxX(wordmarkAlignment), NSWidth(wordmark.superview.bounds) - 19.5);
    NSBundle *bundle = NSBundle.mainBundle;
    NSURL *fontURL = [bundle URLForResource:@"Poppins-SemiBold" withExtension:@"ttf" subdirectory:@"Fonts"]
        ?: [bundle URLForResource:@"Poppins-SemiBold" withExtension:@"ttf"];
    NSURL *licenseURL = [bundle URLForResource:@"OFL" withExtension:@"txt" subdirectory:@"Fonts"]
        ?: [bundle URLForResource:@"OFL" withExtension:@"txt"];
    XCTAssertNotNil(fontURL);
    XCTAssertNotNil(licenseURL);
}

- (void)testWordmarkFontIsReusedAfterLanguageRefresh {
    RCPreferencesRefreshProbe *controller = [self refreshController];
    NSTextField *originalWordmark = [controller valueForKey:@"brandWordmark"];
    NSFont *font = originalWordmark.font;
    [NSNotificationCenter.defaultCenter postNotificationName:RCLanguageDidChangeNotification object:nil];
    [self notifySettings:@[@"language"]];
    NSTextField *wordmark = [controller valueForKey:@"brandWordmark"];
    XCTAssertNotEqual(wordmark, originalWordmark);
    XCTAssertEqualObjects(wordmark.font, font);
    XCTAssertEqualObjects(wordmark.stringValue, @"revclip");
}

- (void)testBrandFooterSurvivesLanguageShellRefreshAndBothAppearances {
    RCPreferencesRefreshProbe *controller = [self refreshController];
    NSImageView *originalFooter = [controller valueForKey:@"brandFooter"];
    [NSNotificationCenter.defaultCenter postNotificationName:RCLanguageDidChangeNotification object:nil];
    [self notifySettings:@[@"language"]];
    NSImageView *footer = [controller valueForKey:@"brandFooter"];
    XCTAssertNotEqual(footer, originalFooter);
    XCTAssertEqualObjects(footer.identifier, @"preferencesBrandFooter");
    for (NSAppearanceName name in @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]) {
        controller.window.appearance = [NSAppearance appearanceNamed:name];
        [controller.window.contentView layoutSubtreeIfNeeded];
        XCTAssertNotNil(footer.image);
        XCTAssertTrue(footer.image.isTemplate);
        XCTAssertEqualWithAccuracy(footer.contentTintColor.alphaComponent, 0.25, 0.01);
        XCTAssertFalse(footer.hidden);
    }
}

- (void)testEverySectionKeepsWindowSizeAndScrollableContent {
    RCPreferencesWindowController *controller = [RCPreferencesWindowController new];
    NSWindow *window = controller.window;
    NSRect frame = window.frame;
    XCTAssertNil(window.toolbar);
    XCTAssertFalse([[controller valueForKey:@"tabIdentifiers"] containsObject:@"beta"]);
    for (NSString *tab in @[@"general", @"appearance", @"menu", @"type", @"exclude", @"shortcuts", @"updates", @"agents", RCPreferencesTabBugReport, @"panic", @"general", @"menu"]) {
        [controller showTab:tab];
        [window.contentView layoutSubtreeIfNeeded];
        XCTAssertTrue(NSEqualRects(frame, window.frame));
        XCTAssertEqualObjects([controller valueForKey:@"selectedTab"], tab);
        NSScrollView *scroll = [controller valueForKey:@"pageScrollView"];
        XCTAssertNotNil(scroll.documentView);
        XCTAssertEqualWithAccuracy(scroll.documentView.frame.size.width, scroll.contentView.bounds.size.width, 1);
        [self assertModernControls:scroll.documentView];
    }
    [window setContentSize:NSMakeSize(860, 520)];
    [window.contentView layoutSubtreeIfNeeded];
    NSScrollView *scroll = [controller valueForKey:@"pageScrollView"];
    XCTAssertGreaterThan(scroll.documentView.frame.size.height, scroll.contentView.bounds.size.height);
    [window orderOut:nil];
}
- (void)testAdvancedTabsPreserveDeepLinksAndRememberCategory {
    RCPreferencesRefreshProbe *controller = [self refreshController];
    [controller showTab:@"type"];
    NSSegmentedControl *categories = [controller valueForKey:@"categoryTabs"];
    NSTableView *sidebar = [controller valueForKey:@"sidebar"];
    XCTAssertFalse(categories.hidden);
    XCTAssertEqual(categories.segmentCount, 4);
    XCTAssertEqualObjects([[controller valueForKey:@"tabIdentifiers"] objectAtIndex:sidebar.selectedRow], @"advanced");
    XCTAssertEqualObjects([controller valueForKey:@"selectedTab"], @"type");
    [controller showTab:@"general"];
    XCTAssertTrue(categories.hidden);
    [controller showTab:@"advanced"];
    XCTAssertEqualObjects([controller valueForKey:@"selectedTab"], @"type");
    [controller showTab:@"permissions"];
    XCTAssertEqualObjects([[controller valueForKey:@"tabIdentifiers"] objectAtIndex:sidebar.selectedRow], @"permissions");
    XCTAssertTrue(categories.hidden);
    [controller showTab:@"panic"];
    XCTAssertEqualObjects([[controller valueForKey:@"tabIdentifiers"] objectAtIndex:sidebar.selectedRow], @"panic");
    XCTAssertTrue(categories.hidden);
    [controller showTab:@"exclude"];
    XCTAssertEqual(categories.segmentCount, 2);
    [controller showTab:@"general"];
    [controller showTab:@"privacy"];
    XCTAssertEqualObjects([controller valueForKey:@"selectedTab"], @"exclude");
}
@end
