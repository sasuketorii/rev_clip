#import "RCFastPreviewController.h"

@interface RCNonactivatingPreviewPanel : NSPanel
@end
@implementation RCNonactivatingPreviewPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface RCFastPreviewController ()
@property NSPanel *panel;
@property NSTimer *timer;
@end

@implementation RCFastPreviewController
- (void)dealloc { [_timer invalidate]; [_panel orderOut:nil]; }
- (void)hide {
    [self.timer invalidate];
    self.timer = nil;
    [self.panel orderOut:nil];
}
- (void)highlightItem:(NSMenuItem *)item text:(NSString *)text {
    [self hide];
    if (!item || item.hasSubmenu || !item.enabled || text.length == 0) return;
    // Bound layout work and avoid splitting emoji / composed characters.
    if (text.length > 2000) {
        NSRange range = [text rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 2000)];
        text = [[text substringWithRange:range] stringByAppendingString:@"…"];
    }
    __weak typeof(self) weakSelf = self;
    __weak NSMenuItem *weakItem = item;
    self.timer = [NSTimer timerWithTimeInterval:0.15 repeats:NO block:^(NSTimer *timer) {
        RCFastPreviewController *strongSelf = weakSelf;
        NSMenuItem *selected = weakItem;
        if (!strongSelf || !selected.menu || selected.menu.highlightedItem != selected) return;
        [strongSelf showText:text menu:selected.menu];
    }];
    // Menu tracking uses its own run-loop mode.
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSEventTrackingRunLoopMode];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}
- (void)showText:(NSString *)text menu:(NSMenu *)menu {
    if (!self.panel) {
        self.panel = [[RCNonactivatingPreviewPanel alloc] initWithContentRect:NSZeroRect
            styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
            backing:NSBackingStoreBuffered defer:NO];
        self.panel.ignoresMouseEvents = YES;
        self.panel.hidesOnDeactivate = NO;
        self.panel.releasedWhenClosed = NO;
        self.panel.hasShadow = YES;
        self.panel.opaque = NO;
        self.panel.backgroundColor = NSColor.clearColor;
        self.panel.level = NSPopUpMenuWindowLevel + 1;
        self.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    }
    NSPoint mouse = NSEvent.mouseLocation;
    NSScreen *screen = NSScreen.mainScreen;
    for (NSScreen *candidate in NSScreen.screens) if (NSPointInRect(mouse, candidate.frame)) { screen = candidate; break; }
    NSRect screenFrame = screen.visibleFrame;
    NSRect menuFrame = menu.accessibilityFrame;
    CGFloat width = MIN(NSIsEmptyRect(menuFrame) ? 300 : MAX(280, NSWidth(menuFrame)), NSWidth(screenFrame) - 24);
    NSDictionary *attributes = @{NSFontAttributeName:[NSFont systemFontOfSize:12]};
    NSRect textBounds = [text boundingRectWithSize:NSMakeSize(width - 24, CGFLOAT_MAX)
        options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading attributes:attributes];
    CGFloat height = MIN(MIN(360, NSHeight(screenFrame) - 24), ceil(NSHeight(textBounds)) + 24);
    // Keep the preview directly below its submenu, aligned to the leading edge.
    CGFloat x = NSIsEmptyRect(menuFrame) ? mouse.x : NSMinX(menuFrame);
    x = MAX(NSMinX(screenFrame) + 8, MIN(x, NSMaxX(screenFrame) - width - 8));
    CGFloat y = (NSIsEmptyRect(menuFrame) ? mouse.y : NSMinY(menuFrame)) - height - 8;
    if (y < NSMinY(screenFrame) + 8) {
        y = (NSIsEmptyRect(menuFrame) ? mouse.y : NSMaxY(menuFrame)) + 8;
    }
    y = MAX(NSMinY(screenFrame) + 8, MIN(y, NSMaxY(screenFrame) - height - 8));
    NSVisualEffectView *background = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
    background.material = NSVisualEffectMaterialMenu;
    background.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    background.state = NSVisualEffectStateActive;
    background.wantsLayer = YES;
    background.layer.cornerRadius = 8;
    background.layer.masksToBounds = YES;
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = attributes[NSFontAttributeName];
    label.textColor = NSColor.labelColor;
    label.frame = NSInsetRect(background.bounds, 12, 12);
    label.lineBreakMode = NSLineBreakByWordWrapping;
    [background addSubview:label];
    self.panel.appearance = menu.appearance;
    self.panel.contentView = background;
    [self.panel setFrame:NSMakeRect(x, y, width, height) display:NO];
    // Never activate, attach as a child, or take focus from the native menu.
    [self.panel orderFrontRegardless];
}
@end
