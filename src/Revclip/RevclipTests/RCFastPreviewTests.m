#import <XCTest/XCTest.h>
#import "RCFastPreviewController.h"
@interface RCFastPreviewController (Testing)
@property (readonly) NSPanel *panel;
@end
@interface RCPreviewTestMenu : NSMenu
@property NSMenuItem *testHighlightedItem;
@property NSRect testFrame;
@end
@implementation RCPreviewTestMenu
- (NSMenuItem *)highlightedItem { return self.testHighlightedItem; }
- (NSRect)accessibilityFrame { return self.testFrame; }
@end
@interface RCFastPreviewTests : XCTestCase
@end
@implementation RCFastPreviewTests
- (void)waitForTrackingTimer {
    XCTestExpectation *elapsed = [self expectationWithDescription:@"Preview delay elapsed"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [elapsed fulfill]; });
    [self waitForExpectations:@[elapsed] timeout:2];
}
- (void)testLeavingRowBeforeDelayCannotShowStalePreview {
    RCFastPreviewController *controller = [RCFastPreviewController new];
    RCPreviewTestMenu *menu = [RCPreviewTestMenu new];
    menu.autoenablesItems = NO;
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"Test" action:nil keyEquivalent:@""];
    [menu addItem:item]; item.enabled = YES; menu.testHighlightedItem = item;
    [controller highlightItem:item text:@"Old text"];
    [controller highlightItem:nil text:nil];
    [self waitForTrackingTimer];
    XCTAssertFalse(controller.panel.visible);
}
- (void)testPreviewCannotTakeFocusAndHideClosesIt {
    RCFastPreviewController *controller = [RCFastPreviewController new];
    RCPreviewTestMenu *menu = [RCPreviewTestMenu new];
    menu.autoenablesItems = NO;
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"Test" action:nil keyEquivalent:@""];
    [menu addItem:item]; item.enabled = YES; menu.testHighlightedItem = item;
    NSScreen *screen = NSScreen.mainScreen;
    for (NSScreen *candidate in NSScreen.screens) if (NSPointInRect(NSEvent.mouseLocation, candidate.frame)) screen = candidate;
    NSRect screenFrame = screen.visibleFrame;
    menu.testFrame = NSMakeRect(NSMidX(screenFrame)-150, NSMidY(screenFrame), 300, 90);
    NSWindow *keyWindow = NSApp.keyWindow;
    [controller highlightItem:item text:@"Preview"];
    [self waitForTrackingTimer];
    XCTAssertTrue(controller.panel.visible);
    XCTAssertTrue(controller.panel.ignoresMouseEvents);
    XCTAssertFalse(controller.panel.canBecomeKeyWindow);
    XCTAssertFalse(controller.panel.canBecomeMainWindow);
    XCTAssertEqual(NSApp.keyWindow, keyWindow);
    XCTAssertEqualWithAccuracy(NSMinX(controller.panel.frame), NSMinX(menu.testFrame), 0.5);
    XCTAssertEqualWithAccuracy(NSMaxY(controller.panel.frame), NSMinY(menu.testFrame)-8, 0.5);
    XCTAssertEqualWithAccuracy(NSWidth(controller.panel.frame), NSWidth(menu.testFrame), 0.5);
    menu.testFrame = NSMakeRect(NSMinX(menu.testFrame), NSMinY(screenFrame)+2, 300, 90);
    [controller highlightItem:item text:@"Preview at screen bottom"];
    [self waitForTrackingTimer];
    XCTAssertEqualWithAccuracy(NSMinY(controller.panel.frame), NSMaxY(menu.testFrame)+8, 0.5);
    [controller hide];
    XCTAssertFalse(controller.panel.visible);
}
@end
