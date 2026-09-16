//
//  NSColor+HexString.h
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Current project: AGPL-3.0-only; legacy portions: MIT. See THIRD_PARTY_NOTICES.md.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSColor (HexString)

+ (nullable NSColor *)colorWithHexString:(NSString *)hexString;
+ (nullable NSColor *)colorWithColorString:(NSString *)colorString;
- (nullable NSString *)hexString;
+ (BOOL)isValidHexColorString:(NSString *)string;
+ (BOOL)isValidColorString:(NSString *)string;
+ (BOOL)isPotentialColorStringCandidate:(NSString *)string;

@end

NS_ASSUME_NONNULL_END
