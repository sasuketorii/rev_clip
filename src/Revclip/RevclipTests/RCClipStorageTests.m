#import <XCTest/XCTest.h>

#import "RCClipData.h"
#import "RCStorageCipherTestAccess.h"

#import <unistd.h>

@interface RCClipData (RCClipStorageTesting)
+ (NSString *)clipStorageDirectory;
@end



static NSString *RCClipStorageTestDirectory;

@interface RCTestClipData : RCClipData
@end

@implementation RCTestClipData

+ (NSString *)clipStorageDirectory {
    return RCClipStorageTestDirectory;
}

@end

@interface RCArchiveCountingClip : RCTestClipData
@property (nonatomic) NSUInteger encodingCount;
@end

@implementation RCArchiveCountingClip

- (void)encodeWithCoder:(NSCoder *)coder {
    self.encodingCount += 1;
    [super encodeWithCoder:coder];
}

@end

@interface RCMalformedClipData : RCTestClipData
@end

@implementation RCMalformedClipData

- (void)encodeWithCoder:(NSCoder *)coder {
    [super encodeWithCoder:coder];
    [coder encodeObject:@[@"valid", @42] forKey:@"fileNames"];
}

@end

@interface RCClipStorageTests : XCTestCase
@property (nonatomic, copy) NSString *directory;
@end

@implementation RCClipStorageTests

- (void)setUp {
    [super setUp];

    self.directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    RCClipStorageTestDirectory = self.directory;
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:self.directory
                                             withIntermediateDirectories:YES
                                                              attributes:@{NSFilePosixPermissions: @0700}
                                                                   error:nil]);


}

- (void)tearDown {
    [[NSFileManager defaultManager] removeItemAtPath:self.directory error:nil];
    RCClipStorageTestDirectory = nil;
    [super tearDown];
}

- (NSString *)pathNamed:(NSString *)name {
    return [self.directory stringByAppendingPathComponent:name];
}

- (void)testBoundedSaveSerializesOnceAndStoresEncryptedData {
    RCArchiveCountingClip *clip = [RCArchiveCountingClip new];
    clip.stringValue = @"保存テスト";
    clip.RTFData = [@"rich payload" dataUsingEncoding:NSUTF8StringEncoding];

    NSData *expected = [NSKeyedArchiver archivedDataWithRootObject:clip
                                               requiringSecureCoding:YES
                                                               error:nil];
    clip.encodingCount = 0;
    NSString *path = [self pathNamed:@"clip.data"];

    XCTAssertTrue([clip saveToPath:path maximumArchiveSize:expected.length]);
    XCTAssertEqual(clip.encodingCount, 1u);

    NSData *saved = [NSData dataWithContentsOfFile:path];
    XCTAssertNotNil(saved);
    XCTAssertFalse([saved isEqualToData:expected]);

    NSError *decryptError = nil;
    NSData *decrypted = [[RCStorageCipher shared] decryptData:saved error:&decryptError];
    XCTAssertEqualObjects(decrypted, expected, @"%@", decryptError);

    RCClipData *loaded = [RCTestClipData clipDataFromPath:path];
    XCTAssertEqualObjects(loaded.stringValue, clip.stringValue);
    XCTAssertEqualObjects(loaded.RTFData, clip.RTFData);

    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    XCTAssertEqual([attributes[NSFilePosixPermissions] unsignedIntegerValue] & 0777, 0600u);
}

- (void)testOversizeArchiveDoesNotCreateOrOverwriteFile {
    RCClipData *clip = [RCTestClipData new];
    clip.stringValue = @"payload";
    NSString *path = [self pathNamed:@"clip.data"];

    XCTAssertFalse([clip saveToPath:path maximumArchiveSize:1]);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:path]);

    NSData *original = [@"original" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([original writeToFile:path atomically:YES]);
    XCTAssertFalse([clip saveToPath:path maximumArchiveSize:1]);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:path], original);
    XCTAssertNil([RCTestClipData clipDataFromPath:path]);
}

- (void)testPlaintextClipIsRejectedWithoutFallback {
    RCClipData *clip = [RCTestClipData new];
    clip.stringValue = @"plaintext";
    NSString *path = [self pathNamed:@"plain.rcclip"];
    NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:clip
                                              requiringSecureCoding:YES
                                                              error:nil];
    XCTAssertTrue([archive writeToFile:path atomically:YES]);
    XCTAssertNil([RCTestClipData clipDataFromPath:path]);
}

- (void)testTraversalAndOutsideAbsolutePathsAreRejected {
    RCClipData *clip = [RCTestClipData new];
    clip.stringValue = @"outside";

    NSString *outsidePath = [[self.directory stringByAppendingPathComponent:@".."]
        stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.rcclip", NSUUID.UUID.UUIDString]];
    XCTAssertFalse([clip saveToPath:outsidePath]);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:outsidePath]);

    NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:clip
                                              requiringSecureCoding:YES
                                                              error:nil];
    NSError *writeError = nil;
    XCTAssertTrue([[RCStorageCipher shared] writeData:archive toPath:outsidePath error:&writeError], @"%@", writeError);
    XCTAssertNil([RCTestClipData clipDataFromPath:outsidePath]);
    [[NSFileManager defaultManager] removeItemAtPath:outsidePath error:nil];

    NSString *nestedDirectory = [self.directory stringByAppendingPathComponent:@"nested"];
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:nestedDirectory
                                              withIntermediateDirectories:NO
                                                               attributes:@{NSFilePosixPermissions: @0700}
                                                                    error:nil]);
    XCTAssertFalse([clip saveToPath:[nestedDirectory stringByAppendingPathComponent:@"clip.rcclip"]]);
}

- (void)testSymlinkDestinationIsRejectedForSaveAndRead {
    RCClipData *clip = [RCTestClipData new];
    clip.stringValue = @"symlink";
    NSString *target = [self pathNamed:@"target.rcclip"];
    NSData *original = [@"unchanged" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([original writeToFile:target atomically:YES]);

    NSString *link = [self pathNamed:@"link.rcclip"];
    XCTAssertEqual(symlink(target.fileSystemRepresentation, link.fileSystemRepresentation), 0);
    XCTAssertFalse([clip saveToPath:link]);
    XCTAssertNil([RCTestClipData clipDataFromPath:link]);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:target], original);
}

- (void)testMalformedFileArraysAreRejected {
    RCMalformedClipData *clip = [RCMalformedClipData new];
    clip.stringValue = @"malformed";
    NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:clip
                                              requiringSecureCoding:YES
                                                              error:nil];
    NSString *path = [self pathNamed:@"malformed.rcclip"];
    NSError *writeError = nil;
    XCTAssertTrue([[RCStorageCipher shared] writeData:archive toPath:path error:&writeError], @"%@", writeError);
    XCTAssertNil([RCTestClipData clipDataFromPath:path]);
}

- (void)testOversizedFileArraysAreRejected {
    RCClipData *clip = [RCTestClipData new];
    clip.stringValue = @"too many files";
    NSMutableArray<NSString *> *fileNames = [NSMutableArray arrayWithCapacity:10001];
    for (NSUInteger index = 0; index <= 10000; index++) {
        [fileNames addObject:[NSString stringWithFormat:@"file-%lu", (unsigned long)index]];
    }
    clip.fileNames = fileNames;

    NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:clip
                                              requiringSecureCoding:YES
                                                              error:nil];
    NSString *path = [self pathNamed:@"oversized-array.rcclip"];
    NSError *writeError = nil;
    XCTAssertTrue([[RCStorageCipher shared] writeData:archive toPath:path error:&writeError], @"%@", writeError);
    XCTAssertNil([RCTestClipData clipDataFromPath:path]);
}

- (void)testRootSymlinkIsRejected {
    NSString *realDirectory = [self.directory stringByAppendingString:@"-real"];
    XCTAssertTrue([[NSFileManager defaultManager] moveItemAtPath:self.directory toPath:realDirectory error:nil]);
    XCTAssertEqual(symlink(realDirectory.fileSystemRepresentation, self.directory.fileSystemRepresentation), 0);

    RCClipData *clip = [RCTestClipData new];
    clip.stringValue = @"root symlink";
    NSString *path = [self pathNamed:@"clip.rcclip"];
    XCTAssertFalse([clip saveToPath:path]);
    XCTAssertNil([RCTestClipData clipDataFromPath:path]);

    unlink(self.directory.fileSystemRepresentation);
    XCTAssertTrue([[NSFileManager defaultManager] moveItemAtPath:realDirectory toPath:self.directory error:nil]);
}

- (void)testDeduplicationIncludesRichContentAfterPlainText {
    RCClipData *a = [RCTestClipData new];
    RCClipData *b = [RCTestClipData new];
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
    RCClipData *a = [RCTestClipData new];
    RCClipData *b = [RCTestClipData new];
    a.fileNames = @[@"first", @"second"];
    b.fileNames = @[@"first", @"third"];
    XCTAssertNotEqualObjects(a.dataHash, b.dataHash);
    XCTAssertEqualObjects([RCTestClipData new].dataHash, @"");
}

@end
