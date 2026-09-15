#import <XCTest/XCTest.h>
#import <AppKit/AppKit.h>
#import "RCSnippetCLIService.h"
#import "RCDatabaseManager.h"
@interface RCDatabaseManager (CLITesting)
- (instancetype)initPrivate;
@end
@interface RCSnippetCLITests : XCTestCase
@property RCDatabaseManager *db;
@property RCSnippetCLIService *api;
@property NSString *directory;
@end
@implementation RCSnippetCLITests
- (void)setUp {
    self.directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:self.directory withIntermediateDirectories:YES attributes:nil error:nil];
    self.db = [[RCDatabaseManager alloc] initPrivate];
    [self.db setValue:[self.directory stringByAppendingPathComponent:@"test.db"] forKey:@"databasePath"];
    XCTAssertTrue(([self.db setupDatabase]));
    self.api = [[RCSnippetCLIService alloc] initWithDatabase:self.db];
}
- (void)tearDown {
    [self.db closeDatabase];
    [NSFileManager.defaultManager removeItemAtPath:self.directory error:nil];
}
- (void)testCreateUpdateReadDeleteAndProtectPopulatedFolder {
    NSDictionary *folder = [self.api executeRequest:@{@"op":@"folder-create",@"title":@"CLI folder"}];
    NSString *fid = folder[@"result"][@"identifier"];
    XCTAssertNotNil(fid);
    NSDictionary *create = [self.api executeRequest:@{@"op":@"create",@"folder":fid,@"title":@"元のタイトル",@"content":@"本文\n二行目"}];
    NSString *sid = create[@"result"][@"identifier"];
    XCTAssertNotNil(sid);
    XCTAssertFalse(([[self.api executeRequest:@{@"op":@"folder-delete",@"id":fid}][@"ok"] boolValue]));
    XCTAssertTrue(([[self.api executeRequest:@{@"op":@"update",@"id":sid,@"title":@"変更後"}][@"ok"] boolValue]));
    NSDictionary *read = [self.api executeRequest:@{@"op":@"get",@"id":sid}][@"result"];
    XCTAssertEqualObjects(read[@"title"],@"変更後");
    XCTAssertEqualObjects(read[@"content"],@"本文\n二行目");
    XCTAssertNotNil([NSJSONSerialization dataWithJSONObject:read options:0 error:nil]);
    XCTAssertTrue(([[self.api executeRequest:@{@"op":@"delete",@"id":sid}][@"ok"] boolValue]));
    XCTAssertFalse(([[self.api executeRequest:@{@"op":@"get",@"id":sid}][@"ok"] boolValue]));
    XCTAssertTrue(([[self.api executeRequest:@{@"op":@"folder-delete",@"id":fid}][@"ok"] boolValue]));
}
- (void)testRejectsInvalidInputWithoutWrites {
    for (id request in @[@[], @{@"op":@"create",@"folder":@42}, @{@"op":@"unknown"},
        @{@"op":@"update",@"id":@"missing",@"title":@"x"},
        @{@"op":@"folder-create",@"title":@""}, @{@"op":@"list",@"typo":@"x"},
        @{@"op":@"create",@"image_base64":@"bad"}]) {
        XCTAssertFalse(([[self.api executeRequest:request][@"ok"] boolValue]));
    }
    XCTAssertEqual([self.db fetchSnippetCatalog].count,0);
}
- (void)testImageSurvivesTitleUpdateAndExplicitTextReplacesIt {
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(2,2)];
    [image lockFocus]; [NSColor.redColor setFill]; NSRectFill(NSMakeRect(0,0,2,2)); [image unlockFocus];
    NSString *base64 = [image.TIFFRepresentation base64EncodedStringWithOptions:0];
    NSString *fid = [self.api executeRequest:@{@"op":@"folder-create",@"title":@"media"}][@"result"][@"identifier"];
    NSString *sid = [self.api executeRequest:@{@"op":@"create",@"folder":fid,@"title":@"image",@"image_base64":base64}][@"result"][@"identifier"];
    XCTAssertNotNil(sid);
    XCTAssertTrue(([[self.api executeRequest:@{@"op":@"update",@"id":sid,@"title":@"renamed"}][@"ok"] boolValue]));
    XCTAssertGreaterThan(([[self.api executeRequest:@{@"op":@"get",@"id":sid}][@"result"][@"media_bytes"] integerValue]),0);
    XCTAssertTrue(([[self.api executeRequest:@{@"op":@"update",@"id":sid,@"content":@"text"}][@"ok"] boolValue]));
    XCTAssertEqual(([[self.api executeRequest:@{@"op":@"get",@"id":sid}][@"result"][@"media_bytes"] integerValue]),0);
}
@end

// No database initialization or real clipboard/history access in these tests.
// This deliberately is not an RCDatabaseManager subclass: only the template
// catalog exists, and any unexpected database selector fails the test.
@interface RCCLITemplateOnlyDatabaseStub : NSObject
@property (nonatomic) NSUInteger catalogReads;
@property (nonatomic) NSUInteger forbiddenReads;
- (NSArray *)fetchSnippetCatalog;
- (NSArray *)fetchClipItemsWithLimit:(NSInteger)limit;
- (NSDictionary *)clipItemWithDataHash:(NSString *)dataHash;
@end
@implementation RCCLITemplateOnlyDatabaseStub
- (NSArray *)fetchSnippetCatalog {
    self.catalogReads++;
    return @[@{@"identifier":@"synthetic-folder", @"title":@"Synthetic templates", @"folder_index":@0,
        @"snippets":@[@{@"identifier":@"synthetic-template", @"title":@"Synthetic title", @"content":@"Synthetic template content"}]}];
}
- (NSArray *)fetchClipItemsWithLimit:(NSInteger)limit {
    self.forbiddenReads++;
    return @[];
}
- (NSDictionary *)clipItemWithDataHash:(NSString *)dataHash {
    self.forbiddenReads++;
    return nil;
}
@end
@interface RCSnippetCLIPrivacyBoundaryTests : XCTestCase
@property (nonatomic, strong) RCCLITemplateOnlyDatabaseStub *stub;
@property (nonatomic, strong) RCSnippetCLIService *api;
@end
@implementation RCSnippetCLIPrivacyBoundaryTests
- (void)setUp {
    [super setUp];
    self.stub = [RCCLITemplateOnlyDatabaseStub new];
    self.api = [[RCSnippetCLIService alloc] initWithDatabase:(RCDatabaseManager *)(id)self.stub];
}
- (void)testHistoryAndClipboardOperationsFailBeforeAnyDatabaseAccess {
    for (NSString *op in @[@"history", @"history-get", @"clipboard", @"read-clipboard", @"export-history"]) {
        NSDictionary *response = [self.api executeRequest:@{@"op":op}];
        XCTAssertEqualObjects(response[@"ok"], @NO, @"%@", op);
        XCTAssertNil(response[@"result"]);
    }
    XCTAssertEqual(self.stub.catalogReads, 0u);
    XCTAssertEqual(self.stub.forbiddenReads, 0u);
}
- (void)testListAndGetRejectHistoryTargetingFieldsBeforeDatabaseAccess {
    for (NSString *op in @[@"list", @"get"]) {
        for (NSString *field in @[@"history", @"clipboard", @"source", @"table", @"data_hash", @"include_history"]) {
            NSDictionary *response = [self.api executeRequest:@{@"op":op, field:@"history"}];
            XCTAssertEqualObjects(response[@"ok"], @NO);
            XCTAssertNil(response[@"result"]);
        }
    }
    NSDictionary *list = [self.api executeRequest:@{@"op":@"list", @"id":@"history"}];
    NSDictionary *get = [self.api executeRequest:@{@"op":@"get", @"id":@"synthetic-template", @"folder":@"history"}];
    XCTAssertEqualObjects(list[@"ok"], @NO);
    XCTAssertEqualObjects(get[@"ok"], @NO);
    XCTAssertEqual(self.stub.catalogReads, 0u);
    XCTAssertEqual(self.stub.forbiddenReads, 0u);
}
- (void)testIdentifiersNeverSelectHistoryAndNormalReadsReturnOnlySyntheticTemplates {
    for (NSString *identifier in @[@"history", @"clipboard", @"clip_items", @"synthetic-history-hash"]) {
        NSDictionary *get = [self.api executeRequest:@{@"op":@"get", @"id":identifier}];
        NSDictionary *list = [self.api executeRequest:@{@"op":@"list", @"folder":identifier}];
        XCTAssertEqualObjects(get[@"ok"], @NO);
        XCTAssertEqualObjects(list[@"ok"], @NO);
        XCTAssertNil(get[@"result"]); XCTAssertNil(list[@"result"]);
    }
    NSDictionary *get = [self.api executeRequest:@{@"op":@"get", @"id":@"synthetic-template"}];
    NSDictionary *list = [self.api executeRequest:@{@"op":@"list"}];
    XCTAssertEqualObjects(get[@"result"][@"content"], @"Synthetic template content");
    XCTAssertEqualObjects(list[@"result"], (@[get[@"result"]]));
    XCTAssertEqual(self.stub.catalogReads, 10u);
    XCTAssertEqual(self.stub.forbiddenReads, 0u);
}
- (void)testRawHistoryDefaultsKeysAreNotSettingsAndSchemaDeclaresBoundary {
    for (NSString *key in @[@"history", @"clipboard", @"clip_items", @"raw_history", @"kRCPrefHistoryKey"]) {
        NSDictionary *response = [self.api executeRequest:@{@"op":@"settings-get", @"key":key}];
        XCTAssertEqualObjects(response[@"ok"], @NO);
        XCTAssertNil(response[@"result"]);
    }
    NSDictionary *schema = [self.api executeRequest:@{@"op":@"settings-schema"}][@"result"];
    XCTAssertEqualObjects(schema[@"security_boundary"][@"history_readable"], @NO);
    XCTAssertEqualObjects(schema[@"security_boundary"][@"clipboard_readable"], @NO);
    XCTAssertEqualObjects(schema[@"security_boundary"][@"bug_report_auto_collects_history"], @NO);
    XCTAssertEqual(self.stub.catalogReads, 0u);
    XCTAssertEqual(self.stub.forbiddenReads, 0u);
}
@end
