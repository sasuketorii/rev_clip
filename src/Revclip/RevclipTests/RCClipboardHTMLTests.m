#import <XCTest/XCTest.h>
#import "RCClipData.h"
#import "RCUtilities.h"
#import "RCClipboardService.h"
#import "RCConstants.h"
@interface RCClipboardService (HTMLTesting)
- (RCClipData *)readEligibleClipFromPasteboard:(NSPasteboard *)board sourceBundleIdentifier:(NSString *)identifier;
@end
@interface RCClipboardHTMLTests : XCTestCase
@end
@implementation RCClipboardHTMLTests
- (void)testEncryptedHTMLSurvivesInterveningCopy {
    NSPasteboard *board = [NSPasteboard pasteboardWithUniqueName];
    NSData *html = [@"<meta charset='utf-8'><span><!--(figma)AAECAw==(/figma)--></span>" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *fixturePath = NSProcessInfo.processInfo.environment[@"REVCLIP_HTML_FIXTURE"];
    if (fixturePath.length > 0) {
        html = [NSData dataWithContentsOfFile:fixturePath];
        XCTAssertGreaterThan(html.length, 0u);
        NSLog(@"HTML acceptance fixture bytes: %lu", (unsigned long)html.length);
    }
    [board setString:@"Selection" forType:NSPasteboardTypeString];
    [board setData:html forType:NSPasteboardTypeHTML];
    RCClipData *clip = [RCClipData clipDataFromPasteboard:board];
    NSString *path = [[RCUtilities clipDataDirectoryPath] stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".rcclip"]];
    XCTAssertTrue([clip saveToPath:path]);
    [board clearContents];
    [board setString:@"intervening copy" forType:NSPasteboardTypeString];
    RCClipData *restored = [RCClipData clipDataFromPath:path];
    XCTAssertEqualObjects(restored.HTMLData, html);
    XCTAssertEqualObjects(clip.dataHash, restored.dataHash);
    XCTAssertTrue([restored writeToPasteboard:board]);
    XCTAssertEqualObjects([board dataForType:NSPasteboardTypeHTML], html);
    XCTAssertEqualObjects([board stringForType:NSPasteboardTypeString], @"Selection");
    restored.HTMLData = [@"<b>different selection</b>" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertNotEqualObjects(clip.dataHash, restored.dataHash);
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    [board releaseGlobally];
}
- (void)testHTMLSettingAndPrivacyMarkers {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id old = [defaults objectForKey:kRCPrefStoreTypesKey];
    NSPasteboard *board = [NSPasteboard pasteboardWithUniqueName];
    @try {
        [board setString:@"text" forType:NSPasteboardTypeString];
        [board setString:@"<b>text</b>" forType:NSPasteboardTypeHTML];
        [defaults setObject:@{@"HTML":@NO, @"String":@YES} forKey:kRCPrefStoreTypesKey];
        RCClipData *clip = [[RCClipboardService shared] readEligibleClipFromPasteboard:board sourceBundleIdentifier:@"com.revclip.tests"];
        XCTAssertNotNil(clip); XCTAssertNil(clip.HTMLData);
        XCTAssertEqualObjects(clip.stringValue, @"text");
        [defaults setObject:@{@"HTML":@YES} forKey:kRCPrefStoreTypesKey];
        XCTAssertNotNil([[RCClipboardService shared] readEligibleClipFromPasteboard:board sourceBundleIdentifier:@"com.revclip.tests"].HTMLData);
        [board setString:@"1" forType:@"org.nspasteboard.ConcealedType"];
        XCTAssertNil([[RCClipboardService shared] readEligibleClipFromPasteboard:board sourceBundleIdentifier:@"com.revclip.tests"]);
    } @finally {
        if (old) [defaults setObject:old forKey:kRCPrefStoreTypesKey];
        else [defaults removeObjectForKey:kRCPrefStoreTypesKey];
        [board releaseGlobally];
    }
}
@end
