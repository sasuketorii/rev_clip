#import <XCTest/XCTest.h>
#import <stdlib.h>
#import "RCClipboardService.h"
#import "RCClipData.h"
#import "RCDatabaseManager.h"
#import "RCDataCleanService.h"
#import "RCUtilities.h"

@interface RCClipboardService (DrainTesting)
- (BOOL)saveClipData:(RCClipData *)clip toPath:(NSString *)path;
- (RCClipData *)readEligibleClipFromPasteboard:(NSPasteboard *)board sourceBundleIdentifier:(NSString *)source;
@end

@interface RCDrainProbe : RCClipboardService
@property (nonatomic, strong) dispatch_semaphore_t resumeSave;
@property (nonatomic, strong) XCTestExpectation *archiveWritten;
@property (atomic) BOOL saveReturned;
@property (atomic) NSUInteger reads;
@property (atomic, copy) NSString *savedPath;
@end
@implementation RCDrainProbe
- (BOOL)canReadPasteboardContentsUsingPrivacyGate { return YES; }
- (BOOL)sourceIsExcluded:(NSString *)source { return NO; }
- (BOOL)shouldStoreClipData:(RCClipData *)clip { return YES; }
- (RCClipData *)readEligibleClipFromPasteboard:(NSPasteboard *)board sourceBundleIdentifier:(NSString *)source {
    self.reads++;
    return [super readEligibleClipFromPasteboard:board sourceBundleIdentifier:source];
}
- (BOOL)saveClipData:(RCClipData *)clip toPath:(NSString *)path {
    BOOL saved = [super saveClipData:clip toPath:path];
    self.savedPath = path;
    if (self.archiveWritten) {
        [self.archiveWritten fulfill];
        // Only the persistence worker waits; XCTest pumps the main run loop.
        long timedOut = dispatch_semaphore_wait(self.resumeSave, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        XCTAssertEqual(timedOut, 0L);
    }
    self.saveReturned = YES;
    return saved;
}
@end

@interface RCClipboardDrainTests : XCTestCase
@property (nonatomic, strong) RCDrainProbe *probe;
@property (nonatomic, strong) RCDatabaseManager *db;
@property (nonatomic, strong) id observer;
@property (nonatomic, copy) NSString *folder;
@property (nonatomic, copy) NSString *snippet;
@end
@implementation RCClipboardDrainTests
- (void)setUp {
    [super setUp];
    // RCStorageTestEnvironment's constructor installs the temp DB root,
    // ephemeral cipher key, memory defaults and unique named pasteboard.
    // Fail closed if this file is ever linked without that environment.
    if (![[RCUtilities applicationSupportPath].lastPathComponent hasPrefix:@"RevclipTests-storage-"] ||
        [NSPasteboard.generalPasteboard.name isEqualToString:NSPasteboardNameGeneral]) abort();
    self.db = RCDatabaseManager.shared;
    XCTAssertTrue([self.db setupDatabase]);
    XCTAssertTrue([self.db deleteAllClipItems]);
    self.probe = [RCDrainProbe new];
    self.probe.resumeSave = dispatch_semaphore_create(0);
}
- (void)drain {
    XCTestExpectation *done = [self expectationWithDescription:@"both queues and prior main notifications drained"];
    [self.probe flushQueueWithCompletion:^{
        dispatch_async(dispatch_get_main_queue(), ^{ [done fulfill]; });
    }];
    [self waitForExpectations:@[done] timeout:6];
}
- (void)tearDown {
    [self.probe stopMonitoring];
    dispatch_semaphore_signal(self.probe.resumeSave);
    [self drain];
    if (self.observer) [NSNotificationCenter.defaultCenter removeObserver:self.observer];
    [[RCDataCleanService shared] stopCleanupTimer];
    if (self.probe.savedPath) [NSFileManager.defaultManager removeItemAtPath:self.probe.savedPath error:nil];
    [self.db deleteAllClipItems];
    if (self.snippet) [self.db deleteSnippet:self.snippet];
    if (self.folder) [self.db deleteSnippetFolder:self.folder];
    [NSPasteboard.generalPasteboard clearContents];
    [super tearDown];
}
- (void)writeExternalFixture {
    NSPasteboard *board = NSPasteboard.generalPasteboard;
    [board clearContents];
    XCTAssertTrue([board setString:NSUUID.UUID.UUIDString forType:NSPasteboardTypeString]);
}
- (void)testManualCaptureAfterStopDoesNotReadOrPersist {
    [self.probe stopMonitoring];
    [self writeExternalFixture];
    __block NSUInteger notifications = 0;
    self.observer = [NSNotificationCenter.defaultCenter addObserverForName:RCClipboardDidChangeNotification object:self.probe queue:nil usingBlock:^(NSNotification *note) {
        notifications++;
    }];
    [self.probe captureCurrentClipboard];
    [self drain];
    XCTAssertEqual(self.probe.reads, 0u);
    XCTAssertNil(self.probe.savedPath);
    XCTAssertEqual(self.db.clipItemCount, 0);
    XCTAssertEqual(notifications, 0u);
}
- (void)testAdmittedSaveDrainsBeforeClearAndPreservesTemplate {
    self.folder = NSUUID.UUID.UUIDString;
    self.snippet = NSUUID.UUID.UUIDString;
    XCTAssertTrue(([self.db insertSnippetFolder:@{@"identifier":self.folder, @"title":@"Drain fixture"}]));
    XCTAssertTrue(([self.db insertSnippet:@{@"identifier":self.snippet, @"content":@"Preserved template"} inFolder:self.folder]));
    NSArray *templates = [self.db fetchSnippetsForFolder:self.folder];
    __block BOOL clearCompletedOnMain = NO;
    __block NSUInteger lateNotifications = 0;
    self.observer = [NSNotificationCenter.defaultCenter addObserverForName:RCClipboardDidChangeNotification object:self.probe queue:nil usingBlock:^(NSNotification *note) {
        XCTAssertTrue(NSThread.isMainThread);
        if (clearCompletedOnMain) lateNotifications++;
    }];
    self.probe.archiveWritten = [self expectationWithDescription:@"actual encrypted archive saved before INSERT"];
    [self writeExternalFixture];
    [self.probe captureCurrentClipboard];
    [self waitForExpectations:@[self.probe.archiveWritten] timeout:3];
    if (!self.probe.savedPath.length) return; // Timeout already failed; teardown releases the worker.
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:self.probe.savedPath]);
    XCTAssertNotNil([RCClipData clipDataFromPath:self.probe.savedPath]);
    XCTAssertEqual(self.db.clipItemCount, 0);
    [self.probe stopMonitoring];
    XCTestExpectation *cleared = [self expectationWithDescription:@"clear after persistence drain"];
    [self.probe flushQueueWithCompletion:^{
        XCTAssertTrue(self.probe.saveReturned);
        NSArray *rows = [self.db fetchClipItemsWithLimit:NSIntegerMax];
        XCTAssertEqual(rows.count, 1u); // Detects a flush that only drains acquisition.
        XCTAssertTrue([self.db deleteAllClipItems]);
        for (NSDictionary *row in rows) {
            for (NSString *key in @[@"data_path", @"thumbnail_path"]) {
                NSString *path = row[key];
                if (path.length) XCTAssertTrue([NSFileManager.defaultManager removeItemAtPath:path error:nil]);
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            clearCompletedOnMain = YES;
            [cleared fulfill];
        });
    }];
    // This sentinel runs after flush has queued its persistence completion.
    // A monitoring-only flush therefore observes the still-blocked save.
    dispatch_queue_t monitoring = [self.probe valueForKey:@"monitoringQueue"];
    dispatch_async(monitoring, ^{ dispatch_semaphore_signal(self.probe.resumeSave); });
    [self waitForExpectations:@[cleared] timeout:6];
    [self writeExternalFixture];
    [self.probe captureCurrentClipboard];
    [self drain];
    XCTAssertEqual(self.probe.reads, 1u);
    XCTAssertEqual(self.db.clipItemCount, 0);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:self.probe.savedPath]);
    XCTAssertEqual(lateNotifications, 0u);
    XCTAssertEqualObjects([self.db fetchSnippetsForFolder:self.folder], templates);
}
@end
