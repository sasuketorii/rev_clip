#import <XCTest/XCTest.h>
#import "RCClipData.h"

@interface RCArchiveCountingClip : RCClipData
@property NSUInteger encodingCount;
@end
@implementation RCArchiveCountingClip
- (void)encodeWithCoder:(NSCoder *)coder {
    self.encodingCount += 1;
    [super encodeWithCoder:coder];
}
@end

@interface RCClipStorageTests : XCTestCase
@property NSString *directory;
@end
@implementation RCClipStorageTests
- (void)setUp {
    self.directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
}
- (void)tearDown {
    [[NSFileManager defaultManager] removeItemAtPath:self.directory error:nil];
}
- (void)testBoundedSaveSerializesOnceAndPreservesContentsAndPermissions {
    RCArchiveCountingClip *clip = [RCArchiveCountingClip new];
    clip.stringValue = @"保存テスト";
    clip.RTFData = [@"rich payload" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *expected = [NSKeyedArchiver archivedDataWithRootObject:clip requiringSecureCoding:YES error:nil];
    clip.encodingCount = 0;
    NSString *path = [self.directory stringByAppendingPathComponent:@"clip.data"];
    XCTAssertTrue([clip saveToPath:path maximumArchiveSize:expected.length]);
    XCTAssertEqual(clip.encodingCount, 1u);
    NSData *saved = [NSData dataWithContentsOfFile:path];
    RCArchiveCountingClip *loaded = [NSKeyedUnarchiver unarchivedObjectOfClass:RCArchiveCountingClip.class fromData:saved error:nil];
    XCTAssertEqualObjects(loaded.stringValue, clip.stringValue);
    XCTAssertEqualObjects(loaded.RTFData, clip.RTFData);
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    XCTAssertEqual([attributes[NSFilePosixPermissions] unsignedIntegerValue] & 0777, 0600u);
}
- (void)testOversizeArchiveDoesNotCreateOrOverwriteFile {
    RCClipData *clip = [RCClipData new];
    clip.stringValue = @"payload";
    NSString *path = [self.directory stringByAppendingPathComponent:@"clip.data"];
    XCTAssertFalse([clip saveToPath:path maximumArchiveSize:1]);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:path]);
    NSData *original = [@"original" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([original writeToFile:path atomically:YES]);
    XCTAssertFalse([clip saveToPath:path maximumArchiveSize:1]);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:path], original);
}
- (void)testDeduplicationIncludesRichContentAfterPlainText {
    RCClipData *a = [RCClipData new];
    RCClipData *b = [RCClipData new];
    a.stringValue = b.stringValue = @"same text";
    a.RTFData = [@"format A" dataUsingEncoding:NSUTF8StringEncoding];
    b.RTFData = [@"format B" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertNotEqualObjects(a.dataHash, b.dataHash);
    b.RTFData = a.RTFData;
    XCTAssertEqualObjects(a.dataHash, b.dataHash);
    b.primaryType = @"different type";
    XCTAssertNotEqualObjects(a.dataHash, b.dataHash);
}
- (void)testDeduplicationIncludesEveryFile {
    RCClipData *a = [RCClipData new];
    RCClipData *b = [RCClipData new];
    a.fileNames = @[@"first", @"second"];
    b.fileNames = @[@"first", @"third"];
    XCTAssertNotEqualObjects(a.dataHash, b.dataHash);
    XCTAssertEqualObjects([RCClipData new].dataHash, @"");
}
@end
