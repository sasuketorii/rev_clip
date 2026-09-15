#import <XCTest/XCTest.h>
#import "RCMenuManager.h"
#import "RCConstants.h"
#import "RCDatabaseManager.h"
#import "RCPasteService.h"
#import "RCClipData.h"
#import <objc/runtime.h>
static RCClipData *capturedMediaClip;
static void captureMediaPaste(id object, SEL selector, RCClipData *clip, NSRunningApplication *app) { capturedMediaClip = clip; }

@interface RCMenuManager (ParityTesting)
- (void)selectSnippetMenuItem:(NSMenuItem *)item;
- (void)appendSnippetDictionaries:(NSArray *)snippets folderIdentifier:(NSString *)identifier toMenu:(NSMenu *)menu;
- (void)handleUserDefaultsDidChange:(NSNotification *)notification;
- (void)handleClipboardDidChange:(NSNotification *)notification;
- (void)menuWillOpen:(NSMenu *)menu;
- (void)menuDidClose:(NSMenu *)menu;
@end
@interface RCTrackingTestManager : RCMenuManager
@property NSUInteger rebuilds;
@property NSUInteger faviconRequests;
@end
@implementation RCTrackingTestManager
- (void)applyStatusItemPreference {}
- (void)rebuildMenuInternal { self.rebuilds++; }
- (void)loadFaviconForMenuItem:(NSMenuItem *)item { self.faviconRequests++; }
@end
@interface RCMenuParityTests : XCTestCase
@end
@implementation RCMenuParityTests
- (void)settle {
    XCTestExpectation *e=[self expectationWithDescription:@"Debounce"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[e fulfill];});
    [self waitForExpectations:@[e] timeout:3];
}
- (void)testFrameworkDefaultsDoNotInvalidateOpenMenu {
    RCTrackingTestManager *manager=[RCTrackingTestManager new];
    NSMenu *menu=[NSMenu new];
    [manager menuWillOpen:menu];
    NSNumber *generation=[manager valueForKey:@"cacheGeneration"];
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"TestWebKitPreference"];
    [manager handleUserDefaultsDidChange:nil];
    [self settle];
    XCTAssertEqual(manager.rebuilds,0u);
    XCTAssertEqualObjects([manager valueForKey:@"cacheGeneration"],generation);
    [manager menuDidClose:menu];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"TestWebKitPreference"];
}
- (void)testHistoryAndPreferenceChangesWaitUntilAllMenusClose {
    RCTrackingTestManager *manager=[RCTrackingTestManager new];
    NSMenu *root=[NSMenu new],*child=[NSMenu new];
    id old=[NSUserDefaults.standardUserDefaults objectForKey:kRCThumbnailWidthKey];
    @try {
        [manager menuWillOpen:root]; [manager menuWillOpen:child];
        [manager handleClipboardDidChange:nil];
        [NSUserDefaults.standardUserDefaults setInteger:317 forKey:kRCThumbnailWidthKey];
        [manager handleUserDefaultsDidChange:nil];
        [self settle];
        XCTAssertEqual(manager.rebuilds,0u);
        [manager menuDidClose:child]; [self settle];
        XCTAssertEqual(manager.rebuilds,0u);
        [manager menuDidClose:root]; [self settle];
        XCTAssertEqual(manager.rebuilds,1u);
    } @finally {
        if(old)[NSUserDefaults.standardUserDefaults setObject:old forKey:kRCThumbnailWidthKey];
        else [NSUserDefaults.standardUserDefaults removeObjectForKey:kRCThumbnailWidthKey];
    }
}
- (void)testRegularBuildCreatesLinkColorAndMediaItems {
    RCTrackingTestManager *manager=[RCTrackingTestManager new];
    NSMenu *menu=[NSMenu new];
    NSBitmapImageRep *rep=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:24 pixelsHigh:12 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    memset(rep.bitmapData,255,rep.bytesPerRow*rep.pixelsHigh);
    NSData *png=[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [manager appendSnippetDictionaries:@[
        @{@"identifier":@"url",@"title":@"Site",@"content":@"https://example.com/"},
        @{@"identifier":@"color",@"title":@"Blue",@"content":@"#1E3A8A"},
        @{@"identifier":@"media",@"title":@"Image",@"content":@"",@"media_data":png}
    ] folderIdentifier:@"folder" toMenu:menu];
    XCTAssertEqual(menu.numberOfItems,3);
    NSMapTable *URLs=[manager valueForKey:@"previewURLs"];
    XCTAssertEqualObjects([[URLs objectForKey:[menu itemAtIndex:0]] absoluteString],@"https://example.com/");
    XCTAssertNotNil([menu itemAtIndex:0].image);
    XCTAssertFalse([menu itemAtIndex:1].image.template);
    NSMapTable *images=[manager valueForKey:@"previewImageData"];
    XCTAssertEqualObjects([images objectForKey:[menu itemAtIndex:2]],png);
    XCTAssertNotNil([menu itemAtIndex:2].image);
    [manager menuWillOpen:menu];
    XCTAssertEqual(manager.faviconRequests,3u);
    [manager menuDidClose:menu];
}
- (void)testRegularMediaSelectionPassesImageToPasteService {
    RCDatabaseManager *db = RCDatabaseManager.shared;
    XCTAssertTrue([db setupDatabase]); XCTAssertTrue([db migrateIfNeeded]);
    NSString *folder = NSUUID.UUID.UUIDString, *snippet = NSUUID.UUID.UUIDString;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:24 pixelsHigh:12 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    memset(rep.bitmapData,255,rep.bytesPerRow*rep.pixelsHigh);
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    XCTAssertTrue(([db insertSnippetFolder:@{@"identifier":folder,@"title":@"Test",@"folder_index":@0}]));
    XCTAssertTrue(([db insertSnippet:@{@"identifier":snippet,@"title":@"Image",@"content":@"",@"media_data":png} inFolder:folder]));
    Method method = class_getInstanceMethod(RCPasteService.class,@selector(pasteClipData:toApplication:));
    IMP original = method_setImplementation(method,(IMP)captureMediaPaste);
    @try {
        NSMenuItem *item = [NSMenuItem new];
        item.representedObject = @{@"folderIdentifier":folder,@"snippetIdentifier":snippet};
        [[RCMenuManager new] selectSnippetMenuItem:item];
        XCTAssertGreaterThan(capturedMediaClip.TIFFData.length,0u);
        XCTAssertEqualObjects(capturedMediaClip.primaryType,NSPasteboardTypeTIFF);
        NSPasteboard *board = [NSPasteboard pasteboardWithUniqueName];
        XCTAssertTrue([capturedMediaClip writeToPasteboard:board]);
        XCTAssertNotNil([[NSImage alloc] initWithData:[board dataForType:NSPasteboardTypeTIFF]]);
        [board releaseGlobally];
    } @finally {
        method_setImplementation(method,original);
        capturedMediaClip = nil;
        [db deleteSnippet:snippet]; [db deleteSnippetFolder:folder];
    }
}
@end
