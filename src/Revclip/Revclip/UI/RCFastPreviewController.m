#import "RCFastPreviewController.h"
#import "RCSnippetMedia.h"
#import "RCLinkPreviewService.h"
#import "RCSVGPreview.h"
#import "RCMenuStyle.h"
#import "RCLocalization.h"

@interface RCNonactivatingPreviewPanel : NSPanel
@end
@implementation RCNonactivatingPreviewPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface RCFastPreviewController ()
@property NSPanel *panel;
@property (nonatomic, copy) NSString *linkRequestStatus;
@property (weak) NSMenuItem *linkItem;
@property NSURL *linkURL;
@property RCLinkPreviewMode observedLinkMode;
@property NSTimer *timer;
@property (nonatomic, strong) NSTimer *linkModifierTimer;
@property BOOL linkOptionWasDown;
@property NSUInteger generation;
@property NSOperationQueue *svgQueue;
@property NSBlockOperation *svgOperation;
@property NSBlockOperation *pendingSVGOperation;
@end

@implementation RCFastPreviewController
- (instancetype)init {
    if ((self = [super init])) {
        _observedLinkMode = RCLinkPreviewService.shared.previewMode;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(linkPolicyChanged:) name:NSUserDefaultsDidChangeNotification object:nil];
    }
    return self;
}
- (void)linkPolicyChanged:(NSNotification *)notification {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self linkPolicyChanged:nil]; }); return; }
    RCLinkPreviewMode mode = RCLinkPreviewService.shared.previewMode;
    if (mode != self.observedLinkMode) { self.observedLinkMode = mode; [self hide]; }
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_linkModifierTimer invalidate];
    [_timer invalidate]; [_svgQueue cancelAllOperations]; [_pendingSVGOperation cancel]; [_panel orderOut:nil];
}
- (void)hide {
    [self.linkModifierTimer invalidate]; self.linkModifierTimer = nil;
    self.linkItem = nil; self.linkURL = nil; self.linkRequestStatus = nil;
    self.generation += 1;
    [self.svgQueue cancelAllOperations];
    [self.pendingSVGOperation cancel];
    self.pendingSVGOperation = nil;
    [self.timer invalidate];
    self.timer = nil;
    [self.panel orderOut:nil];
    self.panel.contentView = nil;
}
- (void)highlightItem:(NSMenuItem *)item text:(NSString *)text {
    [self highlightItem:item text:text imageData:nil];
}
- (void)highlightItem:(NSMenuItem *)item text:(NSString *)text imageData:(NSData *)imageData {
    [self hide];
    if (!item || item.hasSubmenu || !item.enabled || (text.length == 0 && imageData.length == 0)) return;
    // Snapshot bounded standalone code before the display-only 2,000-character truncation.
    NSString *svg = !imageData.length && [RCSVGPreview isCandidateString:text] ? [text copy] : nil;
    if (svg) text = svg; // Keep fallback tied to the same immutable clipboard snapshot.
    NSURL *linkURL = imageData.length || svg ? nil : [RCLinkPreviewService URLForText:text];
    // Bound layout work and avoid splitting emoji / composed characters.
    if (text.length > 2000) {
        NSRange range = [text rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 2000)];
        text = [[text substringWithRange:range] stringByAppendingString:@"…"];
    }
    // Capture explicit intent at hover entry. NSMenu's native tracking loop
    // does not reliably dispatch keyDown through local NSEvent monitors.
    NSEventModifierFlags modifiers = [self previewModifierFlags] &
        (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagShift);
    BOOL requestedByHover = modifiers == NSEventModifierFlagOption;
    NSUInteger scheduledGeneration = self.generation;
    __weak typeof(self) weakSelf = self;
    __weak NSMenuItem *weakItem = item;
    self.timer = [NSTimer timerWithTimeInterval:0.15 repeats:NO block:^(NSTimer *timer) {
        RCFastPreviewController *strongSelf = weakSelf;
        NSMenuItem *selected = weakItem;
        if (!strongSelf || strongSelf.generation != scheduledGeneration || !selected.menu || selected.menu.highlightedItem != selected) return;
        strongSelf.timer = nil;
        if (svg) {
            [strongSelf enqueueSVG:svg fallbackText:text item:selected generation:scheduledGeneration];
            return;
        }
        NSImage *image = imageData.length ? [RCSnippetMedia thumbnailForData:imageData size:360] : nil;
        if (imageData.length && !image) return;
        NSURL *url = linkURL;
        if (url) {
            strongSelf.linkItem = selected;
            strongSelf.linkURL = url;
            NSUInteger generation = strongSelf.generation;
            [strongSelf showLinkURL:url title:selected.accessibilityLabel ?: selected.title image:nil menu:selected.menu];
            if (RCLinkPreviewService.shared.previewMode == RCLinkPreviewModeManual) {
                strongSelf.linkOptionWasDown = requestedByHover;
                [strongSelf startLinkModifierObservation];
            }
            if (requestedByHover && RCLinkPreviewService.shared.previewMode == RCLinkPreviewModeManual) {
                [strongSelf requestLinkPreview];
                return;
            }
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
// Call on main: custom normal text matches the existing row palette; dynamic fallback
// resolves under the panel/menu appearance. Selected-row white is wrong on light menu material.
- (NSColor *)SVGColorForMenu:(NSMenu *)menu {
    NSAppearance *appearance = menu.appearance ?: NSApp.effectiveAppearance;
    __block NSColor *resolved;
    [appearance performAsCurrentDrawingAppearance:^{
        NSColor *normal = [RCMenuStyle isEnabled] ? [RCMenuStyle colorForKey:@"text"] : nil;
        resolved = [(normal ?: NSColor.labelColor) colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    }];
    return resolved;
}
- (NSImage *)renderSVG:(NSString *)svg color:(NSColor *)color size:(CGFloat)size {
    return [RCSVGPreview imageForString:svg color:color size:size];
}
- (void)enqueueSVG:(NSString *)svg fallbackText:(NSString *)text item:(NSMenuItem *)item generation:(NSUInteger)generation {
    NSColor *color = [self SVGColorForMenu:item.menu];
    if (!color) { [self showText:text image:nil menu:item.menu]; return; }
    if (!self.svgQueue) {
        self.svgQueue = [NSOperationQueue new];
        self.svgQueue.name = @"com.revclip.svg-hover";
        self.svgQueue.qualityOfService = NSQualityOfServiceUserInitiated;
        self.svgQueue.maxConcurrentOperationCount = 1;
    }
    __weak typeof(self) weakSelf = self;
    __weak NSMenuItem *weakItem = item;
    __weak NSMenu *weakMenu = item.menu;
    NSBlockOperation *operation = [NSBlockOperation new];
    __weak NSBlockOperation *weakOperation = operation;
    __block NSImage *image;
    [operation addExecutionBlock:^{
        @autoreleasepool {
            if (weakOperation.cancelled) return;
            image = [weakSelf renderSVG:svg color:color size:720];
        }
    }];
    operation.completionBlock = ^{
        NSBlockOperation *finished = weakOperation;
        // Deliver on main in either normal or native tracking mode, then wake the run loop.
        CFRunLoopPerformBlock(CFRunLoopGetMain(), (__bridge CFArrayRef)@[NSRunLoopCommonModes, NSEventTrackingRunLoopMode], ^{
            RCFastPreviewController *owner = weakSelf;
            if (!owner || owner.svgOperation != finished) return;
            owner.svgOperation = nil;
            NSMenuItem *selected = weakItem;
            NSMenu *menu = weakMenu;
            if (!finished.cancelled && owner.generation == generation && menu &&
                selected.menu == menu && menu.highlightedItem == selected && selected.enabled) {
                // If appearance/preferences changed during decode, use readable text until the next hover.
                NSImage *currentImage = [color isEqual:[owner SVGColorForMenu:menu]] ? image : nil;
                [owner showText:text image:currentImage menu:menu];
            }
            NSBlockOperation *next = owner.pendingSVGOperation;
            owner.pendingSVGOperation = nil;
            if (next && !next.cancelled) {
                owner.svgOperation = next;
                [owner.svgQueue addOperation:next];
            }
        });
        CFRunLoopWakeUp(CFRunLoopGetMain());
    };
    // A running native decode cannot be interrupted. Keep at most one operation in
    // the queue and one replaceable pending request, even across rapid hover changes.
    if (self.svgOperation) {
        [self.pendingSVGOperation cancel];
        self.pendingSVGOperation = operation;
    } else {
        self.svgOperation = operation;
        [self.svgQueue addOperation:operation];
    }
}
- (void)showText:(NSString *)text image:(NSImage *)image menu:(NSMenu *)menu {
    [self showText:text image:image menu:menu aspectRatio:0];
}
- (NSEventModifierFlags)previewModifierFlags { return NSEvent.modifierFlags; }
// Native menu tracking can bypass NSEvent monitors. Read modifier state only
// while a manual link card is visible; no global monitor or idle polling.
- (void)startLinkModifierObservation {
    [self.linkModifierTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.linkModifierTimer = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
        [weakSelf pollLinkPreviewModifiers];
    }];
    self.linkModifierTimer.tolerance = 0.02;
    [NSRunLoop.mainRunLoop addTimer:self.linkModifierTimer forMode:NSEventTrackingRunLoopMode];
    [NSRunLoop.mainRunLoop addTimer:self.linkModifierTimer forMode:NSRunLoopCommonModes];
}
- (void)pollLinkPreviewModifiers {
    if (!self.panel.isVisible || !self.linkItem.menu || self.linkItem.menu.highlightedItem != self.linkItem ||
        RCLinkPreviewService.shared.previewMode != RCLinkPreviewModeManual) {
        [self.linkModifierTimer invalidate]; self.linkModifierTimer = nil; return;
    }
    NSEventModifierFlags flags = [self previewModifierFlags] &
        (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagShift);
    BOOL optionDown = flags == NSEventModifierFlagOption;
    BOOL pressed = optionDown && !self.linkOptionWasDown;
    self.linkOptionWasDown = optionDown;
    if (pressed) [self requestLinkPreview];
}
- (void)requestLinkPreview {
    NSMenuItem *item = self.linkItem;
    NSURL *url = self.linkURL;
    if (!url || !item.menu || item.menu.highlightedItem != item) return;
    NSUInteger generation = self.generation;
    __weak typeof(self) weakSelf = self;
    __weak NSMenuItem *weakItem = item;
    self.linkRequestStatus = RCLocalizedString(@"Fetching preview…", nil);
    [self showLinkURL:url title:item.accessibilityLabel ?: item.title image:nil menu:item.menu];
    [[RCLinkPreviewService shared] assetsForURL:url userInitiated:YES completion:^(RCLinkPreviewAssets *assets) {
        RCFastPreviewController *owner = weakSelf; NSMenuItem *row = weakItem;
        if (!owner || owner.generation != generation || !row.menu || row.menu.highlightedItem != row) return;
        owner.linkRequestStatus = assets.image ? nil : RCLocalizedString(@"No preview available. Try again in a minute.", nil);
        [owner showLinkURL:url title:row.accessibilityLabel ?: row.title image:assets.image menu:row.menu];
    }];
}
- (void)showLinkURL:(NSURL *)url title:(NSString *)title image:(NSImage *)image menu:(NSMenu *)menu {
    NSString *link = [url.scheme.lowercaseString isEqual:@"http"] ? [@"⚠️ " stringByAppendingString:url.absoluteString] : url.absoluteString;
    NSString *body = url.host;
    if (!image && RCLinkPreviewService.shared.previewMode == RCLinkPreviewModeManual) {
        body = [NSString stringWithFormat:@"%@\n\n%@", url.host, self.linkRequestStatus ?: RCLocalizedString(@"Press Option to fetch this link preview (connects to website)", nil)];
    } else if (!image && RCLinkPreviewService.shared.previewMode == RCLinkPreviewModeDisabled) {
        body = [NSString stringWithFormat:@"%@\n\n%@", url.host, RCLocalizedString(@"Online previews are disabled", nil)];
    }
    [self showText:body image:image menu:menu aspectRatio:16.0/9.0 caption:[NSString stringWithFormat:@"%@\n%@",title,link]];
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
        self.panel.animationBehavior = NSWindowAnimationBehaviorNone;
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
    // Paint the new content before ordering the reused panel front. Its backing
    // store must not expose pixels from the previously highlighted image.
    [self.panel.contentView layoutSubtreeIfNeeded];
    [self.panel displayIfNeeded];
    // Never activate, attach as a child, or take focus from the native menu.
    if (!self.panel.visible) [self.panel orderFrontRegardless];
}
@end
