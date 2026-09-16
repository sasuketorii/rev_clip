//
//  RCMenuOpenPreflightTests.m
//  RevclipTests
//
//  Copy immediately followed by opening the history menu from a hotkey. The
//  polling timer never runs in this fixture, so a generation written to the
//  isolated named pasteboard is observed only if the open path itself
//  synchronizes with acquisition and persistence before presenting.
//
//  Real acquisition, encryption, archive, private database, notification guard
//  and open/close callbacks execute. Only the pop-up (AppKit tracking session),
//  status item, workspace front-app lookup, favicon network and cleanup timers
//  are replaced. Never touches the general pasteboard, user history or Keychain.
//

#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import "RCMenuManager.h"
#import "RCClipboardService.h"
#import "RCDatabaseManager.h"
#import "RCDataCleanService.h"
#import "RCClipData.h"
#import "RCClipItem.h"
#import "RCConstants.h"
#import "RCUtilities.h"

@interface RCMenuManager (OpenPreflightTesting)
- (void)popUpHistoryMenuFromHotKey;
- (void)popUpStatusMenuFromHotKey;
- (void)handleClipboardDidChange:(NSNotification *)notification;
- (void)menuWillOpen:(NSMenu *)menu;
- (void)menuDidClose:(NSMenu *)menu;
- (void)popUpMenuAtMouseLocation:(NSMenu *)menu;
- (void)populateStatusMenuContents;
- (BOOL)statusMenuHasHighlightedItem;
- (NSTimeInterval)secondsSinceLastUserInput;
- (void)configureClipMenuItem:(NSMenuItem *)item clipItem:(RCClipItem *)clipItem loadThumbnail:(BOOL)loadThumbnail;
@end
@interface RCDatabaseManager (OpenPreflightTesting)
- (instancetype)initPrivate;
@end
@interface RCClipboardService (OpenPreflightTesting)
- (void)pollPasteboardOnMonitoringQueue;
- (RCClipData *)readEligibleClipFromPasteboard:(NSPasteboard *)board sourceBundleIdentifier:(NSString *)source;
- (void)postClipboardDidChangeNotificationWithClipItem:(RCClipItem *)clipItem;
@end

@interface RCOpenPreflightCleanup : NSObject
@end
@implementation RCOpenPreflightCleanup
- (void)scheduleDebouncedCleanup {} // no cleanup timers in this fixture
@end

@interface RCOpenPreflightClipboard : RCClipboardService
@property(weak) RCMenuManager *menu;
@property(strong) NSMutableArray<NSString *> *observed;
@property(strong) NSMutableArray<RCClipItem *> *saved;
// When set, preflight completions are handed to the test instead of running,
// so lifecycle changes can be interleaved deterministically before each one.
@property BOOL holdCompletions;
@property(strong) NSMutableArray<dispatch_block_t> *heldCompletions;
@end
@implementation RCOpenPreflightClipboard
- (void)observePendingClipboardChangeWithCompletion:(void (^)(void))completion {
    if (!self.holdCompletions) { [super observePendingClipboardChangeWithCompletion:completion]; return; }
    [self.heldCompletions addObject:[completion copy]];
}
- (BOOL)canReadPasteboardContentsUsingPrivacyGate { return YES; }
- (BOOL)sourceIsExcluded:(NSString *)source { return NO; }
- (RCClipData *)readEligibleClipFromPasteboard:(NSPasteboard *)board sourceBundleIdentifier:(NSString *)source {
    RCClipData *clip = [super readEligibleClipFromPasteboard:board sourceBundleIdentifier:source];
    if (clip.stringValue) [self.observed addObject:clip.stringValue]; // acquisition runs on main
    return clip;
}
- (void)postClipboardDidChangeNotificationWithClipItem:(RCClipItem *)clipItem {
    if (clipItem == nil) return;
    // Same asynchronous main-queue delivery as the product, addressed to this
    // fixture's manager only; no global notification reaches other managers.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (self == nil) return;
        [self.saved addObject:clipItem];
        [self.menu handleClipboardDidChange:[NSNotification notificationWithName:RCClipboardDidChangeNotification
                                                                            object:self
                                                                          userInfo:@{@"clipItem": clipItem}]];
    });
}
@end

@interface RCOpenPreflightTarget : NSObject
@property(getter=isTerminated) BOOL terminated;
@property pid_t processIdentifier;
@end
@implementation RCOpenPreflightTarget
@end

// Stands in for NSStatusItem: only the menu wiring the manager touches.
@interface RCOpenPreflightStatusItem : NSObject
@property(strong) NSMenu *menu;
@property(strong) id button;
@property NSUInteger menuAssignments; // every native (re)attachment
@end
@implementation RCOpenPreflightStatusItem
- (void)setMenu:(NSMenu *)menu { _menu = menu; self.menuAssignments++; }
@end

@interface RCOpenPreflightMenu : RCMenuManager
@property(strong) NSMutableArray<NSMenu *> *presented;
@property(strong) NSMutableArray<NSNumber *> *presentedAt;
@property(strong) RCOpenPreflightTarget *front; // synthetic frontmost application
@property BOOL mainQueueServicedWhilePresenting;
@property BOOL highlighted; // stands in for NSMenu.highlightedItem, which tests cannot set
@property NSTimeInterval inputAge; // stands in for the session-wide key/mouse-down age
@property NSUInteger populateCount;
@property NSUInteger onOpenThumbnailLoads; // rows given the load-on-open treatment
@property(strong) NSMutableArray<NSNumber *> *populatedAt;
@end
@implementation RCOpenPreflightMenu
- (NSDictionary *)menuPreferenceSnapshot { return @{}; }
- (void)applyStatusItemPreference {} // never creates a real status item (tests install a stand-in)
- (BOOL)statusMenuHasHighlightedItem { return self.highlighted; }
- (NSTimeInterval)secondsSinceLastUserInput { return self.inputAge; }
- (void)populateStatusMenuContents {
    self.populateCount++;
    [self.populatedAt addObject:@(CFAbsoluteTimeGetCurrent())];
    [super populateStatusMenuContents];
}
- (void)configureClipMenuItem:(NSMenuItem *)item clipItem:(RCClipItem *)clipItem loadThumbnail:(BOOL)loadThumbnail {
    if (loadThumbnail) self.onOpenThumbnailLoads++;
    [super configureClipMenuItem:item clipItem:clipItem loadThumbnail:loadThumbnail];
}
- (NSRunningApplication *)frontmostApplication { return (id)self.front; } // never consults the workspace
- (void)capturePasteTargetApplication {}
- (void)configureMenuForSimpleTransparentBackground:(NSMenu *)menu {}
- (void)loadFaviconForMenuItem:(NSMenuItem *)item {} // never requests network assets
- (NSInteger)integerPreferenceForKey:(NSString *)key defaultValue:(NSInteger)value {
    // Rows inline rather than inside "Items 1-10" folders, so the first row is the newest clip.
    return [key isEqual:kRCPrefNumberOfItemsPlaceInlineKey] ? 30 : value;
}
- (void)popUpMenuAtMouseLocation:(NSMenu *)menu {
    XCTAssertTrue(NSThread.isMainThread);
    [self.presentedAt addObject:@(CFAbsoluteTimeGetCurrent())];
    [self.presented addObject:menu];
    // Mirror the real pop-up: the delegate is told the menu opened, then AppKit
    // runs a nested tracking loop. That loop must keep servicing main-queue
    // work (hover previews, favicons), which a nested loop entered from inside
    // a main-queue block cannot do. The menu stays open until the test closes it.
    [self menuWillOpen:menu];
    __block BOOL serviced = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ serviced = YES; });
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 0.5;
    while (!serviced && NSProcessInfo.processInfo.systemUptime < deadline) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
    }
    self.mainQueueServicedWhilePresenting = serviced;
}
@end

// Test-local shared accessors let the product menu resolve the same isolated
// services. Every IMP is restored after draining. The storage test constructor
// supplies the unique named pasteboard, in-memory defaults and RAM cipher key.
@interface RCMenuOpenPreflightTests : XCTestCase {
    Method _dbMethod, _captureMethod, _cleanupMethod;
    IMP _dbOriginal, _captureOriginal, _cleanupOriginal;
    IMP _dbReplacement, _captureReplacement, _cleanupReplacement;
}
@property(strong) RCDatabaseManager *db;
@property(strong) RCOpenPreflightClipboard *capture;
@property(strong) RCOpenPreflightMenu *menu;
@property(copy) NSString *directory;
@end

@implementation RCMenuOpenPreflightTests
- (void)onMain:(dispatch_block_t)block {
    if (NSThread.isMainThread) block(); else dispatch_sync(dispatch_get_main_queue(), block);
}
- (void)setUp {
    [super setUp];
    // Fail closed before any pasteboard/database/archive operation without test isolation.
    if (![[RCUtilities applicationSupportPath] containsString:@"RevclipTests-storage-"] ||
        [NSPasteboard.generalPasteboard.name isEqual:NSPasteboardNameGeneral])
        @throw [NSException exceptionWithName:@"UnsafeOpenPreflightTestHost" reason:@"Storage test constructor is required" userInfo:nil];
    self.directory = [[RCUtilities applicationSupportPath] stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtPath:self.directory withIntermediateDirectories:YES
                                                         attributes:@{NSFilePosixPermissions:@0700} error:nil]);
    self.db = [[RCDatabaseManager alloc] initPrivate];
    [self.db setValue:[self.directory stringByAppendingPathComponent:@"synthetic.db"] forKey:@"databasePath"];
    XCTAssertTrue([self.db setupDatabase]);
    [self onMain:^{
        self.capture = [RCOpenPreflightClipboard new];
        self.capture.observed = [NSMutableArray array];
        self.capture.saved = [NSMutableArray array];
        self.capture.heldCompletions = [NSMutableArray array];
        // Monitoring state only; the polling timer is never started here.
        [self.capture setValue:@YES forKey:@"isMonitoring"];
        self->_dbMethod = class_getClassMethod(RCDatabaseManager.class, @selector(shared));
        self->_captureMethod = class_getClassMethod(RCClipboardService.class, @selector(shared));
        self->_cleanupMethod = class_getClassMethod(RCDataCleanService.class, @selector(shared));
        RCDatabaseManager *db = self.db; RCClipboardService *capture = self.capture;
        RCOpenPreflightCleanup *cleanup = [RCOpenPreflightCleanup new];
        self->_dbReplacement = imp_implementationWithBlock(^id(id object) { return db; });
        self->_captureReplacement = imp_implementationWithBlock(^id(id object) { return capture; });
        self->_cleanupReplacement = imp_implementationWithBlock(^id(id object) { return cleanup; });
        self->_dbOriginal = method_setImplementation(self->_dbMethod, self->_dbReplacement);
        self->_captureOriginal = method_setImplementation(self->_captureMethod, self->_captureReplacement);
        self->_cleanupOriginal = method_setImplementation(self->_cleanupMethod, self->_cleanupReplacement);
        self.menu = [RCOpenPreflightMenu new];
        [NSNotificationCenter.defaultCenter removeObserver:self.menu];
        self.menu.presented = [NSMutableArray array];
        self.menu.presentedAt = [NSMutableArray array];
        self.menu.front = [RCOpenPreflightTarget new];
        self.menu.front.processIdentifier = 1234567;
        self.menu.populatedAt = [NSMutableArray array];
        self.menu.inputAge = 3600; // no key or click since the request unless a test says so
        self.capture.menu = self.menu;
    }];
}
- (void)drain {
    XCTestExpectation *done = [self expectationWithDescription:@"acquisition and persistence drained"];
    [self.capture flushQueueWithCompletion:^{ dispatch_async(dispatch_get_main_queue(), ^{ [done fulfill]; }); }];
    [self waitForExpectations:@[done] timeout:3];
}
- (void)settleMainQueueTurns:(NSUInteger)turns {
    for (NSUInteger turn = 0; turn < turns; turn++) {
        XCTestExpectation *done = [self expectationWithDescription:@"main queue turn"];
        dispatch_async(dispatch_get_main_queue(), ^{ [done fulfill]; });
        [self waitForExpectations:@[done] timeout:2];
    }
}
- (void)tearDown {
    if (self.capture) { [self.capture stopMonitoring]; [self drain]; }
    [self onMain:^{
        NSHashTable *tracking = [self.menu valueForKey:@"trackingMenus"];
        for (NSMenu *menu in tracking.allObjects) [self.menu menuDidClose:menu];
    }];
    [self settleMainQueueTurns:2];
    [self onMain:^{
        self.menu = nil;
        if (self->_cleanupOriginal) method_setImplementation(self->_cleanupMethod, self->_cleanupOriginal);
        if (self->_captureOriginal) method_setImplementation(self->_captureMethod, self->_captureOriginal);
        if (self->_dbOriginal) method_setImplementation(self->_dbMethod, self->_dbOriginal);
        if (self->_cleanupReplacement) imp_removeBlock(self->_cleanupReplacement);
        if (self->_captureReplacement) imp_removeBlock(self->_captureReplacement);
        if (self->_dbReplacement) imp_removeBlock(self->_dbReplacement);
        self.capture = nil;
    }];
    // Remove only this fixture's synthetic archives inside the isolated root.
    NSString *clips = [RCUtilities clipDataDirectoryPath];
    for (NSDictionary *row in [self.db fetchClipItemsWithLimit:1000]) {
        NSString *path = row[@"data_path"];
        if ([path hasPrefix:clips]) [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    }
    [self.db deleteAllClipItems];
    [self.db closeDatabase];
    self.db = nil;
    [NSFileManager.defaultManager removeItemAtPath:self.directory error:nil];
    [super tearDown];
}
// The test-bundle constructor redirects this accessor to a unique named board.
- (NSString *)write:(NSString *)text {
    NSPasteboard *board = NSPasteboard.generalPasteboard;
    XCTAssertNotEqualObjects(board.name, NSPasteboardNameGeneral);
    [board clearContents];
    XCTAssertTrue([board setString:text forType:NSPasteboardTypeString]);
    return [[RCClipData clipDataFromPasteboard:board] dataHash];
}
- (void)waitUntilPresented:(NSUInteger)count timeout:(NSTimeInterval)timeout {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
    while (self.menu.presented.count < count && NSProcessInfo.processInfo.systemUptime < deadline) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
    }
}
- (NSNumber *)updateTimeForHash:(NSString *)hash {
    return [self.db clipItemWithDataHash:hash][@"update_time"];
}
- (BOOL)pendingRebuild { return [[self.menu valueForKey:@"pendingMenuRebuild"] boolValue]; }

// Copy → hotkey before the next poll. The newest clip must already be the first
// row when the menu opens, and the open menu keeps its rows while later copies persist.
- (void)testHistoryHotKeyPresentsCopyMadeBeforeNextPollAndKeepsRowsWhileOpen {
    NSString *text = [@"synthetic-open-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSString *hash = [self write:text];
    XCTAssertEqual([self.db clipItemCount], 0);
    CFAbsoluteTime requested = CFAbsoluteTimeGetCurrent();
    [self.menu popUpHistoryMenuFromHotKey];
    [self waitUntilPresented:1 timeout:3];
    XCTAssertEqual(self.menu.presented.count, 1u);
    NSMenu *shown = self.menu.presented.firstObject;
    NSMenuItem *first = shown.itemArray.firstObject;
    NSLog(@"RC_MENU_METRIC path=history hotkey_to_popup_ms=%.3f first_row_fresh=%d rows=%lu",
          (self.menu.presentedAt.firstObject.doubleValue - requested) * 1000,
          [first.representedObject isEqual:hash], (unsigned long)shown.numberOfItems);
    XCTAssertEqualObjects(first.representedObject, hash,
                          @"The copy made before the next poll must be the first row when the menu opens");
    XCTAssertEqualObjects(self.capture.observed, @[text]);
    XCTAssertNotNil([self.db clipItemWithDataHash:hash], @"Presented row must be persisted, not RAM-only");
    XCTAssertTrue(self.menu.mainQueueServicedWhilePresenting,
                  @"Pop-up must not run inside a main-queue block: its tracking loop must keep servicing main-queue work");

    // A later copy persists while the menu is open without moving or replacing rows.
    NSString *second = [@"synthetic-second-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSString *secondHash = [self write:second];
    dispatch_queue_t monitoring = [self.capture valueForKey:@"monitoringQueue"];
    dispatch_async(monitoring, ^{ [self.capture pollPasteboardOnMonitoringQueue]; });
    [self drain];
    [self settleMainQueueTurns:2];
    XCTAssertNotNil([self.db clipItemWithDataHash:secondHash]);
    XCTAssertEqual(self.capture.saved.count, 2u);
    XCTAssertEqual(shown.itemArray.firstObject, first, @"Row identity is stable while tracking");
    XCTAssertEqualObjects(first.representedObject, hash);
    XCTAssertTrue([self pendingRebuild]);
    [self.menu menuDidClose:shown];
    [self settleMainQueueTurns:2];
    XCTAssertFalse([self pendingRebuild]);
    XCTAssertEqual(self.menu.presented.count, 1u, @"Closing never re-presents a transient menu");
}

- (void)testStatusHotKeyPresentsCopyMadeBeforeNextPoll {
    NSString *text = [@"synthetic-status-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSString *hash = [self write:text];
    CFAbsoluteTime requested = CFAbsoluteTimeGetCurrent();
    [self.menu popUpStatusMenuFromHotKey]; // no status item here: the standalone menu path
    [self waitUntilPresented:1 timeout:3];
    XCTAssertEqual(self.menu.presented.count, 1u);
    NSMenuItem *first = self.menu.presented.firstObject.itemArray.firstObject;
    NSLog(@"RC_MENU_METRIC path=status hotkey_to_popup_ms=%.3f first_row_fresh=%d",
          (self.menu.presentedAt.firstObject.doubleValue - requested) * 1000, [first.representedObject isEqual:hash]);
    XCTAssertEqualObjects(first.representedObject, hash);
    XCTAssertTrue(self.menu.mainQueueServicedWhilePresenting);
}

// Two presses before the first presentation open one menu, built after both.
- (void)testRepeatedHotKeyBeforePresentationPresentsOnce {
    NSString *hash = [self write:[@"synthetic-repeat-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [self.menu popUpHistoryMenuFromHotKey];
    [self.menu popUpHistoryMenuFromHotKey];
    [self waitUntilPresented:1 timeout:3];
    [self drain];
    [self settleMainQueueTurns:3];
    XCTAssertEqual(self.menu.presented.count, 1u, @"A superseded request must not stack a second pop-up");
    XCTAssertEqualObjects(self.menu.presented.firstObject.itemArray.firstObject.representedObject, hash);
    XCTAssertEqual(self.capture.saved.count, 1u, @"The generation is captured once, never re-captured");
}

// A hotkey while a menu already tracks neither stacks a pop-up nor loses the copy.
- (void)testHotKeyWhileAnotherMenuTracksDoesNotStackPopUps {
    NSMenu *open = [NSMenu new];
    [self.menu menuWillOpen:open];
    NSString *hash = [self write:[@"synthetic-tracking-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [self.menu popUpHistoryMenuFromHotKey];
    [self drain];
    [self settleMainQueueTurns:3];
    XCTAssertEqual(self.menu.presented.count, 0u);
    XCTAssertNotNil([self.db clipItemWithDataHash:hash], @"The copy is still captured and persisted");
    XCTAssertTrue([self pendingRebuild]);
    [self.menu menuDidClose:open];
    [self settleMainQueueTurns:3];
    XCTAssertEqual(self.menu.presented.count, 0u, @"The dropped request is not replayed after close");
    XCTAssertFalse([self pendingRebuild]);
}

// The application in front at the hotkey is the paste target. Switching away
// (or that application quitting) before the preflight completes drops the
// presentation; a late menu must never paste into the newly focused application.
- (void)testSwitchingApplicationDuringPreflightDropsPresentation {
    NSString *hash = [self write:[@"synthetic-switch-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [self.menu popUpHistoryMenuFromHotKey];
    self.menu.front = [RCOpenPreflightTarget new];
    self.menu.front.processIdentifier = 7654321;
    [self drain];
    [self settleMainQueueTurns:3];
    XCTAssertEqual(self.menu.presented.count, 0u, @"No menu for a target the user left");
    XCTAssertNotNil([self.db clipItemWithDataHash:hash], @"The copy is still captured and persisted");

    [self.menu popUpHistoryMenuFromHotKey];
    self.menu.front.terminated = YES;
    [self drain];
    [self settleMainQueueTurns:3];
    XCTAssertEqual(self.menu.presented.count, 0u, @"No menu for a target that quit");

    self.menu.front = [RCOpenPreflightTarget new];
    self.menu.front.processIdentifier = 1234567;
    [self.menu popUpHistoryMenuFromHotKey];
    [self waitUntilPresented:1 timeout:3];
    XCTAssertEqual(self.menu.presented.count, 1u, @"An unchanged target presents");
    XCTAssertEqualObjects(self.menu.presented.firstObject.itemArray.firstObject.representedObject, hash);
}

// Monitoring stops only for quit drain, clear history and panic erase. A
// request from before such a stop must never present, even without a hang.
- (void)testHotKeyDoesNotPresentAfterMonitoringStopped {
    [self write:[@"synthetic-stopped-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    self.capture.holdCompletions = YES;
    [self.menu popUpHistoryMenuFromHotKey];
    XCTAssertEqual(self.capture.heldCompletions.count, 1u);
    [self.capture stopMonitoring];
    self.capture.heldCompletions.firstObject();
    [self settleMainQueueTurns:3];
    XCTAssertEqual(self.menu.presented.count, 0u, @"A stop between request and completion invalidates the request");
}

// stop + restart before the completion (the ABA case) must invalidate as well.
- (void)testHotKeyDoesNotPresentAfterMonitoringStopAndRestart {
    self.capture.holdCompletions = YES;
    [self.menu popUpHistoryMenuFromHotKey];
    NSUInteger before = self.capture.monitoringGeneration;
    [self.capture stopMonitoring];
    [self.capture startMonitoring];
    XCTAssertTrue(self.capture.isMonitoring);
    XCTAssertNotEqual(self.capture.monitoringGeneration, before);
    self.capture.heldCompletions.firstObject();
    [self settleMainQueueTurns:3];
    XCTAssertEqual(self.menu.presented.count, 0u, @"isMonitoring alone would pass; the generation must not");
    [self.capture stopMonitoring];
}

// Escape, typing or a click while a slow save keeps the preflight pending: the
// user moved on, so the late menu must not appear (the capture is kept).
- (void)testHotKeyIsCancelledByKeyOrClickWhileSavePending {
    NSString *hash = [self write:[@"synthetic-esc-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    self.capture.holdCompletions = YES;
    [self.menu popUpHistoryMenuFromHotKey];
    [self persistPendingGeneration];   // slow save finishes only now
    self.menu.inputAge = 0;            // a key-down/mouse-down arrived after the request
    [self deliverHeldCompletion];
    XCTAssertEqual(self.menu.presented.count, 0u, @"No late menu after Escape/click-away");
    XCTAssertNotNil([self.db clipItemWithDataHash:hash], @"The copy is still persisted");

    self.menu.inputAge = 3600;         // nothing pressed since the request
    [self.menu popUpHistoryMenuFromHotKey];
    [self deliverHeldCompletion];
    XCTAssertEqual(self.menu.presented.count, 1u, @"Without later input the same request presents");
    XCTAssertEqualObjects(self.menu.presented.firstObject.itemArray.firstObject.representedObject, hash);
}

#pragma mark - Native status-bar click (AppKit opens statusItem.menu, then sends menuWillOpen:)

- (NSMenu *)statusMenu { return [self.menu valueForKey:@"statusMenu"]; }
- (void)installStatusItemStandIn {
    RCOpenPreflightStatusItem *item = [RCOpenPreflightStatusItem new];
    [self.menu setValue:item forKey:@"statusItem"];
}
// Seed one persisted row and build the status menu the way launch/notification does.
- (NSString *)seedStatusMenuWithRow:(NSString *)text {
    NSString *hash = [self write:text];
    [self.capture pollPasteboardOnMonitoringQueue];
    [self drain];
    [self settleMainQueueTurns:2];
    [self.menu rebuildMenu];
    XCTAssertEqualObjects(self.statusMenu.itemArray.firstObject.representedObject, hash);
    return hash;
}
// AppKit's native click: the menu is already visible when menuWillOpen: arrives.
- (void)clickStatusItem {
    XCTAssertEqual([self.menu valueForKey:@"statusItem"] != nil, YES);
    [self.menu menuWillOpen:self.statusMenu];
}
- (void)deliverHeldCompletion {
    XCTAssertGreaterThan(self.capture.heldCompletions.count, 0u);
    dispatch_block_t completion = self.capture.heldCompletions.firstObject;
    [self.capture.heldCompletions removeObjectAtIndex:0];
    completion();
    [self settleMainQueueTurns:3];
}
// Bring the held generation through the real acquisition/persistence path so
// the save notification lands (pendingMenuRebuild) before the completion runs.
- (void)persistPendingGeneration {
    dispatch_queue_t monitoring = [self.capture valueForKey:@"monitoringQueue"];
    dispatch_async(monitoring, ^{ [self.capture pollPasteboardOnMonitoringQueue]; });
    [self drain];
    [self settleMainQueueTurns:2];
}

// Copy → click the status icon before the next poll. The natively opened menu
// refreshes in place once the copy is persisted, because nothing is highlighted.
- (void)testStatusItemClickRefreshesOpenMenuInPlaceWhenNothingIsHighlighted {
    [self installStatusItemStandIn];
    NSString *hashA = [self seedStatusMenuWithRow:[@"synthetic-click-A-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSUInteger populatedBefore = self.menu.populateCount;
    NSString *hashB = [self write:[@"synthetic-click-B-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    CFAbsoluteTime clicked = CFAbsoluteTimeGetCurrent();
    [self clickStatusItem];
    XCTAssertEqualObjects(self.statusMenu.itemArray.firstObject.representedObject, hashA, @"Native open shows the list as built");
    NSUInteger assignmentsBefore = ((RCOpenPreflightStatusItem *)[self.menu valueForKey:@"statusItem"]).menuAssignments;
    NSUInteger thumbnailLoadsBefore = self.menu.onOpenThumbnailLoads;
    [self drain];
    [self settleMainQueueTurns:3];
    XCTAssertEqual(self.menu.populateCount, populatedBefore + 1, @"Exactly one in-place refresh");
    NSLog(@"RC_MENU_METRIC path=status_click open_to_inplace_refresh_ms=%.3f",
          (self.menu.populatedAt.lastObject.doubleValue - clicked) * 1000);
    XCTAssertEqualObjects(self.statusMenu.itemArray.firstObject.representedObject, hashB);
    XCTAssertEqualObjects(self.statusMenu.itemArray[1].representedObject, hashA);
    XCTAssertFalse([self pendingRebuild]);
    NSHashTable *tracking = [self.menu valueForKey:@"trackingMenus"];
    XCTAssertTrue([tracking containsObject:self.statusMenu], @"Same session stays open; nothing is cancelled or reopened");
    RCOpenPreflightStatusItem *item = [self.menu valueForKey:@"statusItem"];
    XCTAssertEqual(item.menu, self.statusMenu, @"Native menu wiring untouched");
    XCTAssertEqual(item.menuAssignments, assignmentsBefore, @"The tracking native menu is never reattached");
    XCTAssertEqual(self.menu.onOpenThumbnailLoads, thumbnailLoadsBefore + 2,
                   @"Both refreshed visible rows get the same load-on-open treatment as menuWillOpen");
    XCTAssertEqual(self.menu.presented.count, 0u, @"The click path never pops a menu itself");
    [self.menu menuDidClose:self.statusMenu];
    [self settleMainQueueTurns:2];
    XCTAssertEqual(self.menu.populateCount, populatedBefore + 1, @"Nothing left pending at close");
}

// A highlighted row (mouse or keyboard) keeps the session exactly as drawn.
- (void)testStatusItemClickKeepsHighlightedSessionUntilReopen {
    [self installStatusItemStandIn];
    NSString *hashA = [self seedStatusMenuWithRow:[@"synthetic-hl-A-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSMenuItem *rowA = self.statusMenu.itemArray.firstObject;
    NSUInteger populatedBefore = self.menu.populateCount;
    NSString *hashB = [self write:[@"synthetic-hl-B-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [self clickStatusItem];
    self.menu.highlighted = YES;
    [self drain];
    [self settleMainQueueTurns:3];
    XCTAssertNotNil([self.db clipItemWithDataHash:hashB], @"Persisted, but not shown into an active selection");
    XCTAssertEqual(self.menu.populateCount, populatedBefore);
    XCTAssertEqual(self.statusMenu.itemArray.firstObject, rowA);
    XCTAssertEqualObjects(rowA.representedObject, hashA);
    XCTAssertTrue([self pendingRebuild], @"Deferred to close, as before");
    [self.menu menuDidClose:self.statusMenu];
    [self settleMainQueueTurns:2];
    XCTAssertEqual(self.menu.populateCount, populatedBefore + 1);
    XCTAssertEqualObjects(self.statusMenu.itemArray.firstObject.representedObject, hashB);
}

// A tracking submenu (folder) also defers; closing only the child does not refresh.
- (void)testStatusItemClickDefersWhileSubmenuTracks {
    [self installStatusItemStandIn];
    NSString *hashA = [self seedStatusMenuWithRow:[@"synthetic-sub-A-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSUInteger populatedBefore = self.menu.populateCount;
    self.capture.holdCompletions = YES;
    NSString *hashB = [self write:[@"synthetic-sub-B-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [self clickStatusItem];
    NSMenu *child = [NSMenu new];
    [self.menu menuWillOpen:child];
    [self persistPendingGeneration];
    XCTAssertTrue([self pendingRebuild]);
    [self deliverHeldCompletion];
    XCTAssertEqual(self.menu.populateCount, populatedBefore);
    XCTAssertEqualObjects(self.statusMenu.itemArray.firstObject.representedObject, hashA);
    [self.menu menuDidClose:child];
    [self settleMainQueueTurns:2];
    XCTAssertEqual(self.menu.populateCount, populatedBefore, @"A consumed completion is not replayed");
    XCTAssertTrue([self pendingRebuild]);
    [self.menu menuDidClose:self.statusMenu];
    [self settleMainQueueTurns:2];
    XCTAssertEqualObjects(self.statusMenu.itemArray.firstObject.representedObject, hashB);
}

// Escape/close before the completion: the stale completion must not touch the
// closed menu nor a later session; the later session's own preflight refreshes it.
- (void)testStaleCompletionAfterCloseDoesNotRefreshClosedOrReopenedSession {
    [self installStatusItemStandIn];
    NSString *hashA = [self seedStatusMenuWithRow:[@"synthetic-esc-A-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    self.capture.holdCompletions = YES;
    NSString *hashB = [self write:[@"synthetic-esc-B-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [self clickStatusItem];
    [self.menu menuDidClose:self.statusMenu]; // Escape before persistence completed
    [self settleMainQueueTurns:2];
    XCTAssertEqualObjects(self.statusMenu.itemArray.firstObject.representedObject, hashA);
    [self clickStatusItem]; // new session
    [self persistPendingGeneration];
    XCTAssertTrue([self pendingRebuild]);
    NSUInteger populatedBefore = self.menu.populateCount;
    self.menu.highlighted = NO;
    [self deliverHeldCompletion]; // stale, from the closed session
    XCTAssertEqual(self.menu.populateCount, populatedBefore, @"A closed session's completion never refreshes another session");
    XCTAssertTrue([self pendingRebuild]);
    [self deliverHeldCompletion]; // this session's own completion
    XCTAssertEqual(self.menu.populateCount, populatedBefore + 1);
    XCTAssertEqualObjects(self.statusMenu.itemArray.firstObject.representedObject, hashB);
    XCTAssertFalse([self pendingRebuild]);
}

// Quit drain / clear history stop monitoring; a stop, or stop+restart, before
// the completion leaves the open menu untouched (deferred to close as before).
- (void)testStatusItemClickIsInvalidatedByStopDrainAndByStopRestart {
    [self installStatusItemStandIn];
    NSString *hashA = [self seedStatusMenuWithRow:[@"synthetic-stop-A-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    self.capture.holdCompletions = YES;
    [self write:[@"synthetic-stop-B-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [self clickStatusItem];
    [self persistPendingGeneration];
    NSUInteger populatedBefore = self.menu.populateCount;
    [self.capture stopMonitoring];
    [self deliverHeldCompletion];
    XCTAssertEqual(self.menu.populateCount, populatedBefore, @"Stopped: no refresh");
    XCTAssertEqualObjects(self.statusMenu.itemArray.firstObject.representedObject, hashA);
    XCTAssertTrue([self pendingRebuild]);

    [self.capture startMonitoring]; // restart, e.g. termination cancelled or clear finished
    [self clickStatusItem];         // a new session while monitoring again
    [self.capture stopMonitoring];
    [self.capture startMonitoring]; // ABA before its completion
    [self deliverHeldCompletion];
    XCTAssertEqual(self.menu.populateCount, populatedBefore, @"isMonitoring is true again, the generation still invalidates");
    XCTAssertTrue([self pendingRebuild]);
    [self.capture stopMonitoring];
}

// Clear history in progress (deletion) never refreshes into a list being deleted.
- (void)testStatusItemClickIsInvalidatedWhileHistoryClearInProgress {
    [self installStatusItemStandIn];
    NSString *hashA = [self seedStatusMenuWithRow:[@"synthetic-clear-A-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    self.capture.holdCompletions = YES;
    [self write:[@"synthetic-clear-B-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [self clickStatusItem];
    [self persistPendingGeneration];
    NSUInteger populatedBefore = self.menu.populateCount;
    [self.menu setValue:@YES forKey:@"historyClearInProgress"];
    [self deliverHeldCompletion];
    [self.menu setValue:@NO forKey:@"historyClearInProgress"];
    XCTAssertEqual(self.menu.populateCount, populatedBefore);
    XCTAssertEqualObjects(self.statusMenu.itemArray.firstObject.representedObject, hashA);
    XCTAssertTrue([self pendingRebuild]);
}

// An already observed generation is neither re-captured nor re-ordered by opening.
- (void)testOpeningDoesNotRecaptureOrReorderAnObservedGeneration {
    NSString *text = [@"synthetic-observed-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSString *hash = [self write:text];
    [self.capture pollPasteboardOnMonitoringQueue];
    [self drain];
    [self settleMainQueueTurns:1];
    XCTAssertEqual(self.capture.saved.count, 1u);
    NSNumber *before = [self updateTimeForHash:hash];
    CFAbsoluteTime requested = CFAbsoluteTimeGetCurrent();
    [self.menu popUpHistoryMenuFromHotKey];
    [self waitUntilPresented:1 timeout:3];
    [self drain];
    [self settleMainQueueTurns:2];
    NSLog(@"RC_MENU_METRIC path=history_unchanged hotkey_to_popup_ms=%.3f",
          (self.menu.presentedAt.firstObject.doubleValue - requested) * 1000);
    XCTAssertEqualObjects(self.capture.observed, @[text], @"Observed exactly once");
    XCTAssertEqual(self.capture.saved.count, 1u, @"No overwrite/reorder notification for an unchanged generation");
    XCTAssertEqualObjects([self updateTimeForHash:hash], before);
    XCTAssertEqualObjects(self.menu.presented.firstObject.itemArray.firstObject.representedObject, hash);
}
@end
