#import <XCTest/XCTest.h>
#import "RCSVGPreview.h"
#import <math.h>

@interface RCSVGPreviewTests : XCTestCase
@end
@implementation RCSVGPreviewTests
- (NSString *)validated:(NSString *)svg {
    NSData *data = [RCSVGPreview validatedSVGDataForString:svg color:[NSColor colorWithSRGBRed:1 green:0 blue:0 alpha:1]];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}
- (void)testTintAndOriginalCodePreservation {
    NSMutableString *svg = [@"<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\"><g transform=\"translate(1 2) scale(0.5)\" fill-rule=\"evenodd\" clip-rule=\"evenodd\"><path fill=\"currentColor\" stroke=\"#123456\" stroke-linecap=\"round\" stroke-linejoin=\"bevel\" stroke-width=\"2\" d=\"M0 0 L20 0 L20 20 Z\"/><circle fill=\"none\" stroke=\"blue\" cx=\"12\" cy=\"12\" r=\"3\"/></g></svg>" mutableCopy];
    NSString *original = [svg copy];
    NSString *output = [self validated:svg];
    XCTAssertNotNil(output);
    XCTAssertTrue([output containsString:@"fill=\"#FF0000\""]);
    XCTAssertTrue([output containsString:@"stroke=\"#FF0000\""]);
    XCTAssertTrue([output containsString:@"fill=\"none\""]);
    XCTAssertTrue([output containsString:@"fill-rule=\"evenodd\""]);
    XCTAssertTrue([output containsString:@"clip-rule=\"evenodd\""]);
    XCTAssertTrue([output containsString:@"transform=\"translate(1 2) scale(0.5)\""]);
    XCTAssertEqualObjects(svg, original);
    XCTAssertFalse([output containsString:@"#123456"]);
}
- (void)testShapesAndDefaultFill {
    NSString *output = [self validated:@"<svg width=\"32\" height=\"16\"><rect width=\"4\" height=\"4\"/><ellipse cx=\"8\" cy=\"8\" rx=\"2\" ry=\"3\"/><line x1=\"0\" y1=\"0\" x2=\"16\" y2=\"16\" stroke=\"currentColor\"/><polygon points=\"0,0 4,0 4,4\"/><polyline points=\"0 0 4 4\"/></svg>"];
    XCTAssertNotNil(output);
    XCTAssertTrue([output containsString:@"viewBox=\"0 0 32 16\""]);
    XCTAssertTrue([output containsString:@"fill=\"#FF0000\""]);
}
- (void)testOnlyStandaloneCodeIsCandidate {
    for (NSString *text in @[@"hello", @"SVG: <svg/>", @"```svg\n<svg/>\n```", @"<svgish/>", @"<?xml version=\"1.0\"?><svg/>", @""]) {
        XCTAssertFalse([RCSVGPreview isCandidateString:text], @"%@", text);
        XCTAssertNil([self validated:text]);
    }
    XCTAssertTrue([RCSVGPreview isCandidateString:@" \n<svg viewBox=\"0 0 10 10\"/>\n"]);
    XCTAssertNil([self validated:@"<svg viewBox=\"0 0 10 10\"/> trailing prose"]);
}
- (void)testRejectsResourcesAndUnapprovedMarkup {
    for (NSString *child in @[@"<script/>", @"<foreignObject/>", @"<image/>", @"<style/>", @"<filter/>", @"<mask/>", @"<use/>", @"<animate/>", @"<animateTransform/>", @"<set/>", @"<defs/>", @"<svg/>", @"<text>hello</text>", @"<?xml-stylesheet href=\"https://example.invalid/a\"?>", @"<![CDATA[hi]]>", @"<!-- comment -->"]) {
        XCTAssertNil(([self validated:[NSString stringWithFormat:@"<svg viewBox=\"0 0 10 10\">%@</svg>", child]]), @"%@", child);
    }
    for (NSString *attr in @[@"href=\"https://example.invalid/a\"", @"href=\"#local\"", @"xlink:href=\"file:///tmp/a\"", @"style=\"fill:red\"", @"onload=\"alert(1)\"", @"fill=\"url(#paint)\"", @"fill=\"inherit\"", @"fill=\"notacolor\"", @"stroke=\"url(https://example.invalid/a)\"", @"fill=\"u&#114;l(#paint)\"", @"filter=\"none\"", @"mask=\"none\"", @"xml:base=\"https://example.invalid/\""]) {
        XCTAssertNil(([self validated:[NSString stringWithFormat:@"<svg viewBox=\"0 0 10 10\"><path d=\"M0 0L1 1\" %@/></svg>", attr]]), @"%@", attr);
    }
    XCTAssertNil([self validated:@"<!DOCTYPE svg [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><svg width='1' height='1'>&x;</svg>"]);
    XCTAssertNil([self validated:@"<svg width='1' height='1'><!ENTITY x 'x'></svg>"]);
    XCTAssertNil([self validated:@"<svg xmlns='https://example.invalid/svg' width='1' height='1'/>"]);
    XCTAssertNil([self validated:@"<html><svg width='1' height='1'/></html>"]);
    XCTAssertNil([self validated:@"<svg width='1' height='1'><g></svg>"]);
    XCTAssertNil([self validated:@"<svg width='1' height='1'/><svg width='1' height='1'/>"]);
}
- (void)testDimensionsAndSizeBounds {
    for (NSString *attrs in @[@"width='0' height='1'", @"width='-1' height='1'", @"width='1e99' height='1'", @"width='NaN' height='1'", @"width='100%' height='1'", @"width='16384' height='16384'", @"viewBox='0 0 0 1'", @"viewBox='0 0 1 -1'", @"viewBox='0 0 1 10000'", @"viewBox='0 0 2 2 2'", @"width='1'", @""]) {
        XCTAssertNil(([self validated:[NSString stringWithFormat:@"<svg %@/>",attrs]]), @"%@",attrs);
    }
    NSString *output = [self validated:@"<svg width='1600' height='800'><rect width='1600' height='800'/></svg>"];
    XCTAssertTrue([output containsString:@"width=\"720\""]);
    XCTAssertTrue([output containsString:@"height=\"360\""]);
    NSString *svg = @"<svg viewBox='0 0 2 1'><rect width='2' height='1'/></svg>";
    XCTAssertNil([RCSVGPreview imageForString:svg color:NSColor.redColor size:0]);
    XCTAssertNil([RCSVGPreview imageForString:svg color:NSColor.redColor size:-1]);
    XCTAssertNil([RCSVGPreview imageForString:svg color:NSColor.redColor size:NAN]);
    XCTAssertNil([RCSVGPreview imageForString:svg color:NSColor.redColor size:INFINITY]);
}
- (void)testByteNodeDepthAndPathBudgets {
    NSString *oversize = [@"<svg " stringByPaddingToLength:128*1024+1 withString:@" " startingAtIndex:0];
    XCTAssertFalse([RCSVGPreview isCandidateString:oversize]);
    // UTF-16 length fits but UTF-8 byte length does not.
    NSString *unicode = [@"<svg width='1' height='1'>" stringByAppendingString:[@"" stringByPaddingToLength:50000 withString:@"界" startingAtIndex:0]];
    XCTAssertTrue([RCSVGPreview isCandidateString:unicode]);
    XCTAssertNil([self validated:unicode]);
    NSMutableString *nodes = [@"<svg width='1' height='1'>" mutableCopy];
    for (NSUInteger i=0; i<512; i++) [nodes appendString:@"<g/>"];
    [nodes appendString:@"</svg>"]; XCTAssertNil([self validated:nodes]);
    NSMutableString *deep = [@"<svg width='1' height='1'>" mutableCopy];
    for (NSUInteger i=0; i<32; i++) [deep appendString:@"<g>"];
    for (NSUInteger i=0; i<32; i++) [deep appendString:@"</g>"];
    [deep appendString:@"</svg>"]; XCTAssertNil([self validated:deep]);
    NSString *path = [@"M0 0" stringByPaddingToLength:65537 withString:@" " startingAtIndex:0];
    // Keep a non-whitespace final token so trimming cannot shrink the budget input.
    XCTAssertNil(([self validated:[NSString stringWithFormat:@"<svg width='1' height='1'><path d='%@L1 1'/></svg>",path]]));
}
- (void)testBoundedPathGrammar {
    for (NSString *d in @[@"L0 0", @"M0", @"M0 0 L", @"M0 0 C1 2", @"M0 0 X1 2", @"M0 0 Z1", @"M0 0 LNaN 0", @"M0 0 L1e99 0", @"M0 0 A1 1 0 2 0 1 1", @"M0 0 A-1 1 0 0 0 1 1", @"M0,,0", @"M0 0,"]) {
        XCTAssertNil(([self validated:[NSString stringWithFormat:@"<svg viewBox='0 0 10 10'><path d='%@'/></svg>",d]]), @"%@",d);
    }
    XCTAssertNotNil([self validated:@"<svg viewBox='0 0 10 10'><path d='M0 0 l1-1 h2 v2 q1 1 2 2 t1 1 c1 1 1 1 2 2 s1 1 2 2 a1 1 0 0 1 1 1 z'/></svg>"]);
}
- (void)testAdjacentDecimalsAndCompactArcFlags {
    for (NSString *d in @[@"M.3.4L.273.049", @"M0 0A2 3 0 0110 20", @"M0 0a.5.5 0 01.3.4", @"M0 0A2 3 0 10-1-2"]) {
        XCTAssertNotNil(([self validated:[NSString stringWithFormat:@"<svg viewBox='0 0 24 24'><path d='%@'/></svg>",d]]), @"%@", d);
    }
    for (NSString *d in @[@"M0 0A2 3 0 0210 20", @"M0 0A2 3 0 -1 0 1 2", @"M0 0A2 3 0 0.0 1 1 2"]) {
        XCTAssertNil(([self validated:[NSString stringWithFormat:@"<svg viewBox='0 0 24 24'><path d='%@'/></svg>",d]]), @"%@", d);
    }
}
- (void)testTransparentPaintStaysTransparent {
    NSString *svg = @"<svg viewBox='0 0 10 10'><rect width='10' height='10' fill='transparent' stroke='transparent'/></svg>";
    NSString *output = [self validated:svg];
    XCTAssertTrue([output containsString:@"fill=\"none\""]);
    XCTAssertTrue([output containsString:@"stroke=\"none\""]);
    NSImage *image = [RCSVGPreview imageForString:svg color:NSColor.redColor size:40];
    XCTAssertNotNil(image);
    NSBitmapImageRep *rep = (NSBitmapImageRep *)image.representations.firstObject;
    XCTAssertLessThan([rep colorAtX:20 y:20].alphaComponent,0.01);
}
- (void)testAllEightExactAgentAssetsValidateAndRasterize {
    // Read repository source bytes, not asset-catalog PNGs or retyped SVG fixtures.
    NSString *tests = [[NSString stringWithUTF8String:__FILE__] stringByDeletingLastPathComponent];
    NSString *directory = [[tests stringByAppendingPathComponent:@"../Revclip/Resources/AgentIcons"] stringByStandardizingPath];
    NSArray *expected = @[@"claude.svg",@"cursor.svg",@"deepseek.svg",@"gemini.svg",@"grok.svg",@"hermes.svg",@"kimi.svg",@"openai.svg"];
    NSError *error;
    NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:&error];
    XCTAssertNotNil(files, @"%@",error);
    NSArray *svgs = [[files filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"pathExtension == 'svg'"]] sortedArrayUsingSelector:@selector(compare:)];
    XCTAssertEqualObjects(svgs, expected);
    for (NSString *file in expected) {
        @autoreleasepool {
            NSData *bytes = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:file]];
            XCTAssertNotNil(bytes, @"%@ missing",file);
            if (!bytes) continue;
            NSString *svg = [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
            XCTAssertNotNil(svg, @"%@",file);
            if (!svg) continue;
            XCTAssertEqualObjects([svg dataUsingEncoding:NSUTF8StringEncoding],bytes);
            CFAbsoluteTime validationStart = CFAbsoluteTimeGetCurrent();
            NSData *validated = [RCSVGPreview validatedSVGDataForString:svg color:NSColor.blackColor];
            NSTimeInterval validationMS = (CFAbsoluteTimeGetCurrent()-validationStart)*1000;
            XCTAssertNotNil(validated, @"%@",file);
            for (NSColor *color in @[[NSColor colorWithSRGBRed:0 green:0 blue:0 alpha:1], [NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:1]]) {
                CFAbsoluteTime rasterStart = CFAbsoluteTimeGetCurrent();
                NSImage *image = [RCSVGPreview imageForString:svg color:color size:720];
                NSTimeInterval rasterMS = (CFAbsoluteTimeGetCurrent()-rasterStart)*1000;
                CFAbsoluteTime hitStart = CFAbsoluteTimeGetCurrent();
                NSImage *hit = [RCSVGPreview imageForString:svg color:color size:720];
                NSTimeInterval hitMS = (CFAbsoluteTimeGetCurrent()-hitStart)*1000;
                NSLog(@"SVG fixture %@ validation=%.3fms request=%.3fms immediateRepeat=%.3fms",file,validationMS,rasterMS,hitMS);
                XCTAssertNotNil(image, @"%@",file); XCTAssertNotNil(hit, @"%@",file);
                NSBitmapImageRep *rep = (NSBitmapImageRep *)image.representations.firstObject;
                XCTAssertTrue([rep isKindOfClass:NSBitmapImageRep.class], @"%@",file);
                XCTAssertGreaterThan(rep.pixelsWide,0); XCTAssertLessThanOrEqual(rep.pixelsWide,720);
                XCTAssertGreaterThan(rep.pixelsHigh,0); XCTAssertLessThanOrEqual(rep.pixelsHigh,720);
                BOOL painted = NO;
                for (NSInteger y=0; y<rep.pixelsHigh && !painted; y+=4) {
                    for (NSInteger x=0; x<rep.pixelsWide; x+=4) {
                        if ([rep colorAtX:x y:y].alphaComponent > 0.05) { painted = YES; break; }
                    }
                }
                XCTAssertTrue(painted, @"%@ produced an empty raster",file);
            }
        }
    }
}
- (void)testTransformAmplificationAndUnsupportedTransformReject {
    for (NSString *transform in @[@"scale(1024) scale(1024)", @"translate(NaN)", @"matrix(1 0 0 1 0)", @"rotate(1 2)", @"url(#x)"]) {
        XCTAssertNil(([self validated:[NSString stringWithFormat:@"<svg viewBox='0 0 10 10'><g transform='%@'><path d='M0 0L1 1'/></g></svg>",transform]]));
    }
    XCTAssertNil([self validated:@"<svg viewBox='0 0 10 10'><g transform='scale(100)'><g transform='scale(100)'><g transform='scale(100)'/></g></g></svg>"]);
}
- (void)testNoneAndAlphaSurviveRasterization {
    NSString *outline = @"<svg viewBox='0 0 10 10'><rect x='1' y='1' width='8' height='8' fill='none' stroke='currentColor'/></svg>";
    NSImage *image = [RCSVGPreview imageForString:outline color:NSColor.redColor size:40];
    XCTAssertNotNil(image);
    NSBitmapImageRep *bitmap = (NSBitmapImageRep *)image.representations.firstObject;
    XCTAssertLessThan([bitmap colorAtX:20 y:20].alphaComponent,0.01);
    NSString *solid = @"<svg viewBox='0 0 10 10'><rect width='10' height='10'/></svg>";
    for (NSNumber *alpha in @[@0.25, @0.75]) {
        NSColor *color = [NSColor colorWithSRGBRed:1 green:0 blue:0 alpha:alpha.doubleValue];
        NSImage *tinted = [RCSVGPreview imageForString:solid color:color size:40];
        XCTAssertNotNil(tinted);
        NSBitmapImageRep *rep = (NSBitmapImageRep *)tinted.representations.firstObject;
        XCTAssertEqualWithAccuracy([rep colorAtX:20 y:20].alphaComponent,alpha.doubleValue,0.02);
    }
}
- (void)testRasterTintSizeAndCacheIdentity {
    NSString *svg = @"<svg viewBox='0 0 2 1'><rect width='2' height='1'/></svg>";
    NSImage *red = [RCSVGPreview imageForString:svg color:[NSColor colorWithSRGBRed:1 green:0 blue:0 alpha:1] size:40];
    NSImage *blue = [RCSVGPreview imageForString:svg color:[NSColor colorWithSRGBRed:0 green:0 blue:1 alpha:1] size:40];
    XCTAssertNotNil(red); XCTAssertNotNil(blue);
    NSBitmapImageRep *r = (NSBitmapImageRep *)red.representations.firstObject;
    NSBitmapImageRep *b = (NSBitmapImageRep *)blue.representations.firstObject;
    XCTAssertTrue([r isKindOfClass:NSBitmapImageRep.class]);
    XCTAssertEqual(r.pixelsWide,40); XCTAssertEqual(r.pixelsHigh,20);
    NSColor *rc = [[r colorAtX:20 y:10] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    NSColor *bc = [[b colorAtX:20 y:10] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    XCTAssertGreaterThan(rc.redComponent,0.9); XCTAssertLessThan(rc.blueComponent,0.1);
    XCTAssertGreaterThan(bc.blueComponent,0.9); XCTAssertLessThan(bc.redComponent,0.1);
    NSImage *large = [RCSVGPreview imageForString:svg color:NSColor.redColor size:10000];
    XCTAssertEqual(large.size.width,720); XCTAssertEqual(large.size.height,360);
    NSImage *cached = [RCSVGPreview imageForString:svg color:[NSColor colorWithSRGBRed:1 green:0 blue:0 alpha:1] size:40];
    XCTAssertEqual(cached.size.width,40);
    cached.size = NSMakeSize(1,1);
    XCTAssertEqual([RCSVGPreview imageForString:svg color:[NSColor colorWithSRGBRed:1 green:0 blue:0 alpha:1] size:40].size.width,40);
}
@end
