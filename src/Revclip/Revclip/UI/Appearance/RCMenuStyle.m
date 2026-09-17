#import "RCHotKeyRecorderView.h"
#import "RCMenuStyle.h"

@interface RCStyledMenuRow : NSView
@property(nonatomic, weak) NSMenuItem *item;
@property(nonatomic, strong) NSImage *tintedImage;
@property(nonatomic, strong) NSImage *sourceImage;
@property(nonatomic, strong) NSColor *tintColor;
@property(nonatomic, strong) NSColor *arrowColor;
@property(nonatomic, strong) NSImage *arrowImage;
@end
static BOOL (^RCMenuStyleSelectionInterceptor)(NSMenuItem *);

@implementation RCStyledMenuRow
- (BOOL)isFlipped { return YES; }
// Submenu tracking stays native; leaf views explicitly dispatch their existing action.
- (NSView *)hitTest:(NSPoint)point { return self.item.hasSubmenu || self.item.isSeparatorItem ? nil : [super hitTest:point]; }
- (BOOL)activateItem {
    NSMenuItem *item = self.item;
    if (!item.enabled || item.hasSubmenu || !item.action) { return NO; }
    BOOL (^interceptor)(NSMenuItem *) = RCMenuStyleSelectionInterceptor;
    if (interceptor != nil && interceptor(item)) { [item.menu cancelTracking]; return YES; }
    [item.menu cancelTracking];
    dispatch_async(dispatch_get_main_queue(), ^{ [NSApp sendAction:item.action to:item.target from:item]; });
    return YES;
}
- (void)mouseDown:(NSEvent *)event { /* Activate only after release inside the row. */ }
- (void)mouseUp:(NSEvent *)event {
    if (NSPointInRect([self convertPoint:event.locationInWindow fromView:nil], self.bounds)) { [self activateItem]; }
}
- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityRole { return NSAccessibilityMenuItemRole; }
- (NSString *)accessibilityLabel { return self.item.accessibilityLabel ?: self.item.title; }
- (BOOL)accessibilityPerformPress { return [self activateItem]; }
- (void)drawRect:(NSRect)dirtyRect {
    NSMenuItem *item = self.item;
    BOOL highlighted = item.isHighlighted && item.isEnabled;
    NSColor *background = [RCMenuStyle colorForKey:highlighted ? @"hoverBackground" : @"background"];
    if (highlighted && !background) { background = NSColor.selectedContentBackgroundColor; }
    // The unchanged default uses AppKit's material, including its edge padding.
    NSString *normalHex = [NSUserDefaults.standardUserDefaults dictionaryForKey:RCMenuStyle.paletteKey][@"background"];
    NSString *defaultHex = [RCMenuStyle.paletteKey isEqualToString:@"RCMenuCustomColorsLight"] ? @"#F2F2F2" : @"#171717";
    if (!highlighted && [normalHex.uppercaseString isEqualToString:defaultHex]) { background = nil; }
    if (background) {
        [[background colorWithAlphaComponent:highlighted ? 0.85 : 0.14] setFill];
        if (highlighted) {
            [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 2, 0) xRadius:7 yRadius:7] fill];
        } else { NSRectFill(self.bounds); }
    }
    if (item.isSeparatorItem) {
        [NSColor.separatorColor setStroke];
        NSBezierPath *line = [NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(16, NSMidY(self.bounds))];
        [line lineToPoint:NSMakePoint(NSWidth(self.bounds)-16, NSMidY(self.bounds))];
        [line stroke];
        return;
    }
    NSColor *text = [RCMenuStyle colorForKey:highlighted ? @"hoverText" : @"text"] ?: (highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor);
    if (!item.isEnabled) { text = [text colorWithAlphaComponent:0.4]; }
    NSFont *font = [NSFont menuFontOfSize:0];
    NSImage *image = item.image;
    if (image.isTemplate) {
        NSColor *tint = highlighted ? text : ([RCMenuStyle colorForKey:@"primary"] ?: NSColor.controlAccentColor);
        if (self.sourceImage != image || ![self.tintColor isEqual:tint]) {
            self.sourceImage = image;
            self.tintColor = tint;
            NSImage *source = image;
            self.tintedImage = [NSImage imageWithSize:image.size flipped:NO drawingHandler:^BOOL(NSRect rect) {
                [source drawInRect:rect];
                [tint setFill];
                NSRectFillUsingOperation(rect, NSCompositingOperationSourceIn);
                return YES;
            }];
        }
        image = self.tintedImage;
    }
    BOOL historyRow = [NSStringFromSelector(item.action) isEqualToString:@"selectClipMenuItem:"];
    CGFloat imageWidth = image ? MIN(56, image.size.width) : 0;
    CGFloat imageSlot = historyRow ? 56 : imageWidth;
    CGFloat leading = 16;
    if (image) {
        CGFloat scale = MIN(1, MIN(56 / MAX(1,image.size.width),32 / MAX(1,image.size.height)));
        NSSize size = NSMakeSize(image.size.width*scale,image.size.height*scale);
        NSRect rect = NSMakeRect(leading,(NSHeight(self.bounds)-size.height)/2,size.width,size.height);
        [image drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:item.enabled ? 1 : 0.4 respectFlipped:YES hints:nil];
    }
    if (imageSlot) { leading += imageSlot + 8; }
    NSDictionary *attributes = @{NSFontAttributeName:font, NSForegroundColorAttributeName:text};
    CGFloat height = [item.title sizeWithAttributes:attributes].height;
    NSString *shortcut = [RCHotKeyRecorderView displayStringForKeyEquivalent:item.keyEquivalent modifiers:item.keyEquivalentModifierMask];
    CGFloat trailingWidth = item.hasSubmenu ? 32 : shortcut.length ? [shortcut sizeWithAttributes:attributes].width + 24 : 16;
    [item.title drawInRect:NSMakeRect(leading,(NSHeight(self.bounds)-height)/2,NSWidth(self.bounds)-leading-trailingWidth,height) withAttributes:attributes];
    if (item.hasSubmenu) {
        if (![self.arrowColor isEqual:text]) {
            self.arrowColor = text;
            NSImage *symbol = [NSImage imageWithSystemSymbolName:@"chevron.right" accessibilityDescription:nil];
            NSImageSymbolConfiguration *configuration = [[NSImageSymbolConfiguration configurationWithPointSize:10 weight:NSFontWeightSemibold] configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[text]]];
            self.arrowImage = [symbol imageWithSymbolConfiguration:configuration];
        }
        [self.arrowImage drawInRect:NSMakeRect(NSWidth(self.bounds)-20,(NSHeight(self.bounds)-10)/2,6,10) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    } else if (item.keyEquivalent.length) {
        NSString *key = shortcut;
        [key drawAtPoint:NSMakePoint(NSWidth(self.bounds)-[key sizeWithAttributes:attributes].width-12,(NSHeight(self.bounds)-height)/2) withAttributes:attributes];
    }
}
@end
@implementation RCMenuStyle
+ (BOOL)isEnabled { return [NSUserDefaults.standardUserDefaults boolForKey:@"RCMenuCustomColorsEnabled"]; }
+ (NSString *)paletteKey {
    BOOL dark = [[NSApp.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
    return dark ? @"RCMenuCustomColors" : @"RCMenuCustomColorsLight";
}
+ (NSColor *)colorForKey:(NSString *)key {
    id raw = [NSUserDefaults.standardUserDefaults dictionaryForKey:self.paletteKey][key];
    if (![raw isKindOfClass:NSString.class]) { return nil; }
    NSString *hex = raw;
    if (hex.length != 7 || ![hex hasPrefix:@"#"]) { return nil; }
    NSString *digits = [hex substringFromIndex:1];
    if ([digits rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet]].location != NSNotFound) { return nil; }
    unsigned int value = 0;
    if (![[NSScanner scannerWithString:digits] scanHexInt:&value]) { return nil; }
    return [NSColor colorWithSRGBRed:((value>>16)&255)/255.0 green:((value>>8)&255)/255.0 blue:(value&255)/255.0 alpha:1];
}
+ (void)applyToItem:(NSMenuItem *)item {
    if (![self isEnabled]) {
        if ([item.view isKindOfClass:RCStyledMenuRow.class]) { item.view = nil; }
        return;
    }
    RCStyledMenuRow *row = [item.view isKindOfClass:RCStyledMenuRow.class] ? (id)item.view : nil;
    if (!row) {
        NSSize textSize = [item.title sizeWithAttributes:@{NSFontAttributeName:[NSFont menuFontOfSize:0]}];
        BOOL historyRow = [NSStringFromSelector(item.action) isEqualToString:@"selectClipMenuItem:"];
        CGFloat width = MIN(560, MAX(220, textSize.width + (historyRow ? 64 : item.image ? MIN(56,item.image.size.width)+8 : 0) + (item.hasSubmenu || item.keyEquivalent.length ? 48 : 32)));
        row = [[RCStyledMenuRow alloc] initWithFrame:NSMakeRect(0,0,width,item.isSeparatorItem ? 12 : MAX(historyRow ? 42 : 28,MAX(textSize.height+10,item.image ? MIN(32,item.image.size.height)+10 : 0)))];
        row.autoresizingMask = NSViewWidthSizable;
        row.item = item;
        item.view = row;
    }
    row.needsDisplay = YES;
}
+ (void)setSelectionInterceptor:(BOOL (^)(NSMenuItem *))interceptor {
    RCMenuStyleSelectionInterceptor = [interceptor copy];
}
+ (void)refreshMenu:(NSMenu *)menu {
    for (NSMenuItem *item in menu.itemArray) { [self applyToItem:item]; }
}
@end
