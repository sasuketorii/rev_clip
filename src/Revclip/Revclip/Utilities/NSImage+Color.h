//
//  NSImage+Color.h
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSImage (Color)

+ (NSImage *)imageWithColor:(NSColor *)color size:(NSSize)size;
+ (NSImage *)imageWithColor:(NSColor *)color size:(NSSize)size cornerRadius:(CGFloat)radius;

@end

NS_ASSUME_NONNULL_END
