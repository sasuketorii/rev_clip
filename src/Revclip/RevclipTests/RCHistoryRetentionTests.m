#import <XCTest/XCTest.h>
#import "RCDatabaseManager.h"
#import "RCDataCleanService.h"
#import "RCClipboardService.h"
#import "RCMenuManager.h"
#import "RCClipItem.h"
#import "RCConstants.h"
#import "RCUtilities.h"
#import "RCStorageMigration.h"
#import "FMDB.h"
@interface RCDatabaseManager (RetentionTesting)
- (instancetype)initPrivate;
@end
@interface RCDataCleanService (RetentionTesting)
- (void)trimHistoryIfNeededWithDatabaseManager:(RCDatabaseManager *)db;
- (void)performCleanupOnCleanupQueue;
@end
@interface RCMenuManager (RetentionTesting)
- (NSArray<NSString *> *)clipDataFilePathsSnapshotForCurrentHistoryWithDatabaseManager:(RCDatabaseManager *)db;
- (void)removeClipDataFilesAtPaths:(NSArray<NSString *> *)paths;
@end
@interface RCRetentionTimerProbe : RCDataCleanService
@property XCTestExpectation *ran;
@end
@implementation RCRetentionTimerProbe
- (void)performCleanupOnCleanupQueue { [self.ran fulfill]; }
@end
@interface RCHistoryRetentionTests : XCTestCase
@property RCDatabaseManager *db;
@property NSString *directory;
@property NSMutableArray<NSString *> *files;
@property id savedLimit;
@end
@implementation RCHistoryRetentionTests
- (void)setUp {
    self.savedLimit = [NSUserDefaults.standardUserDefaults objectForKey:kRCPrefMaxHistorySizeKey];
    self.directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:self.directory withIntermediateDirectories:YES attributes:nil error:nil];
    self.db = [[RCDatabaseManager alloc] initPrivate];
    [self.db setValue:[self.directory stringByAppendingPathComponent:@"history.db"] forKey:@"databasePath"];
    XCTAssertTrue([self.db setupDatabase]); self.files = [NSMutableArray array];
    XCTAssertTrue([RCStorageMigration validatePrivateDirectory:[RCUtilities clipDataDirectoryPath] create:YES]);
}
- (void)tearDown {
    [self.db closeDatabase];
    for (NSString *path in self.files) [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    [NSFileManager.defaultManager removeItemAtPath:self.directory error:nil];
    if (self.savedLimit) [NSUserDefaults.standardUserDefaults setObject:self.savedLimit forKey:kRCPrefMaxHistorySizeKey];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:kRCPrefMaxHistorySizeKey];
}
- (void)seed {
    for (NSUInteger i=0;i<4;i++) {
        NSString *base = [[RCUtilities clipDataDirectoryPath] stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSString *data = [base stringByAppendingPathExtension:@"rcclip"], *thumb = [base stringByAppendingPathExtension:@"thumb"];
        for (NSString *path in @[data,thumb]) {
            XCTAssertTrue([[@"owned test fixture" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES]);
            [self.files addObject:path];
        }
        XCTAssertTrue(([self.db insertClipItem:@{@"data_hash":[NSString stringWithFormat:@"retention-%lu",i],@"data_path":data,@"thumbnail_path":thumb,@"title":@"fixture",@"primary_type":NSPasteboardTypeTIFF,@"update_time":@(100+i)}]));
    }
}
- (void)testLimitDeletesRowsAndFilesAndSurvivesDatabaseReopen {
    [self seed]; [NSUserDefaults.standardUserDefaults setInteger:2 forKey:kRCPrefMaxHistorySizeKey];
    RCDataCleanService *cleaner = [RCDataCleanService new];
    XCTestExpectation *invalidated = [self expectationForNotification:RCClipboardDidChangeNotification object:cleaner handler:^BOOL(NSNotification *note) {
        return [note.userInfo[@"historyRemoved"] boolValue] && NSThread.isMainThread;
    }];
    [cleaner trimHistoryIfNeededWithDatabaseManager:self.db];
    [self waitForExpectations:@[invalidated] timeout:2];
    XCTAssertEqual(self.db.clipItemCount,2);
    XCTAssertNil([self.db clipItemWithDataHash:@"retention-0"]);
    XCTAssertNotNil([self.db clipItemWithDataHash:@"retention-3"]);
    for (NSUInteger i=0;i<self.files.count;i++) XCTAssertEqual([NSFileManager.defaultManager fileExistsAtPath:self.files[i]],i>=4);
    [self.db closeDatabase]; XCTAssertTrue([self.db setupDatabase]); XCTAssertEqual(self.db.clipItemCount,2);
}
- (void)testEqualTimestampsDisplayExactlyTheRowsRetentionKeeps {
    [self seed];
    XCTAssertTrue([self.db performDatabaseOperation:^BOOL(FMDatabase *db) {
        return [db executeUpdate:@"UPDATE clip_items SET update_time = 100"];
    }]);
    NSArray *expected = @[@"retention-3", @"retention-2"];
    NSArray *before = [self.db fetchClipItemsWithLimit:2];
    XCTAssertEqualObjects([before valueForKey:@"data_hash"], expected);

    NSArray<RCClipItem *> *removed = [self.db trimClipItemsToLimit:2];
    XCTAssertNotNil(removed);
    XCTAssertEqual(removed.count, 2);
    XCTAssertEqualObjects(([removed valueForKey:@"dataHash"]), (@[@"retention-1", @"retention-0"]));
    XCTAssertEqualObjects([[self.db fetchClipItemsWithLimit:2] valueForKey:@"data_hash"], expected);
    XCTAssertEqualObjects([self.db fetchClipItemsWithLimit:2], before);

    [self.db closeDatabase];
    XCTAssertTrue([self.db setupDatabase]);
    XCTAssertEqualObjects([[self.db fetchClipItemsWithLimit:2] valueForKey:@"data_hash"], expected);
}
- (void)insertRecencyFixture:(NSString *)hash time:(NSInteger)time {
    NSString *path = [[RCUtilities clipDataDirectoryPath] stringByAppendingPathComponent:
                      [NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"rcclip"]];
    XCTAssertTrue(([self.db insertClipItem:@{@"data_hash":hash, @"data_path":path, @"update_time":@(time)}]));
}
- (void)testSameMillisecondReuseWinsDisplayAndRetention {
    [self insertRecencyFixture:@"A" time:1000];
    [self insertRecencyFixture:@"B" time:1000];
    XCTAssertTrue([self.db updateClipItemUpdateTime:@"A" time:1000]);
    XCTAssertEqualObjects(([[self.db fetchClipItemsWithLimit:2] valueForKey:@"data_hash"]), (@[@"A", @"B"]));
    XCTAssertGreaterThan([[self.db clipItemWithDataHash:@"A"][@"update_time"] longLongValue],
                         [[self.db clipItemWithDataHash:@"B"][@"update_time"] longLongValue]);
    NSArray *removed = [self.db trimClipItemsToLimit:1];
    XCTAssertNotNil(removed);
    XCTAssertEqualObjects(([removed valueForKey:@"dataHash"]), (@[@"B"]));
    XCTAssertNotNil([self.db clipItemWithDataHash:@"A"]);
}
- (void)testClockRollbackRecencySurvivesReopenForReuseAndInsert {
    [self insertRecencyFixture:@"A" time:2000];
    [self insertRecencyFixture:@"B" time:2001];
    [self.db closeDatabase];
    XCTAssertTrue([self.db setupDatabase]);
    XCTAssertTrue([self.db updateClipItemUpdateTime:@"A" time:1000]);
    XCTAssertEqualObjects(([[self.db fetchClipItemsWithLimit:2] valueForKey:@"data_hash"]), (@[@"A", @"B"]));
    [self.db closeDatabase];
    XCTAssertTrue([self.db setupDatabase]);
    [self insertRecencyFixture:@"C" time:500];
    XCTAssertEqualObjects(([[self.db fetchClipItemsWithLimit:3] valueForKey:@"data_hash"]), (@[@"C", @"A", @"B"]));
    NSArray *removed = [self.db trimClipItemsToLimit:2];
    XCTAssertEqualObjects(([removed valueForKey:@"dataHash"]), (@[@"B"]));
    [self.db closeDatabase];
    XCTAssertTrue([self.db setupDatabase]);
    XCTAssertEqualObjects(([[self.db fetchClipItemsWithLimit:2] valueForKey:@"data_hash"]), (@[@"C", @"A"]));
    // Once wall time catches up, retain its normal epoch-millisecond value.
    XCTAssertTrue([self.db updateClipItemUpdateTime:@"A" time:3000]);
    XCTAssertEqualObjects([self.db clipItemWithDataHash:@"A"][@"update_time"], @3000);
    XCTAssertFalse([self.db updateClipItemUpdateTime:@"missing" time:4000]);
}
- (void)testRecencyOverflowFailsWithoutMutatingHistory {
    [self insertRecencyFixture:@"A" time:NSIntegerMax];
    NSArray *before = [self.db fetchClipItemsWithLimit:10];
    XCTAssertFalse([self.db updateClipItemUpdateTime:@"A" time:1]);
    NSString *path = [[RCUtilities clipDataDirectoryPath] stringByAppendingPathComponent:@"overflow.rcclip"];
    XCTAssertFalse(([self.db insertClipItem:@{@"data_hash":@"B", @"data_path":path, @"update_time":@1}]));
    XCTAssertEqualObjects([self.db fetchClipItemsWithLimit:10], before);
}
- (void)testManualClearDeletesDatabaseRowsAndOnlyTheirFiles {
    [self seed]; RCMenuManager *menu = [RCMenuManager new];
    NSArray *paths = [menu clipDataFilePathsSnapshotForCurrentHistoryWithDatabaseManager:self.db];
    XCTAssertEqual(paths.count,8);
    NSString *unrelated = [[RCUtilities clipDataDirectoryPath] stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [@"unrelated" writeToFile:unrelated atomically:YES encoding:NSUTF8StringEncoding error:nil]; [self.files addObject:unrelated];
    XCTAssertTrue([self.db deleteAllClipItems]); [menu removeClipDataFilesAtPaths:paths];
    XCTAssertEqual(self.db.clipItemCount,0);
    for (NSString *path in paths) XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:path]);
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:unrelated]);
    [self.db closeDatabase]; XCTAssertTrue([self.db setupDatabase]); XCTAssertEqual(self.db.clipItemCount,0);
}
- (void)testFailedTrimRollsBackAndKeepsFiles {
    [self seed];
    XCTAssertTrue([self.db performDatabaseOperation:^BOOL(FMDatabase *db) {
        return [db executeUpdate:@"CREATE TRIGGER reject_delete BEFORE DELETE ON clip_items WHEN OLD.data_hash = 'retention-0' BEGIN SELECT RAISE(ABORT, 'fixture'); END"];
    }]);
    XCTAssertNil([self.db trimClipItemsToLimit:2]); XCTAssertEqual(self.db.clipItemCount,4);
    for (NSString *path in self.files) XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:path]);
}
- (void)testRepeatedCopiesDoNotPostponeCleanupDeadline {
    RCRetentionTimerProbe *service = [RCRetentionTimerProbe new];
    service.ran = [self expectationWithDescription:@"cleanup retains first deadline"];
    [service scheduleDebouncedCleanup];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_main_queue(),^{ [service scheduleDebouncedCleanup]; });
    [self waitForExpectations:@[service.ran] timeout:6.5]; [service stopCleanupTimer];
}
@end
