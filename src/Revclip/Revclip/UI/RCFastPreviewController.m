#import "RCFastPreviewController.h"
#import "RCSnippetMedia.h"
#import "RCLinkPreviewService.h"

@interface RCNonactivatingPreviewPanel : NSPanel
@end
@implementation RCNonactivatingPreviewPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface RCFastPreviewController ()
@property NSPanel *panel;
@property NSTimer *timer;
@property NSUInteger generation;
@end

@implementation RCFastPreviewController
- (void)dealloc { [_timer invalidate]; [_panel orderOut:nil]; }
- (void)hide {
    self.generation += 1;
    [self.timer invalidate];
    self.timer = nil;
    [self.panel orderOut:nil];
}
- (void)highlightItem:(NSMenuItem *)item text:(NSString *)text {
    [self highlightItem:item text:text imageData:nil];
}
- (void)highlightItem:(NSMenuItem *)item text:(NSString *)text imageData:(NSData *)imageData {
    [self hide];
    if (!item || item.hasSubmenu || !item.enabled || (text.length == 0 && imageData.length == 0)) return;
    NSURL *linkURL = imageData.length ? nil : [RCLinkPreviewService URLForText:text];
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
        NSImage *image = imageData.length ? [RCSnippetMedia thumbnailForData:imageData size:360] : nil;
        if (imageData.length && !image) return;
        NSURL *url = linkURL;
        if (url) {
            NSUInteger generation = strongSelf.generation;
            [strongSelf showLinkURL:url title:selected.accessibilityLabel ?: selected.title image:nil menu:selected.menu];
            [[RCLinkPreviewService shared] imageForURL:url completion:^(NSImage *preview) {
                if (strongSelf.generation != generation || selected.menu.highlightedItem != selected) return;
                [strongSelf showLinkURL:url title:selected.accessibilityLabel ?: selected.title image:preview menu:selected.menu];
            }];
            return;
        }
        [strongSelf showText:text image:image menu:selected.menu];
    }];
    // Menu tracking uses its own run-loop mode.
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSEventTrackingRunLoopMode];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}
- (void)showText:(NSString *)text image:(NSImage *)image menu:(NSMenu *)menu {
    [self showText:text image:image menu:menu aspectRatio:0];
}
- (void)showLinkURL:(NSURL *)url title:(NSString *)title image:(NSImage *)image menu:(NSMenu *)menu {
    NSString *link = [url.scheme.lowercaseString isEqual:@"http"] ? [@"⚠️ " stringByAppendingString:url.absoluteString] : url.absoluteString;
    [self showText:url.host image:image menu:menu aspectRatio:16.0/9.0 caption:[NSString stringWithFormat:@"%@\n%@",title,link]];
}
- (void)showText:(NSString *)text image:(NSImage *)image menu:(NSMenu *)menu aspectRatio:(CGFloat)aspectRatio {
    [self showText:text image:image menu:menu aspectRatio:aspectRatio caption:nil];
}
- (void)showText:(NSString *)text image:(NSImage *)image menu:(NSMenu *)menu aspectRatio:(CGFloat)aspectRatio caption:(NSString *)caption {
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
    CGFloat width = MIN(NSIsEmptyRect(menuFrame) ? 300 : NSWidth(menuFrame), NSWidth(screenFrame) - 24);
    NSDictionary *attributes = @{NSFontAttributeName:[NSFont systemFontOfSize:12]};
    NSRect textBounds = [text boundingRectWithSize:NSMakeSize(width - 24, CGFLOAT_MAX)
        options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading attributes:attributes];
    CGFloat height = MIN(MIN(360, NSHeight(screenFrame) - 24), ceil(NSHeight(textBounds)) + 24);
    if (image) {
        CGFloat imageHeight = (width - 24) * image.size.height / MAX(1, image.size.width);
        height = MIN(MIN(360, NSHeight(screenFrame) - 24), imageHeight + 24);
    }
    if (aspectRatio > 0) height = width / aspectRatio;
    CGFloat captionHeight = caption.length ? 64 : 0;
    height += captionHeight;
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
    NSRect mediaFrame = NSMakeRect(0,captionHeight,width,height-captionHeight);
    if (image) {
        NSImageView *imageView = [[NSImageView alloc] initWithFrame:aspectRatio > 0 ? mediaFrame : NSInsetRect(mediaFrame, 12, 12)];
        imageView.image = image;
        imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
        imageView.imageAlignment = NSImageAlignCenter;
        [background addSubview:imageView];
    } else {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = attributes[NSFontAttributeName];
    label.textColor = NSColor.labelColor;
    label.frame = NSInsetRect(mediaFrame, 12, 12);
    label.lineBreakMode = NSLineBreakByWordWrapping;
    [background addSubview:label];
    }
    if (caption.length) {
        NSRange divider = [caption rangeOfString:@"\n" options:NSBackwardsSearch];
        NSString *title = [caption substringToIndex:divider.location];
        NSString *urlLine = [caption substringFromIndex:NSMaxRange(divider)];
        NSTextField *details = [NSTextField wrappingLabelWithString:title];
        details.font = [NSFont boldSystemFontOfSize:12];
        details.textColor = NSColor.labelColor;
        details.maximumNumberOfLines = 2;
        details.lineBreakMode = NSLineBreakByTruncatingTail;
        details.frame = NSMakeRect(12,26,width-24,30);
        [background addSubview:details];
        NSTextField *link = [NSTextField labelWithString:urlLine];
        link.font = [NSFont systemFontOfSize:11];
        link.textColor = NSColor.secondaryLabelColor;
        link.lineBreakMode = NSLineBreakByTruncatingMiddle;
        link.frame = NSMakeRect(12,8,width-24,16);
        [background addSubview:link];
    }
    self.panel.appearance = menu.appearance;
    self.panel.contentView = background;
    [self.panel setFrame:NSMakeRect(x, y, width, height) display:NO];
    // Never activate, attach as a child, or take focus from the native menu.
    if (!self.panel.visible) [self.panel orderFrontRegardless];
}
@end
