#import <XCTest/XCTest.h>
#import <AppKit/AppKit.h>
#import "RCGeneralPreferencesViewController.h"
#import "RCPanicPreferencesViewController.h"
#import "RCMenuPreferencesViewController.h"

@interface RCLocalizedInterfaceTests : XCTestCase
@end

@implementation RCLocalizedInterfaceTests
- (void)testGeneralNibUsesTheSelectedLanguage {
    RCGeneralPreferencesViewController *controller = [[RCGeneralPreferencesViewController alloc] initWithNibName:@"RCGeneralPreferencesView" bundle:nil];
    NSView *view = controller.view;
    NSString *expected = NSLocalizedStringFromTable(@"nK7-cV-2pR.title", @"RCGeneralPreferencesView", nil);
    XCTAssertNotEqualObjects(expected, @"nK7-cV-2pR.title");
    XCTAssertEqualObjects(controller.autoExpiryEnabledButton.title, expected);
    XCTAssertEqualObjects(controller.autoExpiryUnitPopUpButton.itemTitles, (@[NSLocalizedString(@"Days", nil), NSLocalizedString(@"Hours", nil), NSLocalizedString(@"Minutes", nil)]));
    [self attachView:view name:@"General preferences"];
}

- (void)testMenuPreferencesRenderTranslatedLabels {
    RCMenuPreferencesViewController *controller = [[RCMenuPreferencesViewController alloc] initWithNibName:@"RCMenuPreferencesView" bundle:nil];
    [self attachView:controller.view name:@"Menu preferences"];
}

- (void)testDeletionExplainsScopeWithoutExecutingIt {
    RCPanicPreferencesViewController *controller = [[RCPanicPreferencesViewController alloc] initWithNibName:@"RCPanicPreferencesView" bundle:nil];
    NSView *view = controller.view;
    NSButton *button = [controller valueForKey:@"eraseButton"];
    XCTAssertEqualObjects(button.title, NSLocalizedString(@"Delete All Revclip Data", nil));
    [view layoutSubtreeIfNeeded];
    XCTAssertTrue(NSContainsRect(view.bounds, button.frame));
    [self attachView:view name:@"Revclip data deletion scope"];
    // No confirmation text is entered, and no erase action is sent.
}

- (void)attachView:(NSView *)view name:(NSString *)name {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:view.frame styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    NSView *background = [[NSView alloc] initWithFrame:view.bounds];
    background.wantsLayer = YES;
    background.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;
    window.contentView = background;
    [background addSubview:view];
    [view layoutSubtreeIfNeeded];
    NSBitmapImageRep *bitmap = [background bitmapImageRepForCachingDisplayInRect:background.bounds];
    XCTAssertNotNil(bitmap);
    [background cacheDisplayInRect:background.bounds toBitmapImageRep:bitmap];
    NSImage *image = [[NSImage alloc] initWithSize:view.bounds.size];
    [image addRepresentation:bitmap];
    XCTAttachment *attachment = [XCTAttachment attachmentWithImage:image];
    attachment.name = [NSString stringWithFormat:@"%@ — %@", name, NSBundle.mainBundle.preferredLocalizations.firstObject];
    attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:attachment];
    window.contentView = nil;
}
@end
