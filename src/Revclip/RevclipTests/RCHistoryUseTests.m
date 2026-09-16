#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import "RCMenuManager.h"
#import "RCPasteService.h"
#import "RCClipboardService.h"
#import "RCDatabaseManager.h"
#import "RCClipData.h"
#import "RCClipItem.h"
#import "RCConstants.h"
#import "RCUtilities.h"
#import "RCDataCleanService.h"

@interface RCMenuManager (HistoryUseTesting)
- (void)selectClipMenuItem:(NSMenuItem *)item;
- (void)selectSnippetMenuItem:(NSMenuItem *)item;
- (void)clearHistoryMenuItemSelected:(NSMenuItem *)item;
@end
@interface RCDatabaseManager (HistoryUseTesting)
- (instancetype)initPrivate;
@end
@interface RCClipboardService (HistoryUseTesting)
- (void)enqueueCapturedClip:(RCClipData *)clip source:(NSString *)source;
- (void)handleExistingClipWithHash:(NSString *)hash existingDict:(NSDictionary *)row
                      updateTime:(NSInteger)time databaseManager:(RCDatabaseManager *)db;
@end

@interface RCHistoryUseBoard : NSObject
@property NSInteger changeCount;
@property BOOL failWrite;
@property(copy) NSString *text;
@end
@implementation RCHistoryUseBoard
- (NSInteger)clearContents { self.text = nil; return ++self.changeCount; }
- (BOOL)setString:(NSString *)text forType:(NSString *)type {
    if (self.failWrite) return NO;
    self.text = text; ++self.changeCount; return YES;
}
@end
@interface RCHistoryUseTarget : NSObject
@property(getter=isActive) BOOL active;
@property(getter=isTerminated) BOOL terminated;
@property pid_t processIdentifier;
@property(copy) NSString *bundleIdentifier;
@end
@implementation RCHistoryUseTarget
@end
@interface RCHistoryUseClipboard : RCClipboardService
@property BOOL overwrite;
@property BOOL reorder;
@property(strong) NSMutableArray<RCClipItem *> *notifications;
@end
@implementation RCHistoryUseClipboard
- (NSInteger)readGeneralPasteboardChangeCount { return 0; }
- (BOOL)boolPreferenceForKey:(NSString *)key defaultValue:(BOOL)value {
    if ([key isEqual:kRCPrefOverwriteSameHistory]) return self.overwrite;
    if ([key isEqual:kRCPrefReorderClipsAfterPasting]) return self.reorder;
    return value;
}
- (NSInteger)currentTimestamp { return 1000; }
- (void)postClipboardDidChangeNotificationWithClipItem:(RCClipItem *)item {
    if (item) [self.notifications addObject:item]; // no global UI notifications
}
@end
@interface RCHistoryUsePaste : RCPasteService
@property(strong) RCHistoryUseBoard *board;
@property(strong) RCHistoryUseClipboard *capture;
@property(strong) RCHistoryUseTarget *target;
@property(strong) NSMutableArray<dispatch_block_t> *callbacks;
@property BOOL automatic;
@property BOOL plainModifier;
@property NSUInteger sent;
@property NSTimeInterval now;
@end
@implementation RCHistoryUsePaste
- (NSPasteboard *)pasteboard { return (id)self.board; }
- (RCClipboardService *)clipboardService { return self.capture; }
- (NSRunningApplication *)frontmostApplication { return (id)self.target; }
- (id)focusedElementForApplication:(NSRunningApplication *)application { return @"synthetic-field"; }
- (BOOL)activateApplication:(NSRunningApplication *)application { return NO; }
- (NSTimeInterval)pasteClock { return self.now; }
- (void)scheduleAfterDelay:(NSTimeInterval)delay block:(dispatch_block_t)block { [self.callbacks addObject:[block copy]]; }
- (void)sendPasteKeyStroke { self.sent++; }
- (BOOL)isPressedModifier:(NSInteger)flag { return self.plainModifier; }
- (NSInteger)integerPreferenceForKey:(NSString *)key defaultValue:(NSInteger)value { return value; }
- (BOOL)boolPreferenceForKey:(NSString *)key defaultValue:(BOOL)value {
    return [key isEqual:kRCPrefInputPasteCommandKey] ? self.automatic : value;
}
@end

@interface RCHistoryUseCleanup : NSObject
@end
@implementation RCHistoryUseCleanup
- (void)scheduleDebouncedCleanup {} // no cleanup timers in this fixture
@end
@interface RCHistoryUseMenu : RCMenuManager
@end
@implementation RCHistoryUseMenu
- (BOOL)boolPreferenceForKey:(NSString *)key defaultValue:(BOOL)value {
    return [key isEqual:kRCPrefShowAlertBeforeClearHistoryKey] ? NO : value;
}
- (void)rebuildMenu {} // no status item or global menu changes
@end

// Test-local shared accessors let the UNCHANGED baseline menu resolve the same
// isolated services. Restore every IMP after draining. Never initialize real
// clipboard/shared DB services. The storage test constructor supplies RAM keys.
@interface RCHistoryUseTests : XCTestCase {
    Method _dbMethod, _pasteMethod, _captureMethod, _cleanupMethod;
    IMP _dbOriginal, _pasteOriginal, _captureOriginal, _cleanupOriginal;
    IMP _dbReplacement, _pasteReplacement, _captureReplacement, _cleanupReplacement;
}
@property(strong) RCDatabaseManager *db;
@property(strong) RCHistoryUseClipboard *capture;
@property(strong) RCHistoryUsePaste *paste;
@property(strong) RCMenuManager *menu;
@property(copy) NSString *directory;
@property(copy) NSString *hashA;
@property(copy) NSString *hashB;
@property(strong) NSMutableArray<NSString *> *archivePaths;
@end
@implementation RCHistoryUseTests
- (void)onMain:(dispatch_block_t)block {
    if (NSThread.isMainThread) block(); else dispatch_sync(dispatch_get_main_queue(), block);
}
- (void)setUp {
    [super setUp];
    // Fail closed before any database/archive operation without test isolation.
    if (![[RCUtilities applicationSupportPath] containsString:@"RevclipTests-storage-"])
        @throw [NSException exceptionWithName:@"UnsafeHistoryUseTestHost" reason:@"Storage test constructor is required" userInfo:nil];
    self.archivePaths = [NSMutableArray array];
    self.directory = [[RCUtilities applicationSupportPath] stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtPath:self.directory withIntermediateDirectories:YES
                                                         attributes:@{NSFilePosixPermissions:@0700} error:nil]);
    self.db = [[RCDatabaseManager alloc] initPrivate];
    [self.db setValue:[self.directory stringByAppendingPathComponent:@"synthetic.db"] forKey:@"databasePath"];
    XCTAssertTrue([self.db setupDatabase]);
    [self onMain:^{
        self.capture = [RCHistoryUseClipboard new]; self.capture.notifications = [NSMutableArray array];
        self.paste = [RCHistoryUsePaste new]; self.paste.capture = self.capture;
        self.paste.board = [RCHistoryUseBoard new]; self.paste.callbacks = [NSMutableArray array];
        self.paste.target = [RCHistoryUseTarget new]; self.paste.target.active = YES;
        self.paste.target.processIdentifier = 1234567; self.paste.target.bundleIdentifier = @"test.synthetic.receiver";
        self->_dbMethod = class_getClassMethod(RCDatabaseManager.class, @selector(shared));
        self->_pasteMethod = class_getClassMethod(RCPasteService.class, @selector(shared));
        self->_captureMethod = class_getClassMethod(RCClipboardService.class, @selector(shared));
        RCDatabaseManager *db = self.db; RCPasteService *paste = self.paste; RCClipboardService *capture = self.capture;
        self->_dbReplacement = imp_implementationWithBlock(^id(id object) { return db; });
        self->_pasteReplacement = imp_implementationWithBlock(^id(id object) { return paste; });
        self->_captureReplacement = imp_implementationWithBlock(^id(id object) { return capture; });
        self->_dbOriginal = method_setImplementation(self->_dbMethod, self->_dbReplacement);
        self->_pasteOriginal = method_setImplementation(self->_pasteMethod, self->_pasteReplacement);
        self->_captureOriginal = method_setImplementation(self->_captureMethod, self->_captureReplacement);
        self->_cleanupMethod = class_getClassMethod(RCDataCleanService.class, @selector(shared));
        RCHistoryUseCleanup *cleanup = [RCHistoryUseCleanup new];
        self->_cleanupReplacement = imp_implementationWithBlock(^id(id object) { return cleanup; });
        self->_cleanupOriginal = method_setImplementation(self->_cleanupMethod, self->_cleanupReplacement);
        self.menu = [RCHistoryUseMenu new];
    }];
}
- (void)drain {
    XCTestExpectation *done = [self expectationWithDescription:@"acquisition and persistence drained"];
    [self.capture flushQueueWithCompletion:^{ dispatch_async(dispatch_get_main_queue(), ^{ [done fulfill]; }); }];
    [self waitForExpectations:@[done] timeout:3];
}
- (void)tearDown {
    if (self.capture) [self drain];
    [self onMain:^{
        [self.paste.callbacks removeAllObjects]; self.menu = nil;
        if (self->_cleanupOriginal) method_setImplementation(self->_cleanupMethod, self->_cleanupOriginal);
        if (self->_cleanupReplacement) imp_removeBlock(self->_cleanupReplacement);
        if (self->_dbOriginal) method_setImplementation(self->_dbMethod, self->_dbOriginal);
        if (self->_pasteOriginal) method_setImplementation(self->_pasteMethod, self->_pasteOriginal);
        if (self->_captureOriginal) method_setImplementation(self->_captureMethod, self->_captureOriginal);
        if (self->_dbReplacement) imp_removeBlock(self->_dbReplacement);
        if (self->_pasteReplacement) imp_removeBlock(self->_pasteReplacement);
        if (self->_captureReplacement) imp_removeBlock(self->_captureReplacement);
    }];
    [self.db closeDatabase];
    for (NSString *path in self.archivePaths) [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    if (self.directory) [NSFileManager.defaultManager removeItemAtPath:self.directory error:nil];
    [super tearDown];
}
- (NSString *)insertText:(NSString *)text time:(NSInteger)time {
    RCClipData *clip = [RCClipData new]; clip.stringValue = text; clip.primaryType = NSPasteboardTypeString;
    NSString *path = [[RCUtilities clipDataDirectoryPath] stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"rcclip"]];
    [self.archivePaths addObject:path];
    XCTAssertTrue([clip saveToPath:path maximumArchiveSize:1024*1024]);
    XCTAssertTrue(([self.db insertClipItem:@{@"data_hash":clip.dataHash, @"data_path":path,
        @"title":text, @"primary_type":NSPasteboardTypeString, @"update_time":@(time)}]));
    return clip.dataHash;
}
- (void)seed {
    XCTAssertTrue([self.db deleteAllClipItems]);
    self.hashA = [self insertText:@"synthetic-A" time:100];
    self.hashB = [self insertText:@"synthetic-B" time:200];
    [self.capture.notifications removeAllObjects];
}
- (void)selectA {
    [self onMain:^{
        NSMenuItem *item = [NSMenuItem new]; item.representedObject = self.hashA;
        [self.menu selectClipMenuItem:item];
    }];
}
- (void)assertAFirst:(BOOL)first {
    XCTAssertEqualObjects([[self.db fetchClipItemsWithLimit:2].firstObject objectForKey:@"data_hash"], first ? self.hashA : self.hashB);
}
- (void)testMenuHistoryRestoreReordersOnlyByReorderForAllFourSettings {
    for (NSNumber *overwrite in @[@NO, @YES]) for (NSNumber *reorder in @[@NO, @YES]) {
        for (NSNumber *automatic in @[@NO, @YES]) {
            [self seed]; self.capture.overwrite = overwrite.boolValue; self.capture.reorder = reorder.boolValue;
            self.paste.automatic = automatic.boolValue; self.paste.sent = 0;
            [self selectA]; [self drain];
            XCTAssertEqualObjects(self.paste.board.text, @"synthetic-A");
            XCTAssertEqual(self.paste.sent, 0u); [self assertAFirst:reorder.boolValue];
            NSNumber *restoredTime = [self.db clipItemWithDataHash:self.hashA][@"update_time"];
            NSUInteger notifications = reorder.boolValue ? 1 : 0;
            XCTAssertEqual(self.capture.notifications.count, notifications);
            [self onMain:^{
                self.paste.now += 0.05;
                NSArray<dispatch_block_t> *pending = self.paste.callbacks.copy;
                [self.paste.callbacks removeAllObjects];
                for (dispatch_block_t callback in pending) callback();
            }];
            [self drain];
            XCTAssertEqual(self.paste.sent, automatic.boolValue ? 1u : 0u);
            XCTAssertEqualObjects([self.db clipItemWithDataHash:self.hashA][@"update_time"], restoredTime);
            XCTAssertEqual(self.capture.notifications.count, notifications, @"Key delivery must not count the restore twice");
            XCTAssertEqual(self.paste.callbacks.count, 0u);
        }
    }
}
- (void)testExternalRecopyReordersOnlyByOverwriteForAllFourSettings {
    for (NSNumber *overwrite in @[@NO, @YES]) for (NSNumber *reorder in @[@NO, @YES]) {
        [self seed]; self.capture.overwrite = overwrite.boolValue; self.capture.reorder = reorder.boolValue;
        [self.capture handleExistingClipWithHash:self.hashA existingDict:[self.db clipItemWithDataHash:self.hashA]
                                    updateTime:1000 databaseManager:self.db];
        [self assertAFirst:overwrite.boolValue];
    }
}
- (void)testFailedRestoreDoesNotCountAsHistoryUse {
    [self seed]; self.capture.reorder = YES; self.capture.overwrite = YES;
    self.paste.board.failWrite = YES; [self selectA]; [self drain];
    [self assertAFirst:NO]; XCTAssertEqual(self.capture.notifications.count, 0u);
}
- (void)testLaterPasteCancellationStillCountsSuccessfulRestore {
    [self seed]; self.capture.reorder = YES; self.paste.automatic = YES;
    [self selectA];
    [self onMain:^{
        self.paste.board.changeCount++; self.paste.now = 2.0;
        NSArray<dispatch_block_t> *pending = self.paste.callbacks.copy; [self.paste.callbacks removeAllObjects];
        for (dispatch_block_t callback in pending) callback();
    }];
    [self drain]; [self assertAFirst:YES]; XCTAssertEqual(self.paste.sent, 0u);
}
- (void)testTemplateRestoreWithMatchingContentDoesNotCountAsHistoryUse {
    [self seed]; self.capture.reorder = YES; self.capture.overwrite = YES;
    XCTAssertTrue(([self.db insertSnippetFolder:@{@"identifier":@"use-folder", @"title":@"Synthetic", @"enabled":@YES, @"folder_index":@0}]));
    XCTAssertTrue(([self.db insertSnippet:@{@"identifier":@"use-template", @"title":@"Synthetic", @"content":@"synthetic-A", @"enabled":@YES, @"snippet_index":@0} inFolder:@"use-folder"]));
    [self onMain:^{
        NSMenuItem *item = [NSMenuItem new];
        item.representedObject = @{@"folderIdentifier":@"use-folder", @"snippetIdentifier":@"use-template"};
        [self.menu selectSnippetMenuItem:item];
    }];
    [self drain]; [self assertAFirst:NO]; XCTAssertEqualObjects(self.paste.board.text, @"synthetic-A");
}
- (void)testRecopyNotificationUsesActualPersistedMonotonicTime {
    [self seed]; self.capture.overwrite = YES;
    [self.capture handleExistingClipWithHash:self.hashA existingDict:[self.db clipItemWithDataHash:self.hashA]
                                updateTime:1 databaseManager:self.db];
    XCTAssertEqual(self.capture.notifications.count, 1u);
    XCTAssertEqual(self.capture.notifications.lastObject.updateTime,
                   [[self.db clipItemWithDataHash:self.hashA][@"update_time"] integerValue]);
}
- (dispatch_queue_t)acquisitionQueue { return [self.capture valueForKey:@"monitoringQueue"]; }
- (dispatch_queue_t)persistenceQueue { return [self.capture valueForKey:@"persistenceQueue"]; }
- (void)waitForAcquisitionBarrier {
    XCTestExpectation *done = [self expectationWithDescription:@"use submitted to persistence"];
    dispatch_async([self acquisitionQueue], ^{ [done fulfill]; });
    [self waitForExpectations:@[done] timeout:3];
}
- (void)queueExternalCopyOfHash:(NSString *)hash {
    RCClipData *clip = [RCClipData clipDataFromPath:[self.db clipItemWithDataHash:hash][@"data_path"]];
    XCTAssertNotNil(clip);
    dispatch_async([self acquisitionQueue], ^{ [self.capture enqueueCapturedClip:clip source:@"test.synthetic.copy-source"]; });
}
- (void)testHistoryUseSharesAcquisitionAndPersistenceOrderWithExternalCopies {
    [self seed]; self.capture.reorder = YES; self.capture.overwrite = YES;
    [self queueExternalCopyOfHash:self.hashB]; [self selectA]; [self drain];
    [self assertAFirst:YES];
    XCTAssertEqualObjects(([self.capture.notifications valueForKey:@"dataHash"]), (@[self.hashB, self.hashA]));
    [self.capture.notifications removeAllObjects];
    [self selectA]; [self queueExternalCopyOfHash:self.hashB]; [self drain];
    [self assertAFirst:NO];
    XCTAssertEqualObjects(([self.capture.notifications valueForKey:@"dataHash"]), (@[self.hashA, self.hashB]));
}
- (void)testAcceptedUsePersistsWhenStopPrecedesEitherQueueDrain {
    for (NSString *queueKey in @[@"monitoringQueue", @"persistenceQueue"]) {
        [self seed]; self.capture.reorder = YES;
        // Resume eligibility for this fixture without creating a polling timer.
        [self.capture setValue:@NO forKey:@"captureSuspended"];
        dispatch_queue_t queue = [self.capture valueForKey:queueKey];
        dispatch_suspend(queue);
        @try {
            [self selectA];
            if ([queueKey isEqual:@"persistenceQueue"]) [self waitForAcquisitionBarrier];
            [self.capture stopMonitoring];
        } @finally { dispatch_resume(queue); }
        [self drain]; [self assertAFirst:YES]; XCTAssertEqual(self.capture.notifications.count, 1u);
        XCTAssertTrue([self.db deleteAllClipItems]);
        [self drain]; XCTAssertEqual(self.db.clipItemCount, 0);
    }
}
- (void)testDeletedRowIsNotResurrectedByQueuedUse {
    [self seed]; self.capture.reorder = YES;
    dispatch_queue_t queue = [self persistenceQueue]; dispatch_suspend(queue);
    @try {
        [self selectA]; [self waitForAcquisitionBarrier];
        XCTAssertTrue([self.db deleteClipItemWithDataHash:self.hashA]);
    } @finally { dispatch_resume(queue); }
    [self drain];
    XCTAssertNil([self.db clipItemWithDataHash:self.hashA]);
    XCTAssertEqual(self.db.clipItemCount, 1); XCTAssertEqual(self.capture.notifications.count, 0u);
}
- (void)testMenuClearDrainsQueuedUseAndRejectsSelectionsDuringClear {
    [self seed]; self.capture.reorder = YES;
    dispatch_queue_t queue = [self persistenceQueue]; dispatch_suspend(queue);
    @try {
        [self selectA]; [self waitForAcquisitionBarrier];
        NSInteger count = self.paste.board.changeCount;
        [self onMain:^{ [self.menu clearHistoryMenuItemSelected:nil]; }];
        [self selectA];
        XCTAssertEqual(self.paste.board.changeCount, count);
    } @finally { dispatch_resume(queue); }
    [self drain];
    XCTAssertEqual(self.db.clipItemCount, 0);
    for (NSString *path in self.archivePaths) XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:path]);
    [self selectA]; [self drain]; XCTAssertEqual(self.db.clipItemCount, 0);
}
- (void)testStoppedServiceDoesNotAcceptNewHistoryUse {
    [self seed]; self.capture.reorder = YES; [self.capture stopMonitoring];
    [self selectA]; [self drain]; [self assertAFirst:NO];
    XCTAssertEqualObjects(self.paste.board.text, @"synthetic-A");
    XCTAssertEqual(self.capture.notifications.count, 0u);
}
- (void)testNewCaptureNotificationUsesActualPersistedTime {
    [self seed];
    XCTAssertTrue([self.db updateClipItemUpdateTime:self.hashB time:2000]);
    RCClipData *clip = [RCClipData new]; clip.stringValue = @"synthetic-C"; clip.primaryType = NSPasteboardTypeString;
    dispatch_async([self acquisitionQueue], ^{ [self.capture enqueueCapturedClip:clip source:@"test.synthetic.copy-source"]; });
    [self drain];
    NSDictionary *row = [self.db clipItemWithDataHash:clip.dataHash];
    XCTAssertNotNil(row);
    if (row[@"data_path"]) [self.archivePaths addObject:row[@"data_path"]];
    XCTAssertEqual(self.capture.notifications.count, 1u);
    XCTAssertEqual(self.capture.notifications.lastObject.updateTime, [row[@"update_time"] integerValue]);
    XCTAssertGreaterThan(self.capture.notifications.lastObject.updateTime, 2000);
}
- (void)testPlainTextModifierPreservesSelectedHistoryIdentity {
    [self seed]; self.capture.reorder = YES; self.paste.plainModifier = YES;
    [self selectA]; [self drain];
    [self assertAFirst:YES]; XCTAssertEqualObjects(self.paste.board.text, @"synthetic-A");
    XCTAssertEqual(self.capture.notifications.count, 1u);
}
- (void)testLegacyStoredHashIsUpdatedWithoutInferringIdentityFromPayload {
    [self seed]; self.capture.reorder = YES;
    NSMutableDictionary *row = [[self.db clipItemWithDataHash:self.hashA] mutableCopy];
    XCTAssertTrue([self.db deleteClipItemWithDataHash:self.hashA]);
    self.hashA = @"synthetic-legacy-history-identity"; row[@"data_hash"] = self.hashA;
    XCTAssertTrue([self.db insertClipItem:row]);
    XCTAssertTrue([self.db updateClipItemUpdateTime:self.hashB time:300]);
    [self selectA]; [self drain]; [self assertAFirst:YES];
    XCTAssertEqualObjects(self.capture.notifications.lastObject.dataHash, self.hashA);
}
@end
