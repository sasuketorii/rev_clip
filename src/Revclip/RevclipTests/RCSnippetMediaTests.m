#import <XCTest/XCTest.h>
#import "RCSnippetMedia.h"
#import "RCSnippetImportExportService.h"
#import "RCDatabaseManager.h"
#import "RCClipData.h"
@interface RCSnippetMediaTests : XCTestCase
@end
@implementation RCSnippetMediaTests
- (NSData *)imageData {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:12 pixelsHigh:8 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    memset(bitmap.bitmapData, 200, bitmap.bytesPerRow * bitmap.pixelsHigh);
    return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}
- (void)testThumbnailAndImagePasteboardSurviveOriginalDeletion {
    NSData *image = [self imageData];
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    XCTAssertTrue([image writeToURL:url atomically:YES]);
    NSData *saved = [RCSnippetMedia readImageAtURL:url error:nil];
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
    XCTAssertEqualObjects(saved,image);
    NSImage *preview = [RCSnippetMedia thumbnailForData:saved size:16];
    XCTAssertEqualWithAccuracy(preview.size.width,16,0.1);
    XCTAssertLessThan(preview.size.height,16);
    RCClipData *clip = [RCClipData new];
    clip.TIFFData = [RCSnippetMedia pasteboardTIFFForData:saved];
    clip.primaryType = NSPasteboardTypeTIFF;
    NSPasteboard *board = [NSPasteboard pasteboardWithUniqueName];
    XCTAssertTrue([clip writeToPasteboard:board]);
    XCTAssertNotNil([[NSImage alloc] initWithData:[board dataForType:NSPasteboardTypeTIFF]]);
    XCTAssertNil([board stringForType:NSPasteboardTypeString]);
    [board releaseGlobally];
}
- (void)testImageRoundTripMergeAndMalformedImportAreAtomic {
    RCDatabaseManager *db = [RCDatabaseManager shared];
    XCTAssertTrue([db setupDatabase]);
    XCTAssertTrue([db migrateIfNeeded]);
    NSString *folderID = NSUUID.UUID.UUIDString;
    NSArray *folders = @[@{@"identifier":folderID,@"title":folderID,@"snippets":@[
        @{@"identifier":NSUUID.UUID.UUIDString,@"title":@"Logo",@"content":@"",@"media_data":[self imageData]},
        @{@"identifier":NSUUID.UUID.UUIDString,@"title":@"Color",@"content":@"#1E3A8A"}
    ]}];
    RCSnippetImportExportService *service = [RCSnippetImportExportService shared];
    NSData *exported = [service exportFoldersAsXMLData:folders error:nil];
    XCTAssertNotNil(exported);
    NSDictionary *root = [NSPropertyListSerialization propertyListWithData:exported options:0 format:nil error:nil];
    XCTAssertEqualObjects(root[@"version"],@2);
    XCTAssertTrue([service importSnippetsFromData:exported merge:YES error:nil]);
    XCTAssertTrue([service importSnippetsFromData:exported merge:YES error:nil]);
    NSArray *snippets = [db fetchSnippetsForFolder:folderID];
    XCTAssertEqual(snippets.count,2);
    XCTAssertEqualObjects(snippets[0][@"media_data"],[self imageData]);
    XCTAssertEqualObjects(snippets[1][@"content"],@"#1E3A8A");
    NSData *full = [service exportSnippetsAsXMLData:nil];
    NSDictionary *fullRoot = [NSPropertyListSerialization propertyListWithData:full options:0 format:nil error:nil];
    NSArray *exportFolders = fullRoot[@"folders"];
    NSDictionary *folder = [exportFolders filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"identifier == %@",folderID]].firstObject;
    XCTAssertEqualObjects(folder[@"snippets"][0][@"media_data"],[self imageData]);
    NSDictionary *invalid = @{@"format":@"revclip.snippets",@"version":@2,@"folders":@[@{@"title":@"bad",@"snippets":@[@{@"title":@"bad",@"content":@"",@"media_data":@"not data"}]}]};
    NSData *bad = [NSPropertyListSerialization dataWithPropertyList:invalid format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
    XCTAssertFalse([service importSnippetsFromData:bad merge:NO error:nil]);
    XCTAssertEqual([db fetchSnippetsForFolder:folderID].count,2);
    XCTAssertTrue([db deleteSnippetFolder:folderID]);
}
- (void)testLegacyTextExportRemainsVersionOne {
    NSData *exported = [[RCSnippetImportExportService shared] exportFoldersAsXMLData:@[@{@"title":@"Text",@"snippets":@[@{@"title":@"Greeting",@"content":@"Hello"}]}] error:nil];
    NSDictionary *root = [NSPropertyListSerialization propertyListWithData:exported options:0 format:nil error:nil];
    XCTAssertEqualObjects(root[@"version"],@1);
}
- (void)testRejectsInvalidAndOversizedImages {
    XCTAssertFalse([RCSnippetMedia isValidImageData:[@"bad" dataUsingEncoding:NSUTF8StringEncoding]]);
    XCTAssertFalse([RCSnippetMedia isValidImageData:[NSMutableData dataWithLength:10 * 1024 * 1024 + 1]]);
}
@end
