#import "RCGlassBackground.h"
@implementation RCGlassBackground
+ (NSView *)wrapContent:(NSView *)content {
    NSVisualEffectView *shell = [[NSVisualEffectView alloc] initWithFrame:content.frame];
    shell.material = NSVisualEffectMaterialHUDWindow;
    shell.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    shell.state = NSVisualEffectStateActive;
    shell.wantsLayer = YES;
    shell.layer.cornerRadius = 24;
    shell.layer.masksToBounds = YES;
    if (@available(macOS 26.0, *)) {
        NSGlassEffectView *glass = [[NSGlassEffectView alloc] initWithFrame:content.frame];
        glass.style = NSGlassEffectViewStyleClear;
        glass.cornerRadius = 24;
        glass.contentView = content;
        glass.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [shell addSubview:glass];
    } else {
        content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [shell addSubview:content];
    }
    return shell;
}
@end
