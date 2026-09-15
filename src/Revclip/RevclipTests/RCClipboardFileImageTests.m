#import <XCTest/XCTest.h>
#import <AppKit/AppKit.h>
#import "RCClipData.h"
#import "RCClipboardService.h"
#import "RCSnippetMedia.h"
#import "RCFileImagePreview.h"
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>

// Synthetic file pixels and named pasteboards only; no live clipboard or history.
@interface RCClipboardFileImageTests : XCTestCase
@property (nonatomic, strong) NSURL *directory;
@property (nonatomic, strong) NSURL *imageURL;
@property (nonatomic, strong) NSData *bluePNG;
@property (nonatomic, strong) NSData *redIconTIFF;
@property (nonatomic, strong) NSPasteboard *sourceBoard;
@property (nonatomic, strong) NSPasteboard *destinationBoard;
@end
@implementation RCClipboardFileImageTests
- (NSData *)solidImageRed:(unsigned char)red blue:(unsigned char)blue type:(NSBitmapImageFileType)type {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:16 pixelsHigh:16 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
        isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:64 bitsPerPixel:32];
    XCTAssertNotNil(bitmap);
    for (NSUInteger pixel = 0; pixel < 16 * 16; pixel++) {
        unsigned char *rgba = bitmap.bitmapData + pixel * 4;
        rgba[0] = red; rgba[1] = 0; rgba[2] = blue; rgba[3] = 255;
    }
    NSData *result = [bitmap representationUsingType:type properties:@{}];
    XCTAssertGreaterThan(result.length, 0u);
    return result;
}
- (void)setUp {
    [super setUp];
    self.directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:self.directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil]);
    self.imageURL = [self.directory URLByAppendingPathComponent:@"synthetic-blue.png"];
    self.bluePNG = [self solidImageRed:0 blue:255 type:NSBitmapImageFileTypePNG];
    self.redIconTIFF = [self solidImageRed:255 blue:0 type:NSBitmapImageFileTypeTIFF];
    XCTAssertTrue([self.bluePNG writeToURL:self.imageURL options:NSDataWritingAtomic error:nil]);
    self.sourceBoard = [NSPasteboard pasteboardWithUniqueName];
    self.destinationBoard = [NSPasteboard pasteboardWithUniqueName];
}
- (void)tearDown {
    [self.sourceBoard releaseGlobally];
    [self.destinationBoard releaseGlobally];
    [NSFileManager.defaultManager removeItemAtURL:self.directory error:nil];
    [super tearDown];
}
- (RCClipData *)captureFileWithIcon:(BOOL)includeIcon withText:(BOOL)includeText {
    NSPasteboardItem *item = [NSPasteboardItem new];
    XCTAssertTrue([item setString:self.imageURL.absoluteString forType:NSPasteboardTypeFileURL]);
    if (includeIcon) XCTAssertTrue([item setData:self.redIconTIFF forType:NSPasteboardTypeTIFF]);
    if (includeText) XCTAssertTrue([item setString:@"synthetic-blue.png" forType:NSPasteboardTypeString]);
    XCTAssertTrue([self.sourceBoard writeObjects:@[item]]);
    return [RCClipData clipDataFromPasteboard:self.sourceBoard];
}
- (NSColor *)centerPixelOfImage:(NSImage *)image {
    XCTAssertNotNil(image);
    NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:image.TIFFRepresentation];
    XCTAssertNotNil(bitmap);
    return [[bitmap colorAtX:bitmap.pixelsWide / 2 y:bitmap.pixelsHigh / 2] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
}
- (void)assertBluePreview:(RCClipData *)clip {
    NSImage *image = [RCFileImagePreview imageForClip:clip size:32];
    NSColor *pixel = [self centerPixelOfImage:image];
    XCTAssertGreaterThan(pixel.blueComponent, 0.9);
    XCTAssertLessThan(pixel.redComponent, 0.1);
    NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:image.TIFFRepresentation];
    XCTAssertLessThanOrEqual(MAX(bitmap.pixelsWide, bitmap.pixelsHigh), 64);
}
- (void)testFileURLOnlyUsesActualPNG {
    RCClipData *clip = [self captureFileWithIcon:NO withText:NO];
    [self assertBluePreview:clip];
    XCTAssertNil(clip.TIFFData);
    XCTAssertEqualObjects(clip.fileURLs, (@[self.imageURL]));
}
- (void)testFileURLBeatsFinderIconAndPreservesPayload {
    RCClipData *clip = [self captureFileWithIcon:YES withText:NO];
    [self assertBluePreview:clip];
    XCTAssertEqualObjects(clip.TIFFData, self.redIconTIFF);
}
- (void)testLegacyFileNamesUseActualPNG {
    RCClipData *clip = [RCClipData new];
    clip.fileNames = @[self.imageURL.path];
    clip.TIFFData = self.redIconTIFF;
    [self assertBluePreview:clip];
    XCTAssertEqualObjects(clip.TIFFData, self.redIconTIFF);
}
- (void)testMissingInvalidAndNonRegularFilesHaveNoFilePreview {
    RCClipData *clip = [RCClipData new];
    for (NSURL *url in @[[self.directory URLByAppendingPathComponent:@"missing.png"], self.directory,
                         [NSURL URLWithString:@"https://example.invalid/image.png"]]) {
        clip.fileURLs = @[url];
        XCTAssertNil([RCFileImagePreview imageForClip:clip size:32]);
    }
    NSURL *invalid = [self.directory URLByAppendingPathComponent:@"invalid.png"];
    [@"not an image" writeToURL:invalid atomically:YES encoding:NSUTF8StringEncoding error:nil];
    clip.fileURLs = @[invalid];
    XCTAssertNil([RCFileImagePreview imageForClip:clip size:32]);
    NSURL *fifo = [self.directory URLByAppendingPathComponent:@"pipe.png"];
    XCTAssertEqual(mkfifo(fifo.fileSystemRepresentation, 0600), 0);
    clip.fileURLs = @[fifo];
    XCTAssertNil([RCFileImagePreview imageForClip:clip size:32]);
}
- (void)testOversizedFileRejectedWithoutReadingPayload {
    NSURL *large = [self.directory URLByAppendingPathComponent:@"large.png"];
    int fd = open(large.fileSystemRepresentation, O_CREAT | O_WRONLY | O_EXCL, 0600);
    XCTAssertGreaterThanOrEqual(fd, 0);
    if (fd < 0) return;
    XCTAssertEqual(ftruncate(fd, 10 * 1024 * 1024 + 1), 0);
    close(fd);
    RCClipData *clip = [RCClipData new]; clip.fileURLs = @[large];
    XCTAssertNil([RCFileImagePreview imageForClip:clip size:32]);
}
- (void)testOnlyFirstFileIsConsidered {
    RCClipData *clip = [RCClipData new];
    clip.fileURLs = @[[self.directory URLByAppendingPathComponent:@"missing.png"], self.imageURL];
    XCTAssertNil([RCFileImagePreview imageForClip:clip size:32]);
}
- (void)testMixedTextFileAndIconMustRetainFileCopyPayloadOnRoundTrip {
    RCClipData *clip = [self captureFileWithIcon:YES withText:YES];
    XCTAssertEqualObjects(clip.primaryType, NSPasteboardTypeString);
    XCTAssertEqualObjects(clip.fileURLs, (@[self.imageURL]));
    [self assertBluePreview:clip];
    XCTAssertTrue([clip writeToPasteboard:self.destinationBoard]);
    RCClipData *restored = [RCClipData clipDataFromPasteboard:self.destinationBoard];
    XCTAssertEqualObjects(restored.fileURLs, (@[self.imageURL]));
    XCTAssertEqualObjects(restored.stringValue, @"synthetic-blue.png");
    XCTAssertEqualObjects(restored.TIFFData, self.redIconTIFF);
    // A fix must select preview pixels independently of primaryType and must
    // not convert Finder file-copy semantics into an image-only clipboard item.
}
@end
