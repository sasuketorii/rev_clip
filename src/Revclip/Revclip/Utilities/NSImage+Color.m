//
//  NSImage+Color.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import "NSImage+Color.h"

@implementation NSImage (Color)

+ (NSImage *)imageWithColor:(NSColor *)color size:(NSSize)size {
    return [self imageWithColor:color size:size cornerRadius:0.0];
}

+ (NSImage *)imageWithColor:(NSColor *)color size:(NSSize)size cornerRadius:(CGFloat)radius {
    CGFloat width = MAX(size.width, 1.0);
    CGFloat height = MAX(size.height, 1.0);
    NSSize imageSize = NSMakeSize(width, height);

    NSImage *image = [NSImage imageWithSize:imageSize flipped:NO drawingHandler:^BOOL(NSRect dstRect) {
        [color setFill];

        CGFloat maxRadius = MIN(width, height) / 2.0;
        CGFloat clampedRadius = MAX(0.0, MIN(radius, maxRadius));
        if (clampedRadius > 0.0) {
            NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:dstRect xRadius:clampedRadius yRadius:clampedRadius];
            [path fill];
        } else {
            NSRectFill(dstRect);
        }

        return YES;
    }];

    return image;
}

@end
