#import <XCTest/XCTest.h>
#import "RCFastPreviewController.h"
#import "RCLinkPreviewService.h"
#import "RCMenuManager.h"
#import "RCClipItem.h"
#import "RCClipData.h"
@interface RCFastPreviewController (Testing)
@property (readonly) NSPanel *panel;
- (void)showText:(NSString *)text image:(NSImage *)image menu:(NSMenu *)menu aspectRatio:(CGFloat)ratio;
- (void)showLinkURL:(NSURL *)url title:(NSString *)title image:(NSImage *)image menu:(NSMenu *)menu;
@end
@interface RCPreviewTestMenu : NSMenu
@property NSMenuItem *testHighlightedItem;
@property NSRect testFrame;
@end
@implementation RCPreviewTestMenu
- (NSMenuItem *)highlightedItem { return self.testHighlightedItem; }
- (NSRect)accessibilityFrame { return self.testFrame; }
@end
@interface RCMenuManager (HistoryPreviewTesting)
- (NSMenuItem *)clipMenuItemForClipItem:(RCClipItem *)clip globalIndex:(NSUInteger)index;
- (void)menuWillOpen:(NSMenu *)menu;
- (void)menuDidClose:(NSMenu *)menu;
- (void)menu:(NSMenu *)menu willHighlightItem:(NSMenuItem *)item;
@end
@interface RCHistoryPreviewTestManager : RCMenuManager
@property NSUInteger archiveReads;
@property NSUInteger previewReads;
@end
@implementation RCHistoryPreviewTestManager
- (id)clipDataForPath:(NSString *)path {
    self.archiveReads++;
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:2200 pixelsHigh:1400 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    memset(bitmap.bitmapData,255,bitmap.bytesPerRow*bitmap.pixelsHigh);
    RCClipData *data = [RCClipData new];
    data.TIFFData = [bitmap representationUsingType:NSBitmapImageFileTypeTIFF properties:@{}];
    return data;
}
- (NSImage *)resizedThumbnailImageAtPath:(NSString *)path targetSize:(NSSize)size {
    self.previewReads++;
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:80 pixelsHigh:40 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    memset(bitmap.bitmapData,255,bitmap.bytesPerRow*bitmap.pixelsHigh);
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(80,40)]; [image addRepresentation:bitmap]; return image;
}
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
    __attribute__((objc_precise_lifetime)) RCPreviewTestMenu *menu = [RCPreviewTestMenu new];
    menu.autoenablesItems = NO;
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"Test" action:nil keyEquivalent:@""];
    [menu addItem:item]; item.enabled = YES; menu.testHighlightedItem = item;
    [controller highlightItem:item text:@"Old text"];
    [controller highlightItem:nil text:nil];
    [self waitForTrackingTimer];
    XCTAssertFalse(controller.panel.visible);
    XCTAssertNil(controller.panel.contentView);
}
- (void)testPreviewCannotTakeFocusAndHideClosesIt {
    RCFastPreviewController *controller = [RCFastPreviewController new];
    __attribute__((objc_precise_lifetime)) RCPreviewTestMenu *menu = [RCPreviewTestMenu new];
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
    XCTAssertNil(controller.panel.contentView);
}
- (void)testImagePreviewFitsNarrowMenuAndCancelsOnLeave {
    RCFastPreviewController *controller = [RCFastPreviewController new];
    __attribute__((objc_precise_lifetime)) RCPreviewTestMenu *menu = [RCPreviewTestMenu new];
    menu.autoenablesItems = NO;
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"Image" action:nil keyEquivalent:@""];
    [menu addItem:item]; item.enabled = YES; menu.testHighlightedItem = item;
    NSRect screen = NSScreen.mainScreen.visibleFrame;
    menu.testFrame = NSMakeRect(NSMidX(screen), NSMidY(screen), 220, 90);
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:80 pixelsHigh:160 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    memset(bitmap.bitmapData, 180, bitmap.bytesPerRow * bitmap.pixelsHigh);
    NSData *data = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [controller highlightItem:item text:nil imageData:data];
    [self waitForTrackingTimer];
    XCTAssertTrue(controller.panel.visible);
    XCTAssertEqualWithAccuracy(NSWidth(controller.panel.frame),220,0.5);
    XCTAssertLessThanOrEqual(NSHeight(controller.panel.frame),360);
    NSImageView *imageView = (NSImageView *)controller.panel.contentView.subviews.firstObject;
    XCTAssertTrue([imageView isKindOfClass:NSImageView.class]);
    XCTAssertNotNil(imageView.image);
    XCTAssertEqual(imageView.imageScaling,NSImageScaleProportionallyUpOrDown);
    XCTAssertLessThanOrEqual(NSMaxX(imageView.frame),NSWidth(controller.panel.frame));
    [controller highlightItem:item text:nil imageData:data];
    [controller hide];
    [self waitForTrackingTimer];
    XCTAssertFalse(controller.panel.visible);
    XCTAssertNil(controller.panel.contentView);
}
- (void)testLinkDetectionRequiresOnlyURLAndExcludesTextAndEmail {
    XCTAssertEqualObjects([RCLinkPreviewService URLForText:@" https://company.rev-c.com/#top "].absoluteString,@"https://company.rev-c.com/");
    XCTAssertEqualObjects([RCLinkPreviewService URLForText:@"rev-c.com"].absoluteString,@"https://rev-c.com");
    XCTAssertEqualObjects([RCLinkPreviewService URLForText:@"http://rev-c.com/"].scheme,@"http");
    for (NSString *text in @[@"rev-c.com\nこんな感じどう？",@"本文 https://company.rev-c.com/ 続き",@"mail@rev-c.com\nhttps://company.rev-c.com/",@"https://rev-c.com/\nhttps://example.com/"]) {
        XCTAssertNil([RCLinkPreviewService URLForText:text]);
    }
    for (NSString *text in @[@"hello@company.rev-c.com",@"mailto:hello@rev-c.com",@"file:///tmp/image.png",@"https://user:pass@example.com/",@"javascript:alert(1)",@"ordinary text"]) {
        XCTAssertNil([RCLinkPreviewService URLForText:text]);
    }
}
- (void)testLinkPanelHasExactSixteenNineAspectAndKeepsMenuWidth {
    RCFastPreviewController *controller = [RCFastPreviewController new];
    __attribute__((objc_precise_lifetime)) RCPreviewTestMenu *menu = [RCPreviewTestMenu new];
    NSRect screen = NSScreen.mainScreen.visibleFrame;
    menu.testFrame = NSMakeRect(NSMidX(screen),NSMidY(screen),320,80);
    [controller showText:@"https://company.rev-c.com/" image:nil menu:menu aspectRatio:16.0/9.0];
    XCTAssertEqualWithAccuracy(controller.panel.frame.size.width,320,0.5);
    XCTAssertEqualWithAccuracy(controller.panel.frame.size.height,180,0.5);
    XCTAssertFalse(controller.panel.canBecomeKeyWindow);
    [controller hide];
}
- (void)testHTTPCardShowsWarningTitleAndLinkBelowSixteenNineImage {
    RCFastPreviewController *controller = [RCFastPreviewController new];
    __attribute__((objc_precise_lifetime)) RCPreviewTestMenu *menu = [RCPreviewTestMenu new];
    menu.testFrame = NSMakeRect(200,500,320,80);
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(640,360)];
    [controller showLinkURL:[NSURL URLWithString:@"http://rev-c.com/"] title:@"公式サイト" image:image menu:menu];
    NSImageView *view = (NSImageView *)controller.panel.contentView.subviews[0];
    XCTAssertEqualWithAccuracy(view.frame.size.width / view.frame.size.height,16.0/9.0,0.01);
    NSTextField *caption = (NSTextField *)controller.panel.contentView.subviews.lastObject;
    XCTAssertTrue([caption.stringValue containsString:@"⚠️ http://rev-c.com/"]);
    XCTAssertEqualObjects([(NSTextField *)controller.panel.contentView.subviews[1] stringValue],@"公式サイト");
    [controller showLinkURL:[NSURL URLWithString:@"https://rev-c.com/"] title:@"公式サイト" image:image menu:menu];
    caption = (NSTextField *)controller.panel.contentView.subviews.lastObject;
    XCTAssertFalse([caption.stringValue containsString:@"⚠️"]);
    [controller hide];
}
- (void)testHistoryImageHoverUsesFullResolutionArchiveAndCachesDownsample {
    RCHistoryPreviewTestManager *manager = [RCHistoryPreviewTestManager new];
    RCClipItem *clip = [[RCClipItem alloc] initWithDictionary:@{@"id":@101,@"data_path":@"fixture.rcclip",@"data_hash":@"history-image",@"thumbnail_path":@"fixture.thumb",@"primary_type":NSPasteboardTypeTIFF}];
    NSMenuItem *item = [manager clipMenuItemForClipItem:clip globalIndex:0];
    __attribute__((objc_precise_lifetime)) RCPreviewTestMenu *menu = [RCPreviewTestMenu new]; menu.autoenablesItems = NO;
    [manager menuWillOpen:menu];
    menu.testFrame = NSMakeRect(200,500,300,90); [menu addItem:item]; item.enabled = YES; menu.testHighlightedItem = item;
    [manager menu:menu willHighlightItem:item];
    RCFastPreviewController *preview = [manager valueForKey:@"previewController"];
    NSPredicate *visible = [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
        return preview.panel.visible && [preview.panel.contentView.subviews.firstObject isKindOfClass:NSImageView.class];
    }];
    XCTNSPredicateExpectation *loaded = [[XCTNSPredicateExpectation alloc] initWithPredicate:visible object:nil];
    [self waitForExpectations:@[loaded] timeout:4];
    XCTAssertTrue(preview.panel.visible);
    XCTAssertTrue([preview.panel.contentView.subviews.firstObject isKindOfClass:NSImageView.class]);
    XCTAssertEqual(manager.archiveReads,1); XCTAssertEqual(manager.previewReads,0);
    NSImageView *imageView = (NSImageView *)preview.panel.contentView.subviews.firstObject;
    NSImageRep *rep = imageView.image.representations.firstObject;
    XCTAssertEqual(rep.pixelsWide,720);
    XCTAssertGreaterThan(rep.pixelsHigh,400);
    [manager menu:menu willHighlightItem:item]; [self waitForTrackingTimer];
    XCTAssertEqual(manager.previewReads,0); XCTAssertEqual(manager.archiveReads,1);
    [manager clearThumbnailCache]; XCTAssertFalse(preview.panel.visible);
    [manager menuDidClose:menu];
}
- (void)testLeavingHistoryImageBeforeDelayDoesNoImageIO {
    RCHistoryPreviewTestManager *manager = [RCHistoryPreviewTestManager new];
    RCClipItem *clip = [[RCClipItem alloc] initWithDictionary:@{@"id":@102,@"data_path":@"fixture.rcclip",@"data_hash":@"leave-image",@"thumbnail_path":@"fixture.thumb",@"primary_type":NSPasteboardTypeTIFF}];
    NSMenuItem *item = [manager clipMenuItemForClipItem:clip globalIndex:0];
    __attribute__((objc_precise_lifetime)) RCPreviewTestMenu *menu = [RCPreviewTestMenu new]; [menu addItem:item]; menu.testHighlightedItem = item;
    [manager menu:menu willHighlightItem:item]; menu.testHighlightedItem = nil;
    [manager menu:menu willHighlightItem:nil]; [self waitForTrackingTimer];
    XCTAssertEqual(manager.previewReads,0); XCTAssertEqual(manager.archiveReads,0);
}
@end
