#import <XCTest/XCTest.h>
#import "RCDatabaseManager.h"
#import "RCDataCleanService.h"
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
    [[RCDataCleanService new] trimHistoryIfNeededWithDatabaseManager:self.db];
    XCTAssertEqual(self.db.clipItemCount,2);
    XCTAssertNil([self.db clipItemWithDataHash:@"retention-0"]);
    XCTAssertNotNil([self.db clipItemWithDataHash:@"retention-3"]);
    for (NSUInteger i=0;i<self.files.count;i++) XCTAssertEqual([NSFileManager.defaultManager fileExistsAtPath:self.files[i]],i>=4);
    [self.db closeDatabase]; XCTAssertTrue([self.db setupDatabase]); XCTAssertEqual(self.db.clipItemCount,2);
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
