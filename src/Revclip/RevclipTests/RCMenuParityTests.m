#import <XCTest/XCTest.h>
#import "RCMenuManager.h"
#import "RCConstants.h"
#import "RCDatabaseManager.h"
#import "RCPasteService.h"
#import "RCClipData.h"
#import "RCClipItem.h"
#import "RCMenuStyle.h"
#import "RCAppDelegate.h"
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
- (void)selectClipMenuItem:(NSMenuItem *)item;
- (void)pasteClipWithDataHash:(NSString *)dataHash targetApplication:(NSRunningApplication *)application;
- (BOOL)captureServiceSelection:(NSMenuItem *)item;
- (BOOL)validateMenuItem:(NSMenuItem *)item;
- (BOOL)serviceMonitoringActive;
- (NSUInteger)serviceMonitoringGeneration;
- (BOOL)serviceModalWindowPresent;
- (NSTimeInterval)serviceNow;
- (void)presentServiceMenu:(NSMenu *)menu;
- (void)popUpMenuAtMouseLocation:(NSMenu *)menu;
- (void)popUpTransientMenu:(NSMenu *)menu;
- (void)trackMenu:(NSMenu *)menu atLocation:(NSPoint)location;
- (void)recordServiceHistoryUse:(NSString *)dataHash;
- (NSMenu *)buildServiceMenu;
- (NSString *)serviceTextForItem:(NSMenuItem *)item historyDataHash:(NSString **)outHash;
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
// The Services entry with everything outside it replaced: no real menu is shown, and
// the general pasteboard, the history and the paste service are never reached.
@interface RCServiceTestManager : RCTrackingTestManager
@property BOOL monitoring;
@property BOOL modal;
@property NSUInteger generation;
@property NSTimeInterval now;
@property NSUInteger presentations;
@property NSUInteger pastes;
@property (nonatomic, strong) NSMutableArray<NSMenu *> *trackedMenus;
@property BOOL buildThrows;
@property (nonatomic, strong) NSMenu *fixtureMenu;
@property (nonatomic, strong) NSMutableArray<NSString *> *historyUses;
@property (nonatomic, copy) void (^whileMenuIsOpen)(RCServiceTestManager *manager, NSMenu *menu);
@property (nonatomic, copy) void (^whileTextIsRead)(RCServiceTestManager *manager);
@end
@implementation RCServiceTestManager
- (instancetype)init {
    if ((self = [super init])) {
        _monitoring = YES; _generation = 3; _now = 100; _historyUses = [NSMutableArray array]; _trackedMenus = [NSMutableArray array];
        _fixtureMenu = [[NSMenu alloc] initWithTitle:@"fixture"];
        for (NSString *hash in @[@"text-hash", @"image-hash"]) {
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:hash action:@selector(selectClipMenuItem:) keyEquivalent:@""];
            item.target = self; item.representedObject = hash;
            [_fixtureMenu addItem:item];
        }
    }
    return self;
}
- (BOOL)serviceMonitoringActive { return self.monitoring; }
- (NSUInteger)serviceMonitoringGeneration { return self.generation; }
- (BOOL)serviceModalWindowPresent { return self.modal; }
- (NSTimeInterval)serviceNow { return self.now; }
- (NSMenu *)buildServiceMenu {
    if (self.buildThrows) @throw [NSException exceptionWithName:@"RCFixture" reason:@"menu construction failed" userInfo:nil];
    return self.fixtureMenu;
}
- (void)presentServiceMenu:(NSMenu *)menu { self.presentations++; if (self.whileMenuIsOpen) self.whileMenuIsOpen(self, menu); }
- (void)recordServiceHistoryUse:(NSString *)dataHash { [self.historyUses addObject:dataHash]; }
- (void)trackMenu:(NSMenu *)menu atLocation:(NSPoint)location { [self.trackedMenus addObject:menu]; }
- (void)pasteClipWithDataHash:(NSString *)dataHash targetApplication:(NSRunningApplication *)application { self.pastes++; }
- (NSString *)serviceTextForItem:(NSMenuItem *)item historyDataHash:(NSString **)outHash {
    if (self.whileTextIsRead) self.whileTextIsRead(self);
    if (![item.representedObject isEqual:@"text-hash"]) { *outHash = nil; return nil; }
    *outHash = @"text-hash"; return @"picked text";
}
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
- (void)spinDefaultRunLoop {
    XCTestExpectation *e=[self expectationWithDescription:@"Default run loop turn"];
    CFRunLoopPerformBlock(CFRunLoopGetMain(),kCFRunLoopDefaultMode,^{[e fulfill];});
    CFRunLoopWakeUp(CFRunLoopGetMain());
    [self waitForExpectations:@[e] timeout:3];
}
- (NSString *)answerOf:(RCServiceTestManager *)manager {
    NSPasteboard *board = [NSPasteboard pasteboardWithUniqueName];
    @try {
        [manager insertFromRevclip:board userData:nil error:NULL];
        return [board stringForType:NSPasteboardTypeString];
    } @finally { [board releaseGlobally]; }
}
- (void)testServiceReturnsThePickedTextOnTheServicePasteboardAndNeverPastes {
    RCServiceTestManager *manager = [RCServiceTestManager new];
    manager.whileMenuIsOpen = ^(RCServiceTestManager *m, NSMenu *menu) { [m selectClipMenuItem:menu.itemArray[0]]; };
    XCTAssertEqualObjects([self answerOf:manager], @"picked text");
    XCTAssertEqualObjects(manager.historyUses, (@[@"text-hash"]));
    XCTAssertEqual(manager.pastes, 0u, @"Choosing during a request records the item instead of pasting");
    // The request is over: the same choice is an ordinary paste again.
    [manager selectClipMenuItem:manager.fixtureMenu.itemArray[0]];
    XCTAssertEqual(manager.pastes, 1u);
    XCTAssertFalse([manager captureServiceSelection:manager.fixtureMenu.itemArray[0]]);
}
- (void)testServiceReturnsNothingForCancelNonTextStopAndTimeOut {
    RCServiceTestManager *manager = [RCServiceTestManager new];
    XCTAssertNil([self answerOf:manager], @"Cancelled: nothing chosen");
    manager.whileMenuIsOpen = ^(RCServiceTestManager *m, NSMenu *menu) { [m selectClipMenuItem:menu.itemArray[1]]; };
    XCTAssertNil([self answerOf:manager], @"An image has no text to return, and is not pasted instead");
    // Clear, Panic or quit while the menu was open, including a stop and restart.
    manager.whileMenuIsOpen = ^(RCServiceTestManager *m, NSMenu *menu) { [m selectClipMenuItem:menu.itemArray[0]]; m.generation++; };
    XCTAssertNil([self answerOf:manager]);
    manager.whileMenuIsOpen = ^(RCServiceTestManager *m, NSMenu *menu) { [m selectClipMenuItem:menu.itemArray[0]]; m.monitoring = NO; };
    XCTAssertNil([self answerOf:manager]);
    manager.monitoring = YES;
    // A stop from another thread while the stored text is read and decrypted.
    manager.whileMenuIsOpen = ^(RCServiceTestManager *m, NSMenu *menu) { [m selectClipMenuItem:menu.itemArray[0]]; };
    manager.whileTextIsRead = ^(RCServiceTestManager *m) { m.generation++; };
    XCTAssertNil([self answerOf:manager]);
    manager.whileTextIsRead = nil;
    // The requesting application may have stopped waiting.
    manager.whileMenuIsOpen = ^(RCServiceTestManager *m, NSMenu *menu) { [m selectClipMenuItem:menu.itemArray[0]]; m.now += 50; };
    XCTAssertNil([self answerOf:manager]);
    XCTAssertEqual(manager.pastes, 0u); XCTAssertEqual(manager.historyUses.count, 0u);
}
- (void)testServiceShowsNoMenuWhenNotReadyModalBusyOrReentered {
    RCServiceTestManager *manager = [RCServiceTestManager new];
    manager.whileMenuIsOpen = ^(RCServiceTestManager *m, NSMenu *menu) { [m selectClipMenuItem:menu.itemArray[0]]; };
    manager.monitoring = NO;
    XCTAssertNil([self answerOf:manager], @"Still launching, or Clear, Panic, quit");
    manager.monitoring = YES; manager.modal = YES;
    XCTAssertNil([self answerOf:manager], @"A modal alert is in front");
    manager.modal = NO;
    NSMenu *open = [NSMenu new];
    [manager menuWillOpen:open];
    XCTAssertNil([self answerOf:manager], @"A Revclip menu is already tracking");
    [manager menuDidClose:open];
    XCTAssertEqual(manager.presentations, 0u);
    // A second request while the first is waiting is refused; the first still answers.
    __block NSString *inner = @"unset";
    __weak typeof(self) weakSelf = self;
    manager.whileMenuIsOpen = ^(RCServiceTestManager *m, NSMenu *menu) {
        inner = [weakSelf answerOf:m];
        [m selectClipMenuItem:menu.itemArray[0]];
    };
    XCTAssertEqualObjects([self answerOf:manager], @"picked text");
    XCTAssertNil(inner);
    XCTAssertEqual(manager.presentations, 1u);
}
- (void)testOnlyItemsOfTheServiceMenuAreTakenAndAFailedSetUpLeavesNoSessionBehind {
    RCServiceTestManager *manager = [RCServiceTestManager new];
    // A hotkey or status menu opened meanwhile keeps its ordinary meaning.
    NSMenu *other = [NSMenu new];
    NSMenuItem *foreign = [[NSMenuItem alloc] initWithTitle:@"other" action:@selector(selectClipMenuItem:) keyEquivalent:@""];
    foreign.target = manager; foreign.representedObject = @"text-hash"; [other addItem:foreign];
    manager.whileMenuIsOpen = ^(RCServiceTestManager *m, NSMenu *menu) { [m selectClipMenuItem:foreign]; };
    XCTAssertNil([self answerOf:manager]);
    XCTAssertEqual(manager.pastes, 1u, @"Pasted as usual, not taken as the answer");
    // An exception while the menu is built.
    manager.buildThrows = YES;
    XCTAssertThrows([self answerOf:manager]);
    manager.buildThrows = NO;
    XCTAssertFalse([manager captureServiceSelection:manager.fixtureMenu.itemArray[0]], @"No session is left active");
    manager.whileMenuIsOpen = ^(RCServiceTestManager *m, NSMenu *menu) { [m selectClipMenuItem:menu.itemArray[0]]; };
    XCTAssertEqualObjects([self answerOf:manager], @"picked text", @"and the next request works");
}
- (void)testNoOtherMenuOpensWhileAServiceRequestWaits {
    RCServiceTestManager *manager = [RCServiceTestManager new];
    NSMenu *hotKeyMenu = [NSMenu new], *statusStyleMenu = [NSMenu new];
    manager.whileMenuIsOpen = ^(RCServiceTestManager *m, NSMenu *menu) {
        [m popUpTransientMenu:hotKeyMenu];             // history, snippet and folder hotkeys
        [m popUpMenuAtMouseLocation:statusStyleMenu];  // main hotkey
        [m popUpMenuAtMouseLocation:menu];             // the request's own menu is not refused
    };
    [self answerOf:manager];
    XCTAssertEqualObjects(manager.trackedMenus, (@[manager.fixtureMenu]));
    [manager popUpTransientMenu:hotKeyMenu];
    XCTAssertEqualObjects(manager.trackedMenus.lastObject, hotKeyMenu, @"Afterwards the hotkeys open their menus again");
}
- (void)testItemsWithoutTextAreDisabledOnlyInsideAServiceRequest {
    RCServiceTestManager *manager = [RCServiceTestManager new];
    NSMapTable *clipItems = [manager valueForKey:@"clipItemsByMenuItem"];
    RCClipItem *text = [RCClipItem new], *image = [RCClipItem new];
    text.primaryType = NSPasteboardTypeString; image.primaryType = NSPasteboardTypeTIFF;
    [clipItems setObject:text forKey:manager.fixtureMenu.itemArray[0]];
    [clipItems setObject:image forKey:manager.fixtureMenu.itemArray[1]];
    XCTAssertTrue([manager validateMenuItem:manager.fixtureMenu.itemArray[1]], @"Ordinary menus are unchanged");
    NSMenuItem *textTemplate = [[NSMenuItem alloc] initWithTitle:@"t" action:NSSelectorFromString(@"selectSnippetMenuItem:") keyEquivalent:@""];
    NSMenuItem *mediaTemplate = [[NSMenuItem alloc] initWithTitle:@"m" action:NSSelectorFromString(@"selectSnippetMenuItem:") keyEquivalent:@""];
    [manager.fixtureMenu addItem:textTemplate]; [manager.fixtureMenu addItem:mediaTemplate];
    [(NSMapTable *)[manager valueForKey:@"previewImageData"] setObject:[NSData dataWithBytes:"x" length:1] forKey:mediaTemplate];
    NSMutableArray<NSNumber *> *enabled = [NSMutableArray array];
    manager.whileMenuIsOpen = ^(RCServiceTestManager *m, NSMenu *menu) {
        for (NSMenuItem *item in menu.itemArray) [enabled addObject:@([m validateMenuItem:item])];
    };
    [self answerOf:manager];
    XCTAssertEqualObjects(enabled, (@[@YES, @NO, @YES, @NO]), @"A text service cannot return an image or a media template");
    XCTAssertTrue([manager validateMenuItem:mediaTemplate], @"and ordinary menus are unchanged afterwards");
}
- (void)testStyledRowHandsItsItemOverBeforeTrackingEndsAndThenSendsNoAction {
    Class rowClass = NSClassFromString(@"RCStyledMenuRow");
    XCTAssertNotNil(rowClass);
    RCServiceTestManager *manager = [RCServiceTestManager new];
    NSMenuItem *item = manager.fixtureMenu.itemArray[0];
    NSView *row = [[rowClass alloc] initWithFrame:NSMakeRect(0, 0, 200, 28)];
    [row setValue:item forKey:@"item"];
    __block NSUInteger offered = 0;
    [RCMenuStyle setSelectionInterceptor:^BOOL(NSMenuItem *candidate) { offered++; return candidate == item; }];
    @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [row performSelector:NSSelectorFromString(@"activateItem")];
#pragma clang diagnostic pop
    } @finally { [RCMenuStyle setSelectionInterceptor:nil]; }
    [self spinDefaultRunLoop];
    XCTAssertEqual(offered, 1u);
    XCTAssertEqual(manager.pastes, 0u, @"Taken synchronously: the delayed action is never sent");
}
// The shape the system really sends is not confirmed here; this pins only the rule:
// both published readings of 'svit' count, and a login item or plain launch never does.
- (void)testOnlyAnOpenApplicationEventMarkedAsServiceItemSkipsTheLaunchGuidance {
    NSAppleEventDescriptor *(^event)(AEEventID, OSType, BOOL) = ^(AEEventID identifier, OSType property, BOOL keyword) {
        NSAppleEventDescriptor *descriptor = [NSAppleEventDescriptor appleEventWithEventClass:kCoreEventClass eventID:identifier
            targetDescriptor:nil returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
        if (property != 0) [descriptor setParamDescriptor:[NSAppleEventDescriptor descriptorWithEnumCode:property] forKeyword:keyAEPropData];
        if (keyword) [descriptor setParamDescriptor:[NSAppleEventDescriptor descriptorWithBoolean:YES] forKeyword:keyAELaunchedAsServiceItem];
        return descriptor;
    };
    XCTAssertTrue([RCAppDelegate launchEventIndicatesService:event(kAEOpenApplication, keyAELaunchedAsServiceItem, NO)]);
    XCTAssertTrue([RCAppDelegate launchEventIndicatesService:event(kAEOpenApplication, 0, YES)]);
    XCTAssertFalse([RCAppDelegate launchEventIndicatesService:event(kAEOpenApplication, 0, NO)], @"An ordinary launch keeps its guidance");
    XCTAssertFalse([RCAppDelegate launchEventIndicatesService:event(kAEOpenApplication, keyAELaunchedAsLogInItem, NO)], @"So does a login item launch");
    XCTAssertFalse([RCAppDelegate launchEventIndicatesService:event(kAEReopenApplication, keyAELaunchedAsServiceItem, NO)]);
    XCTAssertFalse([RCAppDelegate launchEventIndicatesService:nil]);
}
- (void)testCommandRunsImmediatelyWhenNoMenuIsTracking {
    RCTrackingTestManager *manager=[RCTrackingTestManager new];
    __block NSUInteger runs=0;
    [manager performAfterMenuTrackingEnds:^{runs++;}];
    XCTAssertEqual(runs,1u);
}
- (void)testCommandWaitsForEveryMenuAndRunsOutsideTheCloseCallback {
    RCTrackingTestManager *manager=[RCTrackingTestManager new];
    NSMenu *root=[NSMenu new],*child=[NSMenu new];
    __block NSUInteger first=0,second=0;
    [manager menuWillOpen:root]; [manager menuWillOpen:child];
    [manager performAfterMenuTrackingEnds:^{first++;}];
    // The key equivalent and the global hotkey of one key press are one request.
    [manager performAfterMenuTrackingEnds:^{second++;}];
    XCTAssertEqual(first,0u);
    [manager menuDidClose:child]; [self spinDefaultRunLoop];
    XCTAssertEqual(first,0u,@"A submenu closing does not end the session");
    [manager menuDidClose:root];
    XCTAssertEqual(first,0u,@"Never inside menuDidClose:, where AppKit is still tracking");
    [self spinDefaultRunLoop];
    XCTAssertEqual(first,1u); XCTAssertEqual(second,0u);
}
- (void)testSecondEntryBetweenCloseAndExecutionDoesNotStartTwice {
    RCTrackingTestManager *manager=[RCTrackingTestManager new];
    NSMenu *root=[NSMenu new];
    __block NSUInteger first=0,second=0;
    [manager menuWillOpen:root];
    [manager performAfterMenuTrackingEnds:^{first++;}];
    [manager menuDidClose:root];
    // No menu is tracking any more, but the waiting command has not run yet.
    [manager performAfterMenuTrackingEnds:^{second++;}];
    XCTAssertEqual(second,0u,@"Must coalesce instead of invoking immediately");
    [self spinDefaultRunLoop];
    XCTAssertEqual(first,1u); XCTAssertEqual(second,0u);
    [manager performAfterMenuTrackingEnds:^{second++;}];
    XCTAssertEqual(second,1u,@"The slot is free again once the command ran");
}
- (void)testSlotLeftOccupiedByAMenuThatNeverReportedItsCloseIsRevivedByTheNextRequest {
    RCTrackingTestManager *manager=[RCTrackingTestManager new];
    __block NSUInteger first=0,second=0;
    @autoreleasepool {
        NSMenu *lost=[NSMenu new];
        [manager menuWillOpen:lost];
        [manager performAfterMenuTrackingEnds:^{first++;}];
        // Released without menuDidClose:. The weak table forgets it; nothing was scheduled.
    }
    [self spinDefaultRunLoop];
    XCTAssertEqual(first,0u);
    // The next request is the event that revives it: no timer, and the slot is finite.
    [manager performAfterMenuTrackingEnds:^{second++;}];
    [self spinDefaultRunLoop];
    XCTAssertEqual(first,1u,@"The waiting command runs; the request that revived it was the same wish");
    XCTAssertEqual(second,0u);
    [manager performAfterMenuTrackingEnds:^{second++;}];
    XCTAssertEqual(second,1u,@"and the slot is free again");
}
- (void)testWaitingCommandIsDroppedWhenAnotherSessionOpens {
    RCTrackingTestManager *manager=[RCTrackingTestManager new];
    NSMenu *stale=[NSMenu new],*next=[NSMenu new];
    __block NSUInteger runs=0;
    [manager menuWillOpen:stale];
    [manager performAfterMenuTrackingEnds:^{runs++;}];
    [manager menuDidClose:stale];
    [manager menuWillOpen:next];
    [self spinDefaultRunLoop];
    [manager menuDidClose:next]; [self spinDefaultRunLoop];
    XCTAssertEqual(runs,0u);
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
