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
