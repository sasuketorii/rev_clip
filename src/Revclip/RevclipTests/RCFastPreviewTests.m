#import <XCTest/XCTest.h>
#import "RCFastPreviewController.h"
#import "RCLinkPreviewService.h"
#import "RCMenuManager.h"
#import "RCClipItem.h"
#import "RCClipData.h"
#import "RCMenuStyle.h"
#import "RCSVGPreview.h"
@interface RCFastPreviewController (Testing)
@property (readonly) NSPanel *panel;
@property (readonly) NSTimer *timer;
@property (readonly) NSOperationQueue *svgQueue;
@property (readonly) NSBlockOperation *svgOperation;
@property (readonly) NSBlockOperation *pendingSVGOperation;
- (NSColor *)SVGColorForMenu:(NSMenu *)menu;
- (NSImage *)renderSVG:(NSString *)svg color:(NSColor *)color size:(CGFloat)size;
- (void)showText:(NSString *)text image:(NSImage *)image menu:(NSMenu *)menu;
- (void)showText:(NSString *)text image:(NSImage *)image menu:(NSMenu *)menu aspectRatio:(CGFloat)ratio;
- (void)showLinkURL:(NSURL *)url title:(NSString *)title image:(NSImage *)image menu:(NSMenu *)menu;
- (NSEventModifierFlags)previewModifierFlags;
- (void)requestLinkPreview;
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
@interface RCSVGTestPreviewController : RCFastPreviewController
@property (copy) NSImage *(^renderBlock)(NSString *, NSColor *, CGFloat);
@property (copy) void (^showBlock)(NSString *, NSImage *);
@end
@implementation RCSVGTestPreviewController
- (NSImage *)renderSVG:(NSString *)svg color:(NSColor *)color size:(CGFloat)size {
    return self.renderBlock ? self.renderBlock(svg,color,size) : [super renderSVG:svg color:color size:size];
}
- (void)showText:(NSString *)text image:(NSImage *)image menu:(NSMenu *)menu {
    [super showText:text image:image menu:menu];
    if (self.showBlock) self.showBlock(text,image);
}
@end
@interface RCManualLinkPreviewProbe : RCFastPreviewController
@property NSUInteger requests;
@property NSEventModifierFlags fixtureModifiers;
@end
@implementation RCManualLinkPreviewProbe
- (void)requestLinkPreview { self.requests++; }
- (NSEventModifierFlags)previewModifierFlags { return self.fixtureModifiers; }
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
- (RCPreviewTestMenu *)SVGMenu {
    RCPreviewTestMenu *menu = [RCPreviewTestMenu new];
    menu.autoenablesItems = NO;
    menu.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    menu.testFrame = NSMakeRect(200,500,300,90);
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"SVG" action:nil keyEquivalent:@""];
    [menu addItem:item]; item.enabled = YES; menu.testHighlightedItem = item;
    return menu;
}
- (void)testSVGWaitsForHoverAndCapturesUntruncatedImmutableCode {
    RCSVGTestPreviewController *controller = [RCSVGTestPreviewController new];
    RCPreviewTestMenu *menu = [self SVGMenu];
    NSMutableString *source = [@"<svg viewBox='0 0 10 10'>" mutableCopy];
    [source appendString:[@"" stringByPaddingToLength:2500 withString:@" " startingAtIndex:0]];
    [source appendString:@"<path d='M0 0L10 10'/></svg>"];
    NSString *original = [source copy];
    XCTestExpectation *rendered = [self expectationWithDescription:@"Full SVG rendered on worker"];
    XCTestExpectation *shown = [self expectationWithDescription:@"SVG completion presents on main"];
    NSImage *result = [[NSImage alloc] initWithSize:NSMakeSize(20,20)];
    controller.renderBlock = ^NSImage *(NSString *svg, NSColor *color, CGFloat size) {
        XCTAssertFalse(NSThread.isMainThread);
        XCTAssertEqualObjects(svg,original); XCTAssertEqual(size,720);
        XCTAssertNotNil(color); [rendered fulfill]; return result;
    };
    controller.showBlock = ^(NSString *text, NSImage *image) {
        XCTAssertTrue(NSThread.isMainThread); XCTAssertEqual(image,result);
        XCTAssertLessThan(text.length,original.length); [shown fulfill];
    };
    [controller highlightItem:menu.testHighlightedItem text:source];
    XCTAssertNil(controller.svgQueue); XCTAssertFalse(controller.panel.visible);
    [source setString:@"clipboard changed after hover"];
    [controller.timer fire];
    [self waitForExpectations:@[rendered,shown] timeout:3];
    [controller hide];
}
- (void)testLeavingSVGBeforeDelayStartsNoDecode {
    RCSVGTestPreviewController *controller = [RCSVGTestPreviewController new];
    RCPreviewTestMenu *menu = [self SVGMenu];
    controller.renderBlock = ^NSImage *(NSString *svg, NSColor *color, CGFloat size) { XCTFail(@"Unexpected decode after hide"); return nil; };
    [controller highlightItem:menu.testHighlightedItem text:@"<svg viewBox='0 0 10 10'/>"];
    [controller hide]; [self waitForTrackingTimer];
    XCTAssertNil(controller.svgQueue); XCTAssertFalse(controller.panel.visible);
}
- (void)testSVGRapidHoverKeepsOnlyLatestPendingAndDropsStaleCompletion {
    RCSVGTestPreviewController *controller = [RCSVGTestPreviewController new];
    RCPreviewTestMenu *menu = [self SVGMenu];
    dispatch_semaphore_t release = dispatch_semaphore_create(0);
    XCTestExpectation *started = [self expectationWithDescription:@"First decode running"];
    XCTestExpectation *shown = [self expectationWithDescription:@"Only latest hover shown"];
    NSString *first = @"<svg viewBox='0 0 10 10'/>";
    NSString *second = @"<svg viewBox='0 0 20 20'/>";
    NSString *latest = @"<svg viewBox='0 0 30 30'/>";
    __block NSUInteger calls = 0;
    controller.renderBlock = ^NSImage *(NSString *svg, NSColor *color, CGFloat size) {
        calls++;
        if ([svg isEqual:first]) {
            [started fulfill];
            dispatch_semaphore_wait(release, dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC));
        } else XCTAssertEqualObjects(svg,latest);
        return [[NSImage alloc] initWithSize:NSMakeSize(20,20)];
    };
    controller.showBlock = ^(NSString *text, NSImage *image) { XCTAssertEqualObjects(text,latest); [shown fulfill]; };
    [controller highlightItem:menu.testHighlightedItem text:first]; [controller.timer fire];
    [self waitForExpectations:@[started] timeout:2];
    NSBlockOperation *old = controller.svgOperation;
    [controller highlightItem:menu.testHighlightedItem text:second]; [controller.timer fire];
    NSBlockOperation *replaced = controller.pendingSVGOperation;
    XCTAssertNotNil(replaced);
    [controller highlightItem:menu.testHighlightedItem text:latest]; [controller.timer fire];
    XCTAssertTrue(old.cancelled); XCTAssertTrue(replaced.cancelled);
    XCTAssertNotNil(controller.pendingSVGOperation);
    XCTAssertLessThanOrEqual(controller.svgQueue.operationCount,1);
    XCTAssertEqual(controller.svgQueue.maxConcurrentOperationCount,1);
    dispatch_semaphore_signal(release);
    [self waitForExpectations:@[shown] timeout:3];
    XCTAssertEqual(calls,2); [controller hide];
}
- (void)testSVGHideCancelsPendingAndRejectsRunningCompletion {
    RCSVGTestPreviewController *controller = [RCSVGTestPreviewController new];
    RCPreviewTestMenu *menu = [self SVGMenu];
    dispatch_semaphore_t release = dispatch_semaphore_create(0);
    XCTestExpectation *started = [self expectationWithDescription:@"Decode started"];
    __block NSUInteger calls = 0;
    controller.renderBlock = ^NSImage *(NSString *svg, NSColor *color, CGFloat size) {
        calls++; [started fulfill];
        dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC));
        return [[NSImage alloc] initWithSize:NSMakeSize(20,20)];
    };
    controller.showBlock = ^(NSString *text, NSImage *image) { XCTFail(@"Stale preview after hide"); };
    [controller highlightItem:menu.testHighlightedItem text:@"<svg viewBox='0 0 10 10'/>"]; [controller.timer fire];
    [self waitForExpectations:@[started] timeout:2];
    [controller highlightItem:menu.testHighlightedItem text:@"<svg viewBox='0 0 20 20'/>"]; [controller.timer fire];
    NSBlockOperation *pending = controller.pendingSVGOperation;
    XCTAssertNotNil(pending);
    [controller hide];
    XCTAssertTrue(pending.cancelled); XCTAssertNil(controller.pendingSVGOperation);
    dispatch_semaphore_signal(release);
    XCTNSPredicateExpectation *drained = [[XCTNSPredicateExpectation alloc] initWithPredicate:[NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) { return controller.svgOperation == nil; }] object:nil];
    [self waitForExpectations:@[drained] timeout:3];
    XCTAssertEqual(calls,1); XCTAssertFalse(controller.panel.visible);
}
- (void)testSVGCompletionChecksCurrentHighlightEvenWithoutHide {
    RCSVGTestPreviewController *controller = [RCSVGTestPreviewController new];
    RCPreviewTestMenu *menu = [self SVGMenu];
    dispatch_semaphore_t release = dispatch_semaphore_create(0);
    XCTestExpectation *started = [self expectationWithDescription:@"Decode started"];
    controller.renderBlock = ^NSImage *(NSString *svg, NSColor *color, CGFloat size) {
        [started fulfill]; dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC));
        return [[NSImage alloc] initWithSize:NSMakeSize(20,20)];
    };
    controller.showBlock = ^(NSString *text, NSImage *image) { XCTFail(@"Preview for unhighlighted row"); };
    [controller highlightItem:menu.testHighlightedItem text:@"<svg viewBox='0 0 10 10'/>"]; [controller.timer fire];
    [self waitForExpectations:@[started] timeout:2];
    menu.testHighlightedItem = nil; dispatch_semaphore_signal(release);
    XCTNSPredicateExpectation *drained = [[XCTNSPredicateExpectation alloc] initWithPredicate:[NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) { return controller.svgOperation == nil; }] object:nil];
    [self waitForExpectations:@[drained] timeout:3];
    XCTAssertFalse(controller.panel.visible); [controller hide];
}
- (void)testInvalidSVGFallsBackToText {
    RCSVGTestPreviewController *controller = [RCSVGTestPreviewController new];
    RCPreviewTestMenu *menu = [self SVGMenu];
    NSString *source = @"<svg viewBox='0 0 10 10'><image href='https://example.invalid/a'/></svg>";
    XCTestExpectation *shown = [self expectationWithDescription:@"Unsupported SVG shown as text"];
    controller.showBlock = ^(NSString *text, NSImage *image) {
        XCTAssertTrue(NSThread.isMainThread); XCTAssertNil(image); XCTAssertEqualObjects(text,source); [shown fulfill];
    };
    [controller highlightItem:menu.testHighlightedItem text:source]; [controller.timer fire];
    [self waitForExpectations:@[shown] timeout:3];
    XCTAssertTrue([controller.panel.contentView.subviews.firstObject isKindOfClass:NSTextField.class]);
    [controller hide];
}
- (void)testActualHermesSVGDecodesOnHoverWorker {
    NSString *tests = [[NSString stringWithUTF8String:__FILE__] stringByDeletingLastPathComponent];
    NSString *path = [[tests stringByAppendingPathComponent:@"../Revclip/Resources/AgentIcons/hermes.svg"] stringByStandardizingPath];
    NSError *error;
    NSString *svg = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
    XCTAssertNotNil(svg, @"%@",error);
    if (!svg) return;
    XCTAssertGreaterThan(svg.length,2000);
    RCSVGTestPreviewController *controller = [RCSVGTestPreviewController new];
    RCPreviewTestMenu *menu = [self SVGMenu];
    XCTestExpectation *shown = [self expectationWithDescription:@"Actual Hermes SVG renders after hover"];
    controller.renderBlock = ^NSImage *(NSString *fullCode, NSColor *color, CGFloat size) {
        XCTAssertFalse(NSThread.isMainThread); XCTAssertEqualObjects(fullCode,svg);
        return [RCSVGPreview imageForString:fullCode color:color size:size];
    };
    controller.showBlock = ^(NSString *text, NSImage *image) {
        XCTAssertTrue(NSThread.isMainThread); XCTAssertNotNil(image);
        XCTAssertTrue([image.representations.firstObject isKindOfClass:NSBitmapImageRep.class]);
        [shown fulfill];
    };
    [controller highlightItem:menu.testHighlightedItem text:svg];
    XCTAssertNil(controller.svgQueue);
    [controller.timer fire]; [self waitForExpectations:@[shown] timeout:4];
    [controller hide];
}
- (void)testSVGNormalTextColorResolvesAppearanceAndIgnoresHoverWhite {
    RCFastPreviewController *controller = [RCFastPreviewController new];
    RCPreviewTestMenu *menu = [self SVGMenu];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *palette = RCMenuStyle.paletteKey;
    id savedEnabled = [defaults objectForKey:@"RCMenuCustomColorsEnabled"];
    id savedPalette = [defaults objectForKey:palette];
    @try {
        [defaults setBool:NO forKey:@"RCMenuCustomColorsEnabled"];
        NSColor *light = [controller SVGColorForMenu:menu];
        menu.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        NSColor *dark = [controller SVGColorForMenu:menu];
        XCTAssertLessThan(light.redComponent,0.5); XCTAssertGreaterThan(dark.redComponent,0.5);
        [defaults setBool:YES forKey:@"RCMenuCustomColorsEnabled"];
        [defaults setObject:@{@"text":@"#204060",@"hoverText":@"#FFFFFF"} forKey:palette];
        menu.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        NSColor *custom = [controller SVGColorForMenu:menu];
        XCTAssertEqualWithAccuracy(custom.redComponent,32/255.0,0.01);
        XCTAssertEqualWithAccuracy(custom.greenComponent,64/255.0,0.01);
        XCTAssertEqualWithAccuracy(custom.blueComponent,96/255.0,0.01);
    } @finally {
        if (savedEnabled) [defaults setObject:savedEnabled forKey:@"RCMenuCustomColorsEnabled"]; else [defaults removeObjectForKey:@"RCMenuCustomColorsEnabled"];
        if (savedPalette) [defaults setObject:savedPalette forKey:palette]; else [defaults removeObjectForKey:palette];
    }
}
- (void)testManualFetchRequiresOptionHoverAndCancelsStaleHover {
    id saved = [NSUserDefaults.standardUserDefaults objectForKey:RCLinkPreviewModeKey];
    RCManualLinkPreviewProbe *controller = nil;
    @try {
        RCLinkPreviewService.shared.previewMode = RCLinkPreviewModeManual;
        controller = [RCManualLinkPreviewProbe new];
        __attribute__((objc_precise_lifetime)) RCPreviewTestMenu *menu = [RCPreviewTestMenu new];
        menu.autoenablesItems = NO;
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"synthetic link" action:nil keyEquivalent:@""];
        [menu addItem:item]; item.enabled = YES; menu.testHighlightedItem = item;
        [controller highlightItem:item text:@"https://example.invalid/fixture"];
        [self waitForTrackingTimer];
        XCTAssertEqual(controller.requests, 0u);
        controller.fixtureModifiers = NSEventModifierFlagOption;
        [controller highlightItem:item text:@"https://example.invalid/fixture"];
        [self waitForTrackingTimer];
        XCTAssertEqual(controller.requests, 1u);
        [controller highlightItem:item text:@"https://example.invalid/fixture"];
        NSTimer *cancelled = controller.timer;
        [controller hide]; [cancelled fire];
        XCTAssertEqual(controller.requests, 1u);
        controller.fixtureModifiers = NSEventModifierFlagOption | NSEventModifierFlagCommand;
        [controller highlightItem:item text:@"https://example.invalid/fixture"];
        [self waitForTrackingTimer];
        XCTAssertEqual(controller.requests, 1u);
    } @finally {
        [controller hide];
        if (saved) [NSUserDefaults.standardUserDefaults setObject:saved forKey:RCLinkPreviewModeKey];
        else [NSUserDefaults.standardUserDefaults removeObjectForKey:RCLinkPreviewModeKey];
    }
}

@end
