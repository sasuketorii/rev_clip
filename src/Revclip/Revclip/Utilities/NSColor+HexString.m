//
//  NSColor+HexString.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import "NSColor+HexString.h"
#import <math.h>

static NSUInteger const kRCMaxColorStringLength = 512;

static NSString *RCNormalizedHexColorString(NSString *input) {
    if (input.length == 0) {
        return @"";
    }

    NSString *normalized = [[input stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
    if ([normalized hasPrefix:@"#"]) {
        normalized = [normalized substringFromIndex:1];
    } else if ([normalized hasPrefix:@"0X"]) {
        normalized = [normalized substringFromIndex:2];
    }
    return normalized;
}

static BOOL RCIsHexCharactersOnly(NSString *value) {
    if (value.length == 0) {
        return NO;
    }

    NSCharacterSet *nonHexSet = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"] invertedSet];
    return [value rangeOfCharacterFromSet:nonHexSet].location == NSNotFound;
}

static CGFloat RCColorComponentFromHexPair(NSString *hexPair) {
    if (hexPair.length < 2) {
        return 0.0;
    }

    unsigned int value = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hexPair];
    [scanner scanHexInt:&value];
    return (CGFloat)value / 255.0;
}

static NSString *RCNormalizedColorCandidateString(NSString *input) {
    if (input.length == 0) {
        return @"";
    }
    return [input stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static BOOL RCIsPotentialHexColorCandidate(NSString *normalizedLowercaseInput) {
    if (normalizedLowercaseInput.length == 0) {
        return NO;
    }

    NSString *rawHex = nil;
    if ([normalizedLowercaseInput hasPrefix:@"#"]) {
        rawHex = [normalizedLowercaseInput substringFromIndex:1];
    } else if ([normalizedLowercaseInput hasPrefix:@"0x"]) {
        rawHex = [normalizedLowercaseInput substringFromIndex:2];
    } else {
        return NO;
    }

    NSUInteger length = rawHex.length;
    if (!(length == 3 || length == 4 || length == 6 || length == 8)) {
        return NO;
    }

    NSCharacterSet *nonHexSet = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    return [rawHex rangeOfCharacterFromSet:nonHexSet].location == NSNotFound;
}

static BOOL RCScanIntegerComponent(NSString *token, NSInteger *outValue) {
    if (token.length == 0 || outValue == NULL) {
        return NO;
    }

    NSScanner *scanner = [NSScanner scannerWithString:token];
    NSInteger value = 0;
    if (![scanner scanInteger:&value] || !scanner.isAtEnd) {
        return NO;
    }
    *outValue = value;
    return YES;
}

static BOOL RCScanDoubleComponent(NSString *token, double *outValue) {
    if (token.length == 0 || outValue == NULL) {
        return NO;
    }

    NSScanner *scanner = [NSScanner scannerWithString:token];
    double value = 0.0;
    if (![scanner scanDouble:&value] || !scanner.isAtEnd) {
        return NO;
    }
    if (!isfinite(value)) {
        return NO;
    }
    *outValue = value;
    return YES;
}

static NSArray<NSString *> *RCColorFunctionArguments(NSString *input, NSString *functionNameLower) {
    if (input.length == 0 || functionNameLower.length == 0) {
        return nil;
    }

    NSString *normalized = RCNormalizedColorCandidateString(input);
    if (normalized.length < functionNameLower.length + 2) {
        return nil;
    }

    NSString *lower = normalized.lowercaseString;
    NSString *prefix = [functionNameLower stringByAppendingString:@"("];
    if (![lower hasPrefix:prefix] || ![lower hasSuffix:@")"]) {
        return nil;
    }

    NSRange bodyRange = NSMakeRange(prefix.length, normalized.length - prefix.length - 1);
    NSString *body = [normalized substringWithRange:bodyRange];
    NSArray<NSString *> *rawComponents = [body componentsSeparatedByString:@","];
    if (rawComponents.count == 0) {
        return nil;
    }

    NSMutableArray<NSString *> *components = [NSMutableArray arrayWithCapacity:rawComponents.count];
    for (NSString *raw in rawComponents) {
        NSString *token = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (token.length == 0) {
            return nil;
        }
        [components addObject:token];
    }
    return [components copy];
}

static BOOL RCParseRGBAColorComponents(NSString *input, CGFloat *outRed, CGFloat *outGreen, CGFloat *outBlue, CGFloat *outAlpha) {
    NSArray<NSString *> *components = RCColorFunctionArguments(input, @"rgba");
    if (components.count != 4) {
        return NO;
    }

    NSInteger redValue = 0;
    NSInteger greenValue = 0;
    NSInteger blueValue = 0;
    double alphaValue = 0.0;

    if (!RCScanIntegerComponent(components[0], &redValue)
        || !RCScanIntegerComponent(components[1], &greenValue)
        || !RCScanIntegerComponent(components[2], &blueValue)
        || !RCScanDoubleComponent(components[3], &alphaValue)) {
        return NO;
    }

    if (redValue < 0 || redValue > 255
        || greenValue < 0 || greenValue > 255
        || blueValue < 0 || blueValue > 255
        || alphaValue < 0.0 || alphaValue > 1.0) {
        return NO;
    }

    if (outRed != NULL) {
        *outRed = (CGFloat)redValue / 255.0;
    }
    if (outGreen != NULL) {
        *outGreen = (CGFloat)greenValue / 255.0;
    }
    if (outBlue != NULL) {
        *outBlue = (CGFloat)blueValue / 255.0;
    }
    if (outAlpha != NULL) {
        *outAlpha = (CGFloat)alphaValue;
    }
    return YES;
}

static BOOL RCParsePercentValue(NSString *token, double *outValue) {
    if (token.length < 2 || ![token hasSuffix:@"%"] || outValue == NULL) {
        return NO;
    }

    NSString *numericToken = [token substringToIndex:token.length - 1];
    double value = 0.0;
    if (!RCScanDoubleComponent(numericToken, &value)) {
        return NO;
    }
    *outValue = value;
    return YES;
}

static CGFloat RCHueToRGB(CGFloat p, CGFloat q, CGFloat t) {
    if (t < 0.0) {
        t += 1.0;
    }
    if (t > 1.0) {
        t -= 1.0;
    }
    if (t < (1.0 / 6.0)) {
        return p + (q - p) * 6.0 * t;
    }
    if (t < 0.5) {
        return q;
    }
    if (t < (2.0 / 3.0)) {
        return p + (q - p) * ((2.0 / 3.0) - t) * 6.0;
    }
    return p;
}

static BOOL RCParseHSLAColorComponents(NSString *input, CGFloat *outRed, CGFloat *outGreen, CGFloat *outBlue, CGFloat *outAlpha) {
    NSArray<NSString *> *components = RCColorFunctionArguments(input, @"hsla");
    if (components.count != 4) {
        return NO;
    }

    double hueDegrees = 0.0;
    double saturationPercent = 0.0;
    double lightnessPercent = 0.0;
    double alphaValue = 0.0;

    if (!RCScanDoubleComponent(components[0], &hueDegrees)
        || !RCParsePercentValue(components[1], &saturationPercent)
        || !RCParsePercentValue(components[2], &lightnessPercent)
        || !RCScanDoubleComponent(components[3], &alphaValue)) {
        return NO;
    }

    if (hueDegrees < 0.0 || hueDegrees > 360.0
        || saturationPercent < 0.0 || saturationPercent > 100.0
        || lightnessPercent < 0.0 || lightnessPercent > 100.0
        || alphaValue < 0.0 || alphaValue > 1.0) {
        return NO;
    }

    CGFloat hue = (CGFloat)(hueDegrees / 360.0);
    CGFloat saturation = (CGFloat)(saturationPercent / 100.0);
    CGFloat lightness = (CGFloat)(lightnessPercent / 100.0);

    CGFloat red = 0.0;
    CGFloat green = 0.0;
    CGFloat blue = 0.0;

    if (saturation == 0.0) {
        red = lightness;
        green = lightness;
        blue = lightness;
    } else {
        CGFloat q = (lightness < 0.5)
            ? (lightness * (1.0 + saturation))
            : (lightness + saturation - lightness * saturation);
        CGFloat p = 2.0 * lightness - q;
        red = RCHueToRGB(p, q, hue + (1.0 / 3.0));
        green = RCHueToRGB(p, q, hue);
        blue = RCHueToRGB(p, q, hue - (1.0 / 3.0));
    }

    if (outRed != NULL) {
        *outRed = red;
    }
    if (outGreen != NULL) {
        *outGreen = green;
    }
    if (outBlue != NULL) {
        *outBlue = blue;
    }
    if (outAlpha != NULL) {
        *outAlpha = (CGFloat)alphaValue;
    }
    return YES;
}

@implementation NSColor (HexString)

+ (NSColor *)colorWithHexString:(NSString *)hexString {
    if (![self isValidHexColorString:hexString]) {
        return nil;
    }

    NSString *normalized = RCNormalizedHexColorString(hexString);
    NSString *redHex = nil;
    NSString *greenHex = nil;
    NSString *blueHex = nil;
    NSString *alphaHex = @"FF";

    switch (normalized.length) {
        case 3: {
            NSString *r = [normalized substringWithRange:NSMakeRange(0, 1)];
            NSString *g = [normalized substringWithRange:NSMakeRange(1, 1)];
            NSString *b = [normalized substringWithRange:NSMakeRange(2, 1)];
            redHex = [r stringByAppendingString:r];
            greenHex = [g stringByAppendingString:g];
            blueHex = [b stringByAppendingString:b];
            break;
        }
        case 4: {
            NSString *r = [normalized substringWithRange:NSMakeRange(0, 1)];
            NSString *g = [normalized substringWithRange:NSMakeRange(1, 1)];
            NSString *b = [normalized substringWithRange:NSMakeRange(2, 1)];
            NSString *a = [normalized substringWithRange:NSMakeRange(3, 1)];
            redHex = [r stringByAppendingString:r];
            greenHex = [g stringByAppendingString:g];
            blueHex = [b stringByAppendingString:b];
            alphaHex = [a stringByAppendingString:a];
            break;
        }
        case 6:
            redHex = [normalized substringWithRange:NSMakeRange(0, 2)];
            greenHex = [normalized substringWithRange:NSMakeRange(2, 2)];
            blueHex = [normalized substringWithRange:NSMakeRange(4, 2)];
            break;
        case 8:
            redHex = [normalized substringWithRange:NSMakeRange(0, 2)];
            greenHex = [normalized substringWithRange:NSMakeRange(2, 2)];
            blueHex = [normalized substringWithRange:NSMakeRange(4, 2)];
            alphaHex = [normalized substringWithRange:NSMakeRange(6, 2)];
            break;
        default:
            return nil;
    }

    CGFloat red = RCColorComponentFromHexPair(redHex);
    CGFloat green = RCColorComponentFromHexPair(greenHex);
    CGFloat blue = RCColorComponentFromHexPair(blueHex);
    CGFloat alpha = RCColorComponentFromHexPair(alphaHex);

    return [NSColor colorWithSRGBRed:red green:green blue:blue alpha:alpha];
}

+ (NSColor *)colorWithColorString:(NSString *)colorString {
    NSString *normalized = RCNormalizedColorCandidateString(colorString);
    if (normalized.length == 0 || normalized.length > kRCMaxColorStringLength) {
        return nil;
    }

    if ([self isValidHexColorString:normalized]) {
        return [self colorWithHexString:normalized];
    }

    CGFloat red = 0.0;
    CGFloat green = 0.0;
    CGFloat blue = 0.0;
    CGFloat alpha = 0.0;
    if (RCParseRGBAColorComponents(normalized, &red, &green, &blue, &alpha)
        || RCParseHSLAColorComponents(normalized, &red, &green, &blue, &alpha)) {
        return [NSColor colorWithSRGBRed:red green:green blue:blue alpha:alpha];
    }

    return nil;
}

- (NSString *)hexString {
    NSColor *srgbColor = [self colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (srgbColor == nil) {
        return nil;
    }

    CGFloat red = 0.0;
    CGFloat green = 0.0;
    CGFloat blue = 0.0;
    CGFloat alpha = 0.0;
    [srgbColor getRed:&red green:&green blue:&blue alpha:&alpha];

    NSUInteger redByte = (NSUInteger)lround(MAX(0.0, MIN(1.0, red)) * 255.0);
    NSUInteger greenByte = (NSUInteger)lround(MAX(0.0, MIN(1.0, green)) * 255.0);
    NSUInteger blueByte = (NSUInteger)lround(MAX(0.0, MIN(1.0, blue)) * 255.0);
    NSUInteger alphaByte = (NSUInteger)lround(MAX(0.0, MIN(1.0, alpha)) * 255.0);

    if (alphaByte < 255) {
        return [NSString stringWithFormat:@"#%02lX%02lX%02lX%02lX",
                (unsigned long)redByte,
                (unsigned long)greenByte,
                (unsigned long)blueByte,
                (unsigned long)alphaByte];
    }

    return [NSString stringWithFormat:@"#%02lX%02lX%02lX",
            (unsigned long)redByte,
            (unsigned long)greenByte,
            (unsigned long)blueByte];
}

+ (BOOL)isValidHexColorString:(NSString *)string {
    NSString *normalized = RCNormalizedHexColorString(string);
    if (normalized.length == 0 || normalized.length > kRCMaxColorStringLength) {
        return NO;
    }
    NSUInteger length = normalized.length;
    if (!(length == 3 || length == 4 || length == 6 || length == 8)) {
        return NO;
    }

    return RCIsHexCharactersOnly(normalized);
}

+ (BOOL)isValidColorString:(NSString *)string {
    return [self colorWithColorString:string] != nil;
}

+ (BOOL)isPotentialColorStringCandidate:(NSString *)string {
    NSString *trimmed = RCNormalizedColorCandidateString(string);
    if (trimmed.length == 0 || trimmed.length > kRCMaxColorStringLength) {
        return NO;
    }
    NSString *normalized = trimmed.lowercaseString;

    return RCIsPotentialHexColorCandidate(normalized)
        || [normalized hasPrefix:@"rgba("]
        || [normalized hasPrefix:@"hsla("];
}

@end
