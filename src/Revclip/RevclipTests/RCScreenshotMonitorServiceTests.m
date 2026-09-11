#import <Cocoa/Cocoa.h>
#import <XCTest/XCTest.h>

#import "RCScreenshotMonitorService.h"
#import "RCStorageCipherTestAccess.h"

@interface RCScreenshotMonitorService (Testing)
- (nullable NSString *)generateThumbnailForImage:(NSImage *)image
                                       identifier:(NSString *)identifier
                                    directoryPath:(NSString *)directoryPath;
@end

@interface RCScreenshotMonitorServiceTests : XCTestCase
@property (nonatomic, copy) NSString *directory;
@end

@implementation RCScreenshotMonitorServiceTests

- (void)setUp {
    [super setUp];
    self.directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:self.directory
                                             withIntermediateDirectories:NO
                                                              attributes:@{NSFilePosixPermissions: @0700}
                                                                   error:nil]);
}

- (void)tearDown {
    [[NSFileManager defaultManager] removeItemAtPath:self.directory error:nil];
    self.directory = nil;
    [super tearDown];
}

- (NSImage *)fixtureImage {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:32
                      pixelsHigh:32
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSDeviceRGBColorSpace
                    bitmapFormat:NSBitmapFormatAlphaFirst
                     bytesPerRow:0
                    bitsPerPixel:0];
    XCTAssertNotNil(bitmap);
    unsigned char *bytes = bitmap.bitmapData;
    for (NSUInteger offset = 0; offset < bitmap.bytesPerRow * bitmap.pixelsHigh; offset += 4) {
        bytes[offset] = 0xff;
        bytes[offset + 1] = 0x12;
        bytes[offset + 2] = 0x34;
        bytes[offset + 3] = 0x56;
    }
    NSData *tiffData = [bitmap TIFFRepresentation];
    return [[NSImage alloc] initWithData:tiffData];
}

- (void)testScreenshotThumbnailIsEncryptedInIsolatedDirectory {
    RCScreenshotMonitorService *service = [[RCScreenshotMonitorService alloc] init];
    NSString *path = [service generateThumbnailForImage:[self fixtureImage]
                                             identifier:NSUUID.UUID.UUIDString
                                          directoryPath:self.directory];

    XCTAssertTrue(path.length > 0);
    NSData *stored = [NSData dataWithContentsOfFile:path];
    XCTAssertNotNil(stored);
    XCTAssertTrue([RCStorageCipher isEncryptedData:stored]);

    NSError *error = nil;
    NSData *decrypted = [[RCStorageCipher shared] readDataAtPath:path
                                                    allowPlaintext:NO
                                                             error:&error];
    XCTAssertNotNil(decrypted, @"%@", error);
    XCTAssertNotEqualObjects(stored, decrypted);
    XCTAssertNotNil([[NSImage alloc] initWithData:decrypted]);
}

@end
