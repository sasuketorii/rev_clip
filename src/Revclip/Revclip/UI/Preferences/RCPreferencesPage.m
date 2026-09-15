#import "RCPreferencesPage.h"

@implementation RCPreferencesSurface
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) { _cornerRadius = 12; }
    return self;
}
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; self.needsDisplay = YES; }
- (void)drawRect:(NSRect)dirtyRect {
    BOOL dark = [[self.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
    [[(dark ? NSColor.blackColor : NSColor.whiteColor) colorWithAlphaComponent:0.14] setFill];
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:self.cornerRadius yRadius:self.cornerRadius];
    [shape fill];
    if (self.drawsBorder) {
        [[NSColor.labelColor colorWithAlphaComponent:0.14] setStroke];
        shape.lineWidth = 1;
        [shape stroke];
    }
}
@end

@implementation RCPreferencesPage
- (BOOL)isFlipped { return YES; }

+ (NSSwitch *)switchForController:(NSViewController *)controller key:(NSString *)key {
    NSButton *old = [controller valueForKey:key];
    NSSwitch *control = [[NSSwitch alloc] initWithFrame:NSZeroRect];
    control.state = old.state;
    control.enabled = old.enabled;
    control.target = old.target;
    control.action = old.action;
    control.toolTip = old.toolTip;
    control.identifier = key;
    for (NSString *binding in @[NSValueBinding, NSEnabledBinding]) {
        NSDictionary *info = [old infoForBinding:binding];
        if (info) {
            [old unbind:binding];
            [control bind:binding toObject:info[NSObservedObjectKey]
              withKeyPath:info[NSObservedKeyPathKey] options:info[NSOptionsKey]];
        }
    }
    [controller setValue:control forKey:key];
    return control;
}

+ (instancetype)pageWithRows:(NSArray<NSArray *> *)rows {
    RCPreferencesPage *page = [[self alloc] initWithFrame:NSMakeRect(0, 0, 660, rows.count * 56 + 32)];
    NSStackView *stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    RCPreferencesSurface *surface = [[RCPreferencesSurface alloc] initWithFrame:NSZeroRect];
    surface.translatesAutoresizingMaskIntoConstraints = NO;
    [page addSubview:surface];
    [page addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [surface.leadingAnchor constraintEqualToAnchor:stack.leadingAnchor],
        [surface.trailingAnchor constraintEqualToAnchor:stack.trailingAnchor],
        [surface.topAnchor constraintEqualToAnchor:stack.topAnchor],
        [surface.bottomAnchor constraintEqualToAnchor:stack.bottomAnchor],
    ]];
    for (NSArray *entry in rows) {
        NSString *title = entry.firstObject;
        NSView *row = [[NSView alloc] initWithFrame:NSZeroRect];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        NSTextField *label = [NSTextField wrappingLabelWithString:title];
        label.font = [NSFont systemFontOfSize:13];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:label];
        NSStackView *controls = [[NSStackView alloc] initWithFrame:NSZeroRect];
        controls.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        controls.alignment = NSLayoutAttributeCenterY;
        controls.spacing = 8;
        controls.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:controls];
        for (NSView *control in [entry subarrayWithRange:NSMakeRange(1, entry.count - 1)]) {
            [control removeFromSuperview];
            control.translatesAutoresizingMaskIntoConstraints = NO;
            [controls addArrangedSubview:control];
            if ([NSStringFromClass(control.class) isEqualToString:@"RCHotKeyRecorderView"]) {
                [control.widthAnchor constraintEqualToConstant:180].active = YES;
                [control.heightAnchor constraintEqualToConstant:30].active = YES;
            }
            [control setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
            if ([control isKindOfClass:NSControl.class]) {
                [(NSControl *)control setControlSize:NSControlSizeRegular];
                [control setAccessibilityLabel:title];
            }
            if ([control isKindOfClass:NSTextField.class] && [(NSTextField *)control isEditable]) {
                for (NSLayoutConstraint *constraint in control.constraints) {
                    if (constraint.firstAttribute == NSLayoutAttributeWidth && constraint.secondItem == nil) { constraint.active = NO; }
                }
                [control.widthAnchor constraintEqualToConstant:[control isKindOfClass:RCPreferencesTextField.class] ? 200 : 64].active = YES;
            }
        }
        if (stack.arrangedSubviews.count > 0) {
            NSBox *divider = [[NSBox alloc] initWithFrame:NSZeroRect];
            divider.boxType = NSBoxSeparator;
            divider.translatesAutoresizingMaskIntoConstraints = NO;
            [row addSubview:divider];
            [NSLayoutConstraint activateConstraints:@[
                [divider.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
                [divider.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
                [divider.topAnchor constraintEqualToAnchor:row.topAnchor],
            ]];
        }
        [stack addArrangedSubview:row];
        [NSLayoutConstraint activateConstraints:@[
            [row.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
            [row.heightAnchor constraintGreaterThanOrEqualToConstant:56],
            [label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
            [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [label.topAnchor constraintGreaterThanOrEqualToAnchor:row.topAnchor constant:16],
            [label.bottomAnchor constraintLessThanOrEqualToAnchor:row.bottomAnchor constant:-16],
            (title.length == 0 ? [controls.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16] : [controls.leadingAnchor constraintGreaterThanOrEqualToAnchor:label.trailingAnchor constant:20]),
            [controls.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
            [controls.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [controls.topAnchor constraintGreaterThanOrEqualToAnchor:row.topAnchor constant:12],
            [controls.bottomAnchor constraintLessThanOrEqualToAnchor:row.bottomAnchor constant:-12],
        ]];
    }
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:page.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:page.trailingAnchor constant:-24],
        [stack.topAnchor constraintEqualToAnchor:page.topAnchor constant:8],
        [stack.bottomAnchor constraintEqualToAnchor:page.bottomAnchor constant:-24],
    ]];
    // Also provide a valid initial size to callers that embed the page without a scroll view.
    NSLayoutConstraint *measurementWidth = [page.widthAnchor constraintEqualToConstant:660];
    measurementWidth.active = YES;
    CGFloat height = ceil(page.fittingSize.height);
    measurementWidth.active = NO;
    [page setFrameSize:NSMakeSize(660, height)];
    return page;
}
@end

@interface RCPreferencesTextFieldCell : NSTextFieldCell
@end
@implementation RCPreferencesTextFieldCell
- (NSRect)drawingRectForBounds:(NSRect)rect {
    NSRect content = NSInsetRect(rect, 12, 0);
    CGFloat height = self.font.ascender - self.font.descender + 3;
    content.origin.y += (NSHeight(content) - height) / 2;
    content.size.height = height;
    return content;
}
- (void)selectWithFrame:(NSRect)rect inView:(NSView *)view editor:(NSText *)editor delegate:(id)delegate start:(NSInteger)start length:(NSInteger)length {
    [super selectWithFrame:[self drawingRectForBounds:rect] inView:view editor:editor delegate:delegate start:start length:length];
}
- (void)editWithFrame:(NSRect)rect inView:(NSView *)view editor:(NSText *)editor delegate:(id)delegate event:(NSEvent *)event {
    [super editWithFrame:[self drawingRectForBounds:rect] inView:view editor:editor delegate:delegate event:event];
}
@end
@implementation RCPreferencesTextField
+ (Class)cellClass { return RCPreferencesTextFieldCell.class; }
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) { self.bordered = NO; self.bezeled = NO; self.drawsBackground = NO; }
    return self;
}
- (void)drawRect:(NSRect)dirtyRect {
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:10 yRadius:10];
    [[NSColor.controlBackgroundColor colorWithAlphaComponent:0.35] setFill];
    [shape fill];
    [NSColor.separatorColor setStroke];
    shape.lineWidth = 1;
    [shape stroke];
    [super drawRect:dirtyRect];
}
@end
