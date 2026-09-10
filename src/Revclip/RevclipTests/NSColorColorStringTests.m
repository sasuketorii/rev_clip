#import <XCTest/XCTest.h>

#import "NSColor+HexString.h"

@interface NSColorColorStringTests : XCTestCase
@end

@implementation NSColorColorStringTests

- (void)testHexColorCompatibilityIsPreserved {
    XCTAssertTrue([NSColor isValidHexColorString:@"#0F8"]);
    XCTAssertTrue([NSColor isValidColorString:@"#0F8"]);

    NSColor *color = [NSColor colorWithColorString:@"#0F8"];
    XCTAssertNotNil(color);

    NSColor *srgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    CGFloat red = 0.0;
    CGFloat green = 0.0;
    CGFloat blue = 0.0;
    CGFloat alpha = 0.0;
    [srgb getRed:&red green:&green blue:&blue alpha:&alpha];

    XCTAssertEqualWithAccuracy(red, 0.0, 0.0001);
    XCTAssertEqualWithAccuracy(green, 1.0, 0.0001);
    XCTAssertEqualWithAccuracy(blue, 0.5333, 0.001);
    XCTAssertEqualWithAccuracy(alpha, 1.0, 0.0001);
}

- (void)testRGBAColorStringIsParsed {
    NSColor *color = [NSColor colorWithColorString:@"  RGBA(255, 128, 0, 0.5)  "];
    XCTAssertNotNil(color);
    XCTAssertTrue([NSColor isValidColorString:@"RGBA(255, 128, 0, 0.5)"]);

    NSColor *srgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    CGFloat red = 0.0;
    CGFloat green = 0.0;
    CGFloat blue = 0.0;
    CGFloat alpha = 0.0;
    [srgb getRed:&red green:&green blue:&blue alpha:&alpha];

    XCTAssertEqualWithAccuracy(red, 1.0, 0.0001);
    XCTAssertEqualWithAccuracy(green, 128.0 / 255.0, 0.0001);
    XCTAssertEqualWithAccuracy(blue, 0.0, 0.0001);
    XCTAssertEqualWithAccuracy(alpha, 0.5, 0.0001);
}

- (void)testHSLAColorStringIsParsed {
    NSColor *color = [NSColor colorWithColorString:@"hsla(240, 100%, 50%, 0.25)"];
    XCTAssertNotNil(color);
    XCTAssertTrue([NSColor isValidColorString:@"hsla(240, 100%, 50%, 0.25)"]);

    NSColor *srgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    CGFloat red = 0.0;
    CGFloat green = 0.0;
    CGFloat blue = 0.0;
    CGFloat alpha = 0.0;
    [srgb getRed:&red green:&green blue:&blue alpha:&alpha];

    XCTAssertEqualWithAccuracy(red, 0.0, 0.0001);
    XCTAssertEqualWithAccuracy(green, 0.0, 0.0001);
    XCTAssertEqualWithAccuracy(blue, 1.0, 0.0001);
    XCTAssertEqualWithAccuracy(alpha, 0.25, 0.0001);
}

- (void)testUnsupportedAndOutOfRangeValuesAreRejected {
    XCTAssertFalse([NSColor isValidColorString:@"rgb(255, 0, 0)"]);
    XCTAssertFalse([NSColor isValidColorString:@"hsl(120, 50%, 50%)"]);
    XCTAssertFalse([NSColor isValidColorString:@"rgba(255, 0, 0, 1.2)"]);
    XCTAssertFalse([NSColor isValidColorString:@"rgba(12.5, 0, 0, 1)"]);
    XCTAssertFalse([NSColor isValidColorString:@"hsla(361, 50%, 50%, 1)"]);
    XCTAssertFalse([NSColor isValidColorString:@"hsla(120, 110%, 50%, 1)"]);
}

- (void)testRejectsNaNInfAndOverflowInAllColorComponents {
    NSArray<NSString *> *invalidColorStrings = @[
        // RGBA: r / g / b / a (NaN)
        @"rgba(nan, 0, 0, 1)",
        @"rgba(0, nan, 0, 1)",
        @"rgba(0, 0, nan, 1)",
        @"rgba(0, 0, 0, nan)",
        // RGBA: r / g / b / a (Inf)
        @"rgba(inf, 0, 0, 1)",
        @"rgba(0, inf, 0, 1)",
        @"rgba(0, 0, inf, 1)",
        @"rgba(0, 0, 0, inf)",
        // RGBA: r / g / b / a (overflow)
        @"rgba(1e309, 0, 0, 1)",
        @"rgba(0, 1e309, 0, 1)",
        @"rgba(0, 0, 1e309, 1)",
        @"rgba(0, 0, 0, 1e309)",
        // HSLA: h / s / l / a (NaN)
        @"hsla(nan, 50%, 50%, 1)",
        @"hsla(120, nan%, 50%, 1)",
        @"hsla(120, 50%, nan%, 1)",
        @"hsla(120, 50%, 50%, nan)",
        // HSLA: h / s / l / a (Inf)
        @"hsla(inf, 50%, 50%, 1)",
        @"hsla(120, inf%, 50%, 1)",
        @"hsla(120, 50%, inf%, 1)",
        @"hsla(120, 50%, 50%, inf)",
        // HSLA: h / s / l / a (overflow)
        @"hsla(1e309, 50%, 50%, 1)",
        @"hsla(120, 1e309%, 50%, 1)",
        @"hsla(120, 50%, 1e309%, 1)",
        @"hsla(120, 50%, 50%, 1e309)",
    ];

    for (NSString *invalid in invalidColorStrings) {
        XCTAssertFalse([NSColor isValidColorString:invalid], @"Expected invalid: %@", invalid);
    }
}

- (void)testRejectsOverlyLongColorStrings {
    NSMutableString *longString = [NSMutableString stringWithString:@"rgba("];
    while (longString.length <= 540) {
        [longString appendString:@"1"];
    }
    [longString appendString:@", 0, 0, 1)"];

    XCTAssertFalse([NSColor isPotentialColorStringCandidate:longString]);
    XCTAssertFalse([NSColor isValidColorString:longString]);
}

- (void)testPotentialCandidateCheckUsesTrimAndCaseInsensitivePrefix {
    XCTAssertTrue([NSColor isPotentialColorStringCandidate:@"   RGBA(1,2,3,0.1)"]);
    XCTAssertTrue([NSColor isPotentialColorStringCandidate:@"  HsLa(1,2%,3%,0.4)"]);
    XCTAssertTrue([NSColor isPotentialColorStringCandidate:@"  0XFFAABB"]);
    XCTAssertTrue([NSColor isPotentialColorStringCandidate:@"  #abc"]);
    XCTAssertTrue([NSColor isPotentialColorStringCandidate:@"#AABBCCDD"]);

    XCTAssertFalse([NSColor isPotentialColorStringCandidate:@"# heading"]);
    XCTAssertFalse([NSColor isPotentialColorStringCandidate:@"#12345"]);
    XCTAssertFalse([NSColor isPotentialColorStringCandidate:@"0x12G4"]);
    XCTAssertFalse([NSColor isPotentialColorStringCandidate:@"rgb(255,0,0)"]);
    XCTAssertFalse([NSColor isPotentialColorStringCandidate:@"hsl(120,50%,50%)"]);
    XCTAssertFalse([NSColor isPotentialColorStringCandidate:@"plain text"]);
}

@end
