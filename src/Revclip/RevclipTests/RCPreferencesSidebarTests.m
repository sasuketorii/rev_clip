#import <XCTest/XCTest.h>
#import "RCPreferencesPage.h"
#import "RCPreferencesWindowController.h"

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
        XCTAssertNotEqualObjects(view.accessibilityRole, NSAccessibilityCheckBoxRole);
    }
    for (NSView *child in view.subviews) { [self assertModernControls:child]; }
}

- (void)testEverySectionKeepsWindowSizeAndScrollableContent {
    RCPreferencesWindowController *controller = [RCPreferencesWindowController new];
    NSWindow *window = controller.window;
    NSRect frame = window.frame;
    XCTAssertNil(window.toolbar);
    for (NSString *tab in @[@"general", @"appearance", @"menu", @"type", @"exclude", @"shortcuts", @"updates", @"beta", @"panic", @"general", @"menu"]) {
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
@end
