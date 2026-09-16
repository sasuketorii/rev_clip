#import <XCTest/XCTest.h>
#import "RCMenuManager.h"
#import "RCClipboardService.h"
#import "RCClipItem.h"

@interface RCMenuManager (FreshnessDiagnostics)
- (void)handleClipboardDidChange:(NSNotification *)notification;
- (void)menuWillOpen:(NSMenu *)menu;
- (void)menuDidClose:(NSMenu *)menu;
@end

// Only rendering and external boundaries are replaced. The real notification,
// rebuildMenu/setupStatusItem guards, tracking set, and close callback execute.
// committedRows represents rows already saved, NOT a measurement of capture or
// database latency. No pop-up, selection, pasteboard, archive or database access.
@interface RCFreshnessDiagnosticManager : RCMenuManager
@property(nonatomic, strong) NSMenu *fixtureMenu;
@property(nonatomic, copy) NSArray<NSDictionary *> *committedRows;
@property(nonatomic) NSUInteger renderCount;
@end
@implementation RCFreshnessDiagnosticManager
- (NSDictionary *)menuPreferenceSnapshot { return @{}; }
- (void)applyStatusItemPreference {} // never creates a status item
- (void)capturePasteTargetApplication {} // never consults workspace/frontmost app
- (void)configureMenuForSimpleTransparentBackground:(NSMenu *)menu {}
- (void)loadFaviconForMenuItem:(NSMenuItem *)item {} // never requests network assets
- (void)rebuildMenuInternal {
    self.renderCount++;
    [self.fixtureMenu removeAllItems];
    for (NSDictionary *row in self.committedRows) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:row[@"title"] action:NULL keyEquivalent:@""];
        item.representedObject = row[@"data_hash"];
        [self.fixtureMenu addItem:item];
    }
}
@end

@interface RCMenuFreshnessTests : XCTestCase
@property(nonatomic, strong) RCFreshnessDiagnosticManager *manager;
@property(nonatomic, strong) NSMenu *menu;
@end
@implementation RCMenuFreshnessTests
- (void)onMain:(dispatch_block_t)block {
    if (NSThread.isMainThread) block(); else dispatch_sync(dispatch_get_main_queue(), block);
}
- (NSDictionary *)row:(NSString *)name {
    return @{@"title":[@"synthetic-" stringByAppendingString:name], @"data_hash":name,
             @"primary_type":NSPasteboardTypeString, @"update_time":@1};
}
- (void)setUp {
    [super setUp];
    [self onMain:^{
        self.manager = [RCFreshnessDiagnosticManager new];
        // Dispatch directly to the real handler below without notifying other
        // managers in the test host or receiving unrelated defaults events.
        [NSNotificationCenter.defaultCenter removeObserver:self.manager];
        self.menu = [NSMenu new];
        self.manager.fixtureMenu = self.menu;
        self.manager.committedRows = @[[self row:@"A"]];
        [self.manager rebuildMenu];
        XCTAssertEqual(self.manager.renderCount, 1u);
    }];
}
- (void)settleOneMainQueueTurn {
    XCTestExpectation *done = [self expectationWithDescription:@"main queue turn"];
    dispatch_async(dispatch_get_main_queue(), ^{ [done fulfill]; });
    [self waitForExpectations:@[done] timeout:2];
}
- (void)deliverSavedRow:(NSString *)name {
    XCTAssertTrue(NSThread.isMainThread);
    NSDictionary *row = [self row:name];
    self.manager.committedRows = [@[row] arrayByAddingObjectsFromArray:self.manager.committedRows];
    RCClipItem *clip = [[RCClipItem alloc] initWithDictionary:row];
    NSNotification *saved = [NSNotification notificationWithName:RCClipboardDidChangeNotification
        object:nil userInfo:@{@"clipItem":clip}];
    [self.manager handleClipboardDidChange:saved];
}
- (void)tearDown {
    [self onMain:^{
        // Close any remaining synthetic tracked menus even after an assertion
        // failure. No real NSMenu tracking session was ever entered.
        NSHashTable *tracking = [self.manager valueForKey:@"trackingMenus"];
        for (NSMenu *menu in tracking.allObjects) [self.manager menuDidClose:menu];
    }];
    [self settleOneMainQueueTurn];
    [self onMain:^{ self.manager = nil; self.menu = nil; }];
    [super tearDown];
}
// Characterization, intentionally asserts CURRENT stale-while-open behavior.
// A future freshness fix must update these expectations rather than treating
// this passing diagnostic as acceptance of an arbitrarily stale open menu.
- (void)testSavedHistoryRemainsInvisibleAcrossQueueTurnsUntilMenuCloses {
    __block NSMenuItem *original;
    [self onMain:^{
        original = self.menu.itemArray.firstObject;
        [self.manager menuWillOpen:self.menu];
        [self deliverSavedRow:@"B"];
        XCTAssertTrue([[self.manager valueForKey:@"pendingMenuRebuild"] boolValue]);
        XCTAssertEqualObjects(self.manager.committedRows.firstObject[@"data_hash"], @"B");
    }];
    // Multiple notifications and queue turns cannot release a guard whose only
    // release condition is closing the last tracked menu; no sleeps are needed.
    for (NSString *name in @[@"C", @"D", @"E"]) {
        [self settleOneMainQueueTurn];
        [self onMain:^{
            [self deliverSavedRow:name];
            XCTAssertEqual(self.manager.renderCount, 1u);
            XCTAssertEqual(self.menu.numberOfItems, 1);
            XCTAssertEqual(self.menu.itemArray.firstObject, original);
            XCTAssertEqualObjects(original.title, @"synthetic-A");
            XCTAssertEqualObjects(original.representedObject, @"A", @"Selection identity remains stable");
            XCTAssertTrue([[self.manager valueForKey:@"pendingMenuRebuild"] boolValue]);
        }];
    }
    [self onMain:^{ [self.manager menuDidClose:self.menu]; }];
    [self settleOneMainQueueTurn];
    [self onMain:^{
        XCTAssertEqual(self.manager.renderCount, 2u);
        XCTAssertEqual(self.menu.numberOfItems, 5);
        XCTAssertEqualObjects(self.menu.itemArray.firstObject.representedObject, @"E");
        XCTAssertFalse([[self.manager valueForKey:@"pendingMenuRebuild"] boolValue]);
    }];
}
- (void)testSavedHistoryRefreshesWithoutDelayWhenNoMenuIsTracking {
    [self onMain:^{
        [self deliverSavedRow:@"B"];
        XCTAssertEqual(self.manager.renderCount, 2u);
        XCTAssertEqualObjects(self.menu.itemArray.firstObject.representedObject, @"B");
        XCTAssertFalse([[self.manager valueForKey:@"pendingMenuRebuild"] boolValue]);
    }];
}
- (void)testClosingChildAloneLeavesParentStaleUntilLastTrackedMenuCloses {
    __block NSMenu *child;
    [self onMain:^{
        child = [NSMenu new];
        NSMenuItem *folder = [[NSMenuItem alloc] initWithTitle:@"synthetic-folder" action:NULL keyEquivalent:@""];
        folder.submenu = child; [self.menu addItem:folder];
        [self.manager menuWillOpen:self.menu];
        [self.manager menuWillOpen:child];
        [self deliverSavedRow:@"B"];
        [self.manager menuDidClose:child];
    }];
    [self settleOneMainQueueTurn];
    [self onMain:^{
        XCTAssertEqual(self.manager.renderCount, 1u);
        XCTAssertEqualObjects(self.menu.itemArray.firstObject.representedObject, @"A");
        XCTAssertTrue([[self.manager valueForKey:@"pendingMenuRebuild"] boolValue]);
        [self.manager menuDidClose:self.menu];
    }];
    [self settleOneMainQueueTurn];
    [self onMain:^{
        XCTAssertEqual(self.manager.renderCount, 2u);
        XCTAssertEqualObjects(self.menu.itemArray.firstObject.representedObject, @"B");
    }];
}
@end
