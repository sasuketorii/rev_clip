#import <XCTest/XCTest.h>
#import <AppKit/AppKit.h>
#import "RCClipData.h"

@interface RCIdentityUntrustedHashClip : RCClipData
@end
@implementation RCIdentityUntrustedHashClip
- (NSString *)dataHash { return @"deliberately-identical"; }
- (NSString *)legacyDataHash { return @"deliberately-identical"; }
@end

@interface RCClipIdentityTests : XCTestCase
@end

@implementation RCClipIdentityTests
- (RCClipData *)plainClip {
    RCClipData *clip = [RCClipData new];
    clip.stringValue = @"same text";
    clip.primaryType = NSPasteboardTypeString;
    return clip;
}

- (void)testLegacyDigestCompatibility {
    RCClipData *clip = [self plainClip];
    XCTAssertEqualObjects(clip.legacyDataHash, @"fe6fd033d92af19bb31e184578ec95a4ae73393e3a468b845f57fa64865392c0");
    clip.HTMLData = [@"<b>same text</b>" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertEqualObjects(clip.legacyDataHash, @"6627ff671a882a23557379f01e754975a98e6c975ec5a35e398acd549fb69018");
    XCTAssertNotEqualObjects(clip.dataHash, clip.legacyDataHash);
    XCTAssertEqual(clip.dataHash.length, 64u);
    XCTAssertEqualObjects([RCClipData new].legacyDataHash, @"");
    XCTAssertEqualObjects([RCClipData new].dataHash, @"");

    clip.stringValue = @"text";
    clip.RTFData = [@"rtf" dataUsingEncoding:NSUTF8StringEncoding];
    clip.RTFDData = [@"rtfd" dataUsingEncoding:NSUTF8StringEncoding];
    clip.PDFData = [@"pdf" dataUsingEncoding:NSUTF8StringEncoding];
    clip.TIFFData = [@"tiff" dataUsingEncoding:NSUTF8StringEncoding];
    clip.fileNames = @[@"one", @"two"];
    clip.fileURLs = @[[NSURL URLWithString:@"file:///tmp/a"]];
    clip.URLString = @"https://example.test/";
    clip.primaryType = @"primary";
    clip.HTMLData = [@"html" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertEqualObjects(clip.legacyDataHash, @"94fb2a633da65e744c9c9111aeffb4020c65f4a123f8663eadbccff5c0acc286");
}

- (void)testSyntheticCrossFormatCollisionIsSeparated {
    RCClipData *a = [self plainClip];
    RCClipData *b = [self plainClip];
    a.RTFData = [@"{\\rtf1 same text}" dataUsingEncoding:NSUTF8StringEncoding];
    // Intentionally assigned to a different flavor: structural proof, not valid RTFD.
    b.RTFDData = a.RTFData;
    XCTAssertEqualObjects(a.legacyDataHash, @"82d4952ebfd2d70cf95878feaed3a3f7e129dd85da31395dab690f4b857e8dbc");
    XCTAssertEqualObjects(a.legacyDataHash, b.legacyDataHash);
    XCTAssertNotEqualObjects(a.dataHash, b.dataHash);
    XCTAssertFalse([a hasSamePayloadAsClipData:b]);
    XCTAssertFalse([a isEqual:b]);
}

- (void)testValidRichFormatsRemainDistinctAndRoundTrip {
    NSAttributedString *text = [[NSAttributedString alloc] initWithString:@"same text"];
    RCClipData *a = [self plainClip];
    RCClipData *b = [self plainClip];
    a.RTFData = [text RTFFromRange:NSMakeRange(0, text.length) documentAttributes:@{}];
    b.RTFDData = [text RTFDFromRange:NSMakeRange(0, text.length) documentAttributes:@{}];
    XCTAssertGreaterThan(a.RTFData.length, 0u);
    XCTAssertGreaterThan(b.RTFDData.length, 0u);
    XCTAssertNotEqualObjects(a.dataHash, b.dataHash);
    XCTAssertFalse([a hasSamePayloadAsClipData:b]);
    a.RTFDData = b.RTFDData;
    NSError *error = nil;
    NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:a requiringSecureCoding:YES error:&error];
    XCTAssertNil(error);
    RCClipData *restored = [NSKeyedUnarchiver unarchivedObjectOfClass:RCClipData.class fromData:archive error:&error];
    XCTAssertNil(error);
    XCTAssertTrue([a hasSamePayloadAsClipData:restored]);
    XCTAssertEqualObjects(a.dataHash, restored.dataHash);
}

- (void)testEveryScalarFieldParticipatesInHashAndDirectComparison {
    NSArray *keys = @[@"stringValue", @"HTMLData", @"RTFData", @"RTFDData", @"PDFData", @"TIFFData", @"URLString", @"primaryType"];
    for (NSString *key in keys) {
        RCClipData *a = [self plainClip];
        RCClipData *b = [self plainClip];
        id value = [key hasSuffix:@"Data"] ? (id)[@"changed" dataUsingEncoding:NSUTF8StringEncoding] : @"changed";
        [b setValue:value forKey:key];
        XCTAssertNotEqualObjects(a.dataHash, b.dataHash, @"%@", key);
        XCTAssertFalse([a hasSamePayloadAsClipData:b], @"%@", key);
        [a setValue:value forKey:key];
        XCTAssertEqualObjects(a.dataHash, b.dataHash, @"%@", key);
        XCTAssertTrue([a hasSamePayloadAsClipData:b], @"%@", key);
    }
}

- (void)testCollectionBoundariesAndOrder {
    RCClipData *a = [self plainClip];
    RCClipData *b = [self plainClip];
    a.fileNames = @[@"one", @"two"];
    b.fileNames = @[@"one"];
    b.URLString = @"two";
    XCTAssertEqualObjects(a.legacyDataHash, b.legacyDataHash);
    XCTAssertNotEqualObjects(a.dataHash, b.dataHash);
    XCTAssertFalse([a hasSamePayloadAsClipData:b]);
    b.URLString = nil;
    b.fileNames = @[@"two", @"one"];
    XCTAssertNotEqualObjects(a.dataHash, b.dataHash);
    XCTAssertFalse([a hasSamePayloadAsClipData:b]);
    b.fileNames = a.fileNames;
    a.fileURLs = @[[NSURL URLWithString:@"file:///tmp/one"], [NSURL URLWithString:@"file:///tmp/two"]];
    b.fileURLs = @[a.fileURLs.lastObject, a.fileURLs.firstObject];
    XCTAssertNotEqualObjects(a.dataHash, b.dataHash);
    XCTAssertFalse([a hasSamePayloadAsClipData:b]);
    b.fileURLs = a.fileURLs;
    XCTAssertTrue([a hasSamePayloadAsClipData:b]);
    XCTAssertEqualObjects(a.dataHash, b.dataHash);
    b.fileURLs = @[a.fileURLs.firstObject];
    XCTAssertNotEqualObjects(a.dataHash, b.dataHash);
    XCTAssertFalse([a hasSamePayloadAsClipData:b]);
}

- (void)testPresenceAndEmptyArrayElementsAreRepresented {
    NSDictionary *emptyValues = @{@"stringValue": @"", @"HTMLData": NSData.data, @"RTFData": NSData.data,
        @"RTFDData": NSData.data, @"PDFData": NSData.data, @"TIFFData": NSData.data,
        @"URLString": @"", @"primaryType": @"", @"fileNames": @[], @"fileURLs": @[]};
    for (NSString *key in emptyValues) {
        RCClipData *a = [RCClipData new];
        RCClipData *b = [RCClipData new];
        [b setValue:emptyValues[key] forKey:key];
        XCTAssertNotEqualObjects(a.dataHash, b.dataHash, @"%@", key);
        XCTAssertFalse([a hasSamePayloadAsClipData:b], @"%@", key);
    }
    RCClipData *a = [self plainClip];
    RCClipData *b = [self plainClip];
    a.fileNames = @[@""];
    b.fileNames = @[@"", @""];
    XCTAssertNotEqualObjects(a.dataHash, b.dataHash);
    XCTAssertFalse([a hasSamePayloadAsClipData:b]);
}

- (void)testPayloadComparisonDoesNotTrustEitherHash {
    RCClipData *a = [RCIdentityUntrustedHashClip new];
    RCClipData *b = [RCIdentityUntrustedHashClip new];
    a.stringValue = @"one";
    b.stringValue = @"two";
    XCTAssertEqualObjects(a.dataHash, b.dataHash);
    XCTAssertEqualObjects(a.legacyDataHash, b.legacyDataHash);
    XCTAssertFalse([a hasSamePayloadAsClipData:b]);
    XCTAssertFalse([a isEqual:b]);
    XCTAssertFalse([a hasSamePayloadAsClipData:nil]);
    b.stringValue = a.stringValue;
    XCTAssertTrue([a hasSamePayloadAsClipData:b]);
}
@end
