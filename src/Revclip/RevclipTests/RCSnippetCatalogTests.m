#import <XCTest/XCTest.h>
#import "RCDatabaseManager.h"
#import "FMDB.h"
@interface RCDatabaseManager (CatalogTesting)
- (instancetype)initPrivate;
@end
@interface RCSnippetCatalogTests : XCTestCase
@property RCDatabaseManager *database;
@property NSString *directory;
@end
@implementation RCSnippetCatalogTests
- (void)setUp {
    self.directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [[NSFileManager defaultManager] createDirectoryAtPath:self.directory withIntermediateDirectories:YES attributes:nil error:nil];
    self.database = [[RCDatabaseManager alloc] initPrivate];
    [self.database setValue:[self.directory stringByAppendingPathComponent:@"test.db"] forKey:@"databasePath"];
    XCTAssertTrue(([self.database setupDatabase]));
    XCTAssertTrue(([self.database migrateIfNeeded]));
}
- (void)tearDown {
    [self.database closeDatabase];
    [[NSFileManager defaultManager] removeItemAtPath:self.directory error:nil];
}
- (void)testCatalogUsesTextIdentifiersAndStableFolderAndSnippetOrdering {
    RCDatabaseManager *db=self.database;
    XCTAssertTrue(([db insertSnippetFolder:@{@"identifier":@"z-folder",@"title":@"first",@"folder_index":@0}]));
    XCTAssertTrue(([db insertSnippetFolder:@{@"identifier":@"a-folder",@"title":@"empty",@"folder_index":@1}]));
    XCTAssertTrue(([db insertSnippet:@{@"identifier":@"second",@"snippet_index":@1,@"content":@"二"} inFolder:@"z-folder"]));
    XCTAssertTrue(([db insertSnippet:@{@"identifier":@"first",@"snippet_index":@0,@"content":@"一"} inFolder:@"z-folder"]));
    NSArray *catalog=[db fetchSnippetCatalog];
    XCTAssertEqual(catalog.count,2);
    XCTAssertEqualObjects(catalog[0][@"identifier"],@"z-folder");
    XCTAssertEqualObjects(catalog[0][@"snippets"][0][@"identifier"],@"first");
    XCTAssertEqualObjects(catalog[0][@"snippets"][0][@"folder_id"],@"z-folder");
    XCTAssertEqual([catalog[1][@"snippets"] count],0);
    XCTAssertEqual([db currentSchemaVersion],2);
    XCTAssertTrue(([db performDatabaseOperation:^BOOL(FMDatabase *sql) {
        return [sql longForQuery:@"SELECT count(*) FROM sqlite_master WHERE type='index' AND name='idx_snippets_folder_order'"] == 1;
    }]));
}
- (void)testReadFailureIsNotAnEmptyCatalog {
    XCTAssertEqual([self.database fetchSnippetCatalog].count,0);
    XCTAssertTrue(([self.database performDatabaseOperation:^BOOL(FMDatabase *db) {
        return [db executeUpdate:@"DROP TABLE snippets"];
    }]));
    XCTAssertNil([self.database fetchSnippetCatalog]);
}
- (void)testPlacementRollsBackWholeBatchOnForeignKeyOrMissingRow {
    RCDatabaseManager *db=self.database;
    XCTAssertTrue(([db insertSnippetFolder:@{@"identifier":@"f"}]));
    XCTAssertTrue(([db insertSnippet:@{@"identifier":@"s",@"snippet_index":@0} inFolder:@"f"]));
    XCTAssertFalse(([db updateSnippetPlacement:@[
        @{@"identifier":@"s",@"folder_id":@"f",@"snippet_index":@9},
        @{@"identifier":@"missing",@"folder_id":@"f",@"snippet_index":@1}]]));
    XCTAssertEqualObjects([db fetchSnippetsForFolder:@"f"][0][@"snippet_index"],@0);
    XCTAssertFalse(([db updateSnippetPlacement:@[@{@"identifier":@"s",@"folder_id":@"missing",@"snippet_index":@1}]]));
    XCTAssertEqualObjects([db fetchSnippetsForFolder:@"f"][0][@"snippet_index"],@0);
    XCTAssertFalse(([db updateSnippetFolderIndexes:@[@"f",@"missing"]]));
}
@end
