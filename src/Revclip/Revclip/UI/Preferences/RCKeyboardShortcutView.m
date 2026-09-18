#import "RCKeyboardShortcutView.h"
#import "RCHotKeyRecorderView.h"

@implementation RCKeyboardShortcutView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _keyCombo = RCInvalidKeyCombo();
        self.accessibilityElement = YES;
        self.accessibilityRole = NSAccessibilityImageRole;
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (void)setKeyCombo:(RCKeyCombo)combo {
    if (_keyCombo.keyCode == combo.keyCode && _keyCombo.modifiers == combo.modifiers) return;
    _keyCombo = combo;
    self.accessibilityLabel = [RCHotKeyRecorderView displayStringForKeyCombo:combo];
    self.needsDisplay = YES;
}
- (NSSet<NSNumber *> *)highlightedKeyCodes {
    if (!RCIsValidKeyCombo(self.keyCombo)) return [NSSet set];
    NSMutableSet *keys = [NSMutableSet setWithObject:@(self.keyCombo.keyCode)];
    // Stored combinations do not distinguish left/right modifiers. Show the
    // left representative, matching the supplied illustration.
    if (self.keyCombo.modifiers & cmdKey) [keys addObject:@55];
    if (self.keyCombo.modifiers & shiftKey) [keys addObject:@56];
    if (self.keyCombo.modifiers & optionKey) [keys addObject:@58];
    if (self.keyCombo.modifiers & controlKey) [keys addObject:@59];
    return keys;
}
+ (NSRect)imageRectForKeyCode:(UInt32)keyCode {
    static NSDictionary<NSNumber *, NSValue *> *rects;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Coordinates in the unmodified 2546 x 1046 source image. No letter
        // translation: hotkey keyCodes identify physical key positions.
        NSMutableDictionary *map = [NSMutableDictionary dictionary];
        void (^row)(NSArray *, NSArray *, CGFloat, CGFloat) = ^(NSArray *codes, NSArray *edges, CGFloat y, CGFloat height) {
            for (NSUInteger i = 0; i < codes.count; i++) {
                NSArray *edge = edges[i];
                map[codes[i]] = [NSValue valueWithRect:NSMakeRect([edge[0] doubleValue], y,
                    [edge[1] doubleValue] - [edge[0] doubleValue], height)];
            }
        };
        row(@[@53,@122,@120,@99,@118,@96,@97,@98,@100,@101,@109,@103,@111],
            @[@[@33,@259],@[@268,@428],@[@437,@598],@[@607,@768],@[@777,@937],@[@946,@1107],@[@1117,@1280],@[@1289,@1454],@[@1464,@1631],@[@1641,@1810],@[@1819,@1986],@[@1995,@2160],@[@2169,@2334]],25,126);
        row(@[@50,@18,@19,@20,@21,@23,@22,@26,@28,@25,@29,@27,@24,@51],
            @[@[@33,@195],@[@204,@366],@[@375,@538],@[@547,@707],@[@717,@877],@[@887,@1048],@[@1058,@1221],@[@1230,@1392],@[@1402,@1565],@[@1574,@1736],@[@1745,@1907],@[@1916,@2081],@[@2090,@2251],@[@2260,@2507]],166,160);
        row(@[@48,@12,@13,@14,@15,@17,@16,@32,@34,@31,@35,@33,@30,@42],
            @[@[@33,@280],@[@291,@453],@[@463,@626],@[@636,@798],@[@809,@971],@[@981,@1143],@[@1153,@1315],@[@1325,@1487],@[@1497,@1659],@[@1668,@1830],@[@1840,@2002],@[@2013,@2174],@[@2185,@2346],@[@2355,@2507]],340,156);
        row(@[@57,@0,@1,@2,@3,@5,@4,@38,@40,@37,@41,@39,@36],
            @[@[@33,@328],@[@338,@499],@[@510,@673],@[@684,@847],@[@857,@1020],@[@1031,@1192],@[@1203,@1364],@[@1374,@1537],@[@1547,@1710],@[@1720,@1881],@[@1891,@2053],@[@2062,@2223],@[@2233,@2507]],510,156);
        row(@[@56,@6,@7,@8,@9,@11,@45,@46,@43,@47,@44,@60],
            @[@[@33,@411],@[@422,@585],@[@596,@760],@[@771,@934],@[@944,@1107],@[@1117,@1282],@[@1292,@1456],@[@1467,@1631],@[@1641,@1802],@[@1812,@1973],@[@1982,@2142],@[@2151,@2507]],679,156);
        row(@[@63,@59,@58,@55,@49,@54,@61],
            @[@[@33,@186],@[@196,@359],@[@369,@533],@[@543,@761],@[@772,@1624],@[@1633,@1844],@[@1855,@2022]],850,161);
        map[@123] = [NSValue valueWithRect:NSMakeRect(2031,923,151,88)];
        map[@126] = [NSValue valueWithRect:NSMakeRect(2192,850,153,80)];
        map[@125] = [NSValue valueWithRect:NSMakeRect(2192,936,153,75)];
        map[@124] = [NSValue valueWithRect:NSMakeRect(2354,923,153,88)];
        rects = [map copy];
    });
    NSValue *value = rects[@(keyCode)];
    return value ? value.rectValue : NSZeroRect;
}
- (void)drawRect:(NSRect)dirtyRect {
    static NSImage *keyboard;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *url = [NSBundle.mainBundle URLForResource:@"macbook_keyboard" withExtension:@"png"]
            ?: [NSBundle.mainBundle URLForResource:@"macbook_keyboard" withExtension:@"png" subdirectory:@"Keyboard"];
        if (url) keyboard = [[NSImage alloc] initWithContentsOfURL:url];
    });
    CGFloat scale = MIN(self.bounds.size.width / 2546.0, self.bounds.size.height / 1046.0);
    NSRect frame = NSMakeRect((self.bounds.size.width - 2546 * scale) / 2,
                             (self.bounds.size.height - 1046 * scale) / 2, 2546 * scale, 1046 * scale);
    [keyboard drawInRect:frame fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
               fraction:1 respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
    for (NSNumber *code in self.highlightedKeyCodes) {
        NSRect key = [RCKeyboardShortcutView imageRectForKeyCode:code.unsignedIntValue];
        if (NSIsEmptyRect(key)) continue; // External/numpad keys are named by the recorder, never mislabelled on the photo.
        key = NSMakeRect(frame.origin.x + key.origin.x * scale, frame.origin.y + key.origin.y * scale,
                         key.size.width * scale, key.size.height * scale);
        NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(key, 1, 1) xRadius:15 * scale yRadius:15 * scale];
        [NSGraphicsContext saveGraphicsState];
        NSShadow *glow = [NSShadow new];
        glow.shadowColor = [NSColor colorWithSRGBRed:0 green:0.45 blue:1 alpha:1];
        glow.shadowBlurRadius = 34 * scale; glow.shadowOffset = NSZeroSize; [glow set];
        [[NSColor colorWithSRGBRed:0 green:0.36 blue:1 alpha:0.22] setFill]; [path fill];
        [[NSColor colorWithSRGBRed:0.1 green:0.65 blue:1 alpha:1] setStroke]; path.lineWidth = 9 * scale; [path stroke];
        [NSGraphicsContext restoreGraphicsState];
        [[NSColor colorWithSRGBRed:0.62 green:0.9 blue:1 alpha:1] setStroke]; path.lineWidth = 3 * scale; [path stroke];
    }
}
@end
