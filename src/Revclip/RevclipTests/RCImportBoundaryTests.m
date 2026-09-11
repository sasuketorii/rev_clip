#import <XCTest/XCTest.h>
#import "RCSnippetImportExportService.h"
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>

@interface RCImportReadProbe : RCSnippetImportExportService
@property (nonatomic, strong) NSData *receivedData;
@end
@implementation RCImportReadProbe
- (BOOL)importSnippetsFromData:(NSData *)data merge:(BOOL)merge error:(NSError **)error {
    self.receivedData = data;
    return YES;
}
@end

@interface RCImportBoundaryTests : XCTestCase
@property (nonatomic, strong) NSURL *directory;
@end
@implementation RCImportBoundaryTests
- (void)setUp {
    self.directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil]);
}
- (void)tearDown { [NSFileManager.defaultManager removeItemAtURL:self.directory error:nil]; }
- (void)testReadsRegularFileWithoutChangingContents {
    NSData *expected = [@"<templates>test</templates>" dataUsingEncoding:NSUTF8StringEncoding];
    NSURL *url = [self.directory URLByAppendingPathComponent:@"templates.xml"];
    XCTAssertTrue([expected writeToURL:url atomically:YES]);
    RCImportReadProbe *service = [RCImportReadProbe new];
    XCTAssertTrue([service importSnippetsFromURL:url merge:YES error:nil]);
    XCTAssertEqualObjects(service.receivedData, expected);
}
- (void)testRejectsOversizedSparseFileBeforeParsing {
    NSURL *url = [self.directory URLByAppendingPathComponent:@"large.xml"];
    int fd = open(url.fileSystemRepresentation, O_CREAT | O_RDWR | O_EXCL, 0600);
    XCTAssertGreaterThanOrEqual(fd, 0);
    XCTAssertEqual(ftruncate(fd, 50 * 1024 * 1024 + 1), 0);
    close(fd);
    RCImportReadProbe *service = [RCImportReadProbe new];
    NSError *error = nil;
    XCTAssertFalse([service importSnippetsFromURL:url merge:NO error:&error]);
    XCTAssertNotNil(error);
    XCTAssertNil(service.receivedData);
}
- (void)testRejectsDirectoriesAndFIFOsWithoutBlockingOrParsing {
    NSURL *fifo = [self.directory URLByAppendingPathComponent:@"pipe.xml"];
    XCTAssertEqual(mkfifo(fifo.fileSystemRepresentation, 0600), 0);
    for (NSURL *url in @[self.directory, fifo]) {
        RCImportReadProbe *service = [RCImportReadProbe new];
        NSError *error = nil;
        XCTAssertFalse([service importSnippetsFromURL:url merge:NO error:&error]);
        XCTAssertNotNil(error);
        XCTAssertNil(service.receivedData);
    }
}
@end
