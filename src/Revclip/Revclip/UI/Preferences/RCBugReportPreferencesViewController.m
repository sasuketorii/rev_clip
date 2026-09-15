#import "RCBugReportPreferencesViewController.h"
#import "RCPreferencesPage.h"
#import "RCLocalization.h"
#import "RCBugReportService.h"

@interface RCBugReportDocument : NSView
@end
@implementation RCBugReportDocument
- (BOOL)isFlipped { return YES; }
@end

// Reuse the preferences input's rounded background and border for a multiline editor.
@interface RCBugReportTextAreaSurface : RCPreferencesTextField
@property (nonatomic, weak) NSTextView *editor;
@end
@implementation RCBugReportTextAreaSurface
- (BOOL)isAccessibilityElement { return NO; }
- (NSArray *)accessibilityChildren {
    // This NSTextField is decoration only. Expose the native scroll area/editor,
    // rather than inheriting a static-text leaf that hides the editable child.
    NSScrollView *scroll = self.editor.enclosingScrollView;
    return scroll ? @[scroll] : @[];
}
- (NSArray *)accessibilityChildrenInNavigationOrder { return self.accessibilityChildren; }
- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    if (self.window.isKeyWindow && self.window.firstResponder == self.editor && self.editor.editable) {
        [NSColor.keyboardFocusIndicatorColor setStroke];
        NSBezierPath *ring = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 1.5, 1.5) xRadius:9 yRadius:9];
        ring.lineWidth = 2;
        [ring stroke];
    }
}
- (void)mouseDown:(NSEvent *)event { [self.window makeFirstResponder:self.editor]; }
@end

@interface RCBugReportTextView : NSTextView
@end
@implementation RCBugReportTextView
- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityRole { return NSAccessibilityTextAreaRole; }
- (BOOL)becomeFirstResponder {
    BOOL accepted = [super becomeFirstResponder];
    self.enclosingScrollView.superview.needsDisplay = YES;
    return accepted;
}
- (BOOL)resignFirstResponder {
    BOOL accepted = [super resignFirstResponder];
    self.enclosingScrollView.superview.needsDisplay = YES;
    return accepted;
}
@end

@interface RCBugReportConsentCheckbox : NSButton
@end
@implementation RCBugReportConsentCheckbox
- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityRole { return NSAccessibilityCheckBoxRole; }
- (NSNumber *)accessibilityValue { return @(self.state); }
- (BOOL)isAccessibilityEnabled { return self.enabled; }
- (BOOL)accessibilityPerformPress {
    if (!self.enabled) { return NO; }
    [self performClick:nil];
    return YES;
}
@end

@interface RCBugReportSendButton : NSButton
@end
@implementation RCBugReportSendButton
- (BOOL)allowsVibrancy { return NO; }
- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityRole { return NSAccessibilityButtonRole; }
- (NSString *)accessibilityLabel { return self.title; }
- (BOOL)isAccessibilityEnabled { return self.enabled; }
- (BOOL)accessibilityPerformPress {
    if (!self.enabled) { return NO; }
    [self performClick:nil];
    return YES;
}
- (NSSize)intrinsicContentSize {
    NSSize textSize = [self.title sizeWithAttributes:@{NSFontAttributeName: self.font ?: [NSFont systemFontOfSize:13]}];
    return NSMakeSize(MAX(120, ceil(textSize.width) + 40), 36);
}
- (void)setTitle:(NSString *)title {
    [super setTitle:title];
    [self invalidateIntrinsicContentSize];
    self.needsDisplay = YES;
}
- (void)setEnabled:(BOOL)enabled { [super setEnabled:enabled]; self.needsDisplay = YES; }
- (void)highlight:(BOOL)flag { [super highlight:flag]; self.needsDisplay = YES; }
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; self.needsDisplay = YES; }
- (NSRect)focusRingMaskBounds { return self.bounds; }
- (void)drawFocusRingMask {
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:NSHeight(self.bounds) / 2 yRadius:NSHeight(self.bounds) / 2] fill];
}
- (void)drawRect:(NSRect)dirtyRect {
    NSColor *fill = self.enabled ? [NSColor colorWithSRGBRed:0 green:127.0 / 255.0 blue:1 alpha:1] : NSColor.quaternaryLabelColor;
    if (self.enabled && self.cell.isHighlighted) { fill = [fill blendedColorWithFraction:0.12 ofColor:NSColor.blackColor]; }
    [fill setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:NSHeight(self.bounds) / 2 yRadius:NSHeight(self.bounds) / 2] fill];
    NSDictionary *attributes = @{NSFontAttributeName: self.font ?: [NSFont systemFontOfSize:13],
                                NSForegroundColorAttributeName: self.enabled ? NSColor.whiteColor : NSColor.secondaryLabelColor};
    NSSize textSize = [self.title sizeWithAttributes:attributes];
    [self.title drawInRect:NSMakeRect((NSWidth(self.bounds) - textSize.width) / 2,
                                    (NSHeight(self.bounds) - textSize.height) / 2, textSize.width, textSize.height)
           withAttributes:attributes];
}
@end

@interface RCBugReportPreferencesViewController () <NSTextFieldDelegate, NSTextViewDelegate>
@property (nonatomic, strong) NSTextField *titleField;
@property (nonatomic, strong) NSTextView *descriptionField;
@property (nonatomic, strong) RCBugReportTextAreaSurface *descriptionSurface;
@property (nonatomic, strong) NSTextField *contactField;
@property (nonatomic, strong) NSButton *consentCheckbox;
@property (nonatomic, strong) NSTextField *metadataLabel;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSButton *sendButton;
@property (nonatomic, strong) NSProgressIndicator *progress;
@property (nonatomic, strong) NSMapTable<NSTextField *, NSString *> *localizedLabels;
@property (nonatomic, copy) NSString *statusKey;
@property (nonatomic) BOOL inFlight;
@property (nonatomic) BOOL displaysServiceDraft;
@end

@implementation RCBugReportPreferencesViewController
- (RCBugReportService *)reportService { return RCBugReportService.shared; }
- (void)loadView {
    self.view = [[RCBugReportDocument alloc] initWithFrame:NSMakeRect(0, 0, 660, 760)];
    self.localizedLabels = [NSMapTable strongToStrongObjectsMapTable];
    NSStackView *stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    RCPreferencesSurface *surface = [[RCPreferencesSurface alloc] initWithFrame:NSZeroRect];
    surface.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:surface];
    [surface addSubview:stack];
    NSLayoutConstraint *fillWidth = [surface.widthAnchor constraintEqualToAnchor:self.view.widthAnchor constant:-48];
    fillWidth.priority = NSLayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [surface.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:8],
        [surface.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [surface.widthAnchor constraintLessThanOrEqualToConstant:680],
        [surface.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor constant:-48], fillWidth,
        [surface.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-24],
        [stack.leadingAnchor constraintEqualToAnchor:surface.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:surface.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:surface.topAnchor constant:16],
        [stack.bottomAnchor constraintEqualToAnchor:surface.bottomAnchor constant:-16],
    ]];
    [self addView:[self labelForKey:@"Describe a problem with Revclip. Your report is sent to the support team via Telegram."] toStack:stack];
    [self addView:[self labelForKey:@"With your consent, the server collects your source IP address, approximate location, and network provider (ASN). Your report also includes the app and macOS versions, language, and time zone. Clipboard contents, history, and logs are not collected."] toStack:stack];
    [self addView:[self labelForKey:@"Title (required, up to 120 characters)"] toStack:stack];
    self.titleField = [self inputField];
    self.titleField.identifier = @"bugReportTitle";
    [self addView:self.titleField toStack:stack];
    [self addView:[self labelForKey:@"Description (required, up to 2,500 characters)"] toStack:stack];
    NSScrollView *descriptionScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 580, 140)];
    descriptionScroll.hasVerticalScroller = YES;
    descriptionScroll.autohidesScrollers = YES;
    descriptionScroll.drawsBackground = NO;
    descriptionScroll.borderType = NSNoBorder;
    self.descriptionField = [[RCBugReportTextView alloc] initWithFrame:descriptionScroll.contentView.bounds];
    self.descriptionField.delegate = self;
    self.descriptionField.identifier = @"bugReportDescription";
    self.descriptionField.font = [NSFont systemFontOfSize:13];
    self.descriptionField.textColor = NSColor.labelColor;
    self.descriptionField.drawsBackground = NO;
    self.descriptionField.richText = NO;
    self.descriptionField.importsGraphics = NO;
    self.descriptionField.automaticLinkDetectionEnabled = NO;
    self.descriptionField.automaticDataDetectionEnabled = NO;
    self.descriptionField.automaticTextReplacementEnabled = NO;
    self.descriptionField.automaticSpellingCorrectionEnabled = NO;
    self.descriptionField.verticallyResizable = YES;
    self.descriptionField.horizontallyResizable = NO;
    self.descriptionField.minSize = NSMakeSize(0, 0);
    self.descriptionField.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    self.descriptionField.autoresizingMask = NSViewWidthSizable;
    self.descriptionField.textContainerInset = NSZeroSize;
    self.descriptionField.textContainer.lineFragmentPadding = 0;
    self.descriptionField.textContainer.widthTracksTextView = YES;
    self.descriptionField.textContainer.containerSize = NSMakeSize(descriptionScroll.contentSize.width, CGFLOAT_MAX);
    descriptionScroll.documentView = self.descriptionField;
    self.descriptionSurface = [[RCBugReportTextAreaSurface alloc] initWithFrame:NSZeroRect];
    self.descriptionSurface.identifier = @"bugReportDescriptionSurface";
    self.descriptionSurface.editable = NO;
    self.descriptionSurface.selectable = NO;
    self.descriptionSurface.focusRingType = NSFocusRingTypeNone;
    self.descriptionSurface.editor = self.descriptionField;
    [self addView:self.descriptionSurface toStack:stack];
    descriptionScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.descriptionSurface addSubview:descriptionScroll];
    [NSLayoutConstraint activateConstraints:@[
        [self.descriptionSurface.heightAnchor constraintEqualToConstant:140],
        [descriptionScroll.leadingAnchor constraintEqualToAnchor:self.descriptionSurface.leadingAnchor constant:12],
        [descriptionScroll.trailingAnchor constraintEqualToAnchor:self.descriptionSurface.trailingAnchor constant:-12],
        [descriptionScroll.topAnchor constraintEqualToAnchor:self.descriptionSurface.topAnchor constant:8],
        [descriptionScroll.bottomAnchor constraintEqualToAnchor:self.descriptionSurface.bottomAnchor constant:-8],
    ]];
    [self addView:[self labelForKey:@"Reply contact (optional, up to 200 characters)"] toStack:stack];
    self.contactField = [self inputField];
    self.contactField.identifier = @"bugReportContact";
    [self addView:self.contactField toStack:stack];
    self.consentCheckbox = [[RCBugReportConsentCheckbox alloc] initWithFrame:NSZeroRect];
    [self.consentCheckbox setButtonType:NSButtonTypeSwitch];
    self.consentCheckbox.target = self;
    self.consentCheckbox.action = @selector(formValueDidChange:);
    self.consentCheckbox.state = NSControlStateValueOff;
    self.consentCheckbox.allowsMixedState = NO;
    self.consentCheckbox.identifier = @"bugReportSourceConsent";
    self.consentCheckbox.cell.wraps = YES;
    self.consentCheckbox.cell.lineBreakMode = NSLineBreakByWordWrapping;
    [self.consentCheckbox setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self addView:self.consentCheckbox toStack:stack];
    self.metadataLabel = [self labelForKey:@""];
    self.metadataLabel.textColor = NSColor.secondaryLabelColor;
    [self addView:self.metadataLabel toStack:stack];
    NSStackView *actions = [[NSStackView alloc] initWithFrame:NSZeroRect];
    actions.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    actions.alignment = NSLayoutAttributeCenterY;
    actions.spacing = 10;
    self.sendButton = [[RCBugReportSendButton alloc] initWithFrame:NSZeroRect];
    self.sendButton.target = self;
    self.sendButton.action = @selector(sendReport:);
    [self.sendButton setButtonType:NSButtonTypeMomentaryPushIn];
    self.sendButton.bordered = NO;
    self.sendButton.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    self.sendButton.focusRingType = NSFocusRingTypeExterior;
    self.sendButton.identifier = @"bugReportSend";
    [actions addArrangedSubview:self.sendButton];
    self.progress = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(0, 0, 16, 16)];
    self.progress.style = NSProgressIndicatorStyleSpinning;
    self.progress.controlSize = NSControlSizeSmall;
    self.progress.indeterminate = YES;
    self.progress.displayedWhenStopped = NO;
    [actions addArrangedSubview:self.progress];
    [self.progress.widthAnchor constraintEqualToConstant:16].active = YES;
    [self.progress.heightAnchor constraintEqualToConstant:16].active = YES;
    [stack addArrangedSubview:actions];
    self.statusLabel = [self labelForKey:@""];
    self.statusLabel.identifier = @"bugReportStatus";
    [self.statusLabel.heightAnchor constraintGreaterThanOrEqualToConstant:18].active = YES;
    [self addView:self.statusLabel toStack:stack];
    NSDictionary *draft = self.reportService.draft;
    if (draft) {
        self.titleField.stringValue = draft[@"title"];
        self.descriptionField.string = draft[@"description"];
        self.contactField.stringValue = draft[@"contact"];
        // A new, editable form always asks again. An active submission displays its prior consent.
        self.consentCheckbox.state = self.reportService.isSubmitting ? NSControlStateValueOn : NSControlStateValueOff;
        self.displaysServiceDraft = YES;
    }
    [self serviceDidChange:nil];
    [self refreshLanguage:nil];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refreshLanguage:)
                                               name:RCLanguageDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(serviceDidChange:)
                                               name:RCBugReportServiceDidChangeNotification object:self.reportService];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateDescriptionFocus:)
                                               name:NSWindowDidBecomeKeyNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateDescriptionFocus:)
                                               name:NSWindowDidResignKeyNotification object:nil];
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
- (NSTextField *)labelForKey:(NSString *)key {
    NSTextField *label = [NSTextField wrappingLabelWithString:@""];
    label.font = [NSFont systemFontOfSize:13];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [label setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationVertical];
    [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    if (key.length) { [self.localizedLabels setObject:key forKey:label]; }
    return label;
}
- (NSTextField *)inputField {
    NSTextField *field = [[RCPreferencesTextField alloc] initWithFrame:NSZeroRect];
    field.font = [NSFont systemFontOfSize:13];
    field.delegate = self;
    field.translatesAutoresizingMaskIntoConstraints = NO;
    [field.heightAnchor constraintEqualToConstant:32].active = YES;
    [field setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    field.cell.scrollable = YES;
    return field;
}
- (void)addView:(NSView *)view toStack:(NSStackView *)stack {
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:view];
    [view.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
}
- (void)refreshLanguage:(NSNotification *)notification {
    for (NSTextField *label in self.localizedLabels) {
        label.stringValue = RCLocalizedString([self.localizedLabels objectForKey:label], nil);
    }
    self.titleField.accessibilityLabel = RCLocalizedString(@"Title (required, up to 120 characters)", nil);
    self.descriptionField.accessibilityLabel = RCLocalizedString(@"Description (required, up to 2,500 characters)", nil);
    self.contactField.accessibilityLabel = RCLocalizedString(@"Reply contact (optional, up to 200 characters)", nil);
    self.consentCheckbox.title = RCLocalizedString(@"I consent to the collection of source information.", nil);
    self.consentCheckbox.accessibilityLabel = self.consentCheckbox.title;
    NSDictionary *metadata = self.reportService.sourceMetadata;
    self.metadataLabel.stringValue = [NSString stringWithFormat:RCLocalizedString(@"App version: %@\nmacOS: %@\nLanguage: %@\nTime zone: %@", nil),
                                     metadata[@"app_version"], metadata[@"os_version"], metadata[@"language"], metadata[@"timezone"]];
    self.sendButton.title = RCLocalizedString(@"Send Report", nil);
    self.statusLabel.stringValue = self.statusKey.length ? RCLocalizedString(self.statusKey, nil) : @"";
    [self updateSendAvailability];
}
- (void)updateDescriptionFocus:(NSNotification *)notification { self.descriptionSurface.needsDisplay = YES; }
- (void)controlTextDidChange:(NSNotification *)notification { [self updateSendAvailability]; }
- (void)textDidChange:(NSNotification *)notification { [self updateSendAvailability]; }
- (IBAction)formValueDidChange:(id)sender { [self updateSendAvailability]; }
- (void)updateSendAvailability {
    NSCharacterSet *whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSText *titleEditor = self.titleField.currentEditor;
    NSText *contactEditor = self.contactField.currentEditor;
    NSString *title = [(titleEditor ? titleEditor.string : self.titleField.stringValue) stringByTrimmingCharactersInSet:whitespace];
    NSString *description = [self.descriptionField.string stringByTrimmingCharactersInSet:whitespace];
    NSString *contact = [(contactEditor ? contactEditor.string : self.contactField.stringValue) stringByTrimmingCharactersInSet:whitespace];
    // This controls the affordance only; the shared service remains the submission authority.
    self.sendButton.enabled = !self.inFlight && !self.reportService.isSubmitting &&
        self.consentCheckbox.state == NSControlStateValueOn && title.length > 0 && title.length <= 120 &&
        description.length > 0 && description.length <= 2500 && contact.length <= 200;
}
- (void)updateSending:(BOOL)sending statusKey:(NSString *)key {
    self.inFlight = sending;
    self.titleField.enabled = !sending;
    self.descriptionField.editable = !sending;
    self.contactField.enabled = !sending;
    self.consentCheckbox.enabled = !sending;
    self.descriptionSurface.needsDisplay = YES;
    if (sending) { [self.progress startAnimation:nil]; } else { [self.progress stopAnimation:nil]; }
    self.statusKey = key;
    [self refreshLanguage:nil];
}
- (void)serviceDidChange:(NSNotification *)notification {
    RCBugReportService *service = self.reportService;
    if (service.isSubmitting) {
        NSDictionary *draft = service.draft;
        self.displaysServiceDraft = [self.titleField.stringValue isEqualToString:draft[@"title"]] &&
            [self.descriptionField.string isEqualToString:draft[@"description"]] &&
            [self.contactField.stringValue isEqualToString:draft[@"contact"]] && self.consentCheckbox.state == NSControlStateValueOn;
        [self updateSending:YES statusKey:@"Sending report…"];
    } else {
        BOOL success = [service.lastResponse[@"ok"] boolValue];
        if (success && self.displaysServiceDraft) {
            self.titleField.stringValue = @"";
            self.descriptionField.string = @"";
            self.contactField.stringValue = @"";
            self.consentCheckbox.state = NSControlStateValueOff;
        }
        self.displaysServiceDraft = NO;
        NSString *status = service.lastResponse ? (success ? @"Report sent. Thank you for helping improve Revclip."
            : @"Could not send the report. Your text is preserved. Please try again when you are ready.") : @"";
        [self updateSending:NO statusKey:status];
    }
}
- (IBAction)sendReport:(id)sender {
    if (self.inFlight || self.reportService.isSubmitting) { return; }
    if (self.view.window && ![self.view.window makeFirstResponder:nil]) { return; }
    [self updateSendAvailability];
    if (!self.sendButton.enabled) { return; }
    __weak typeof(self) weakSelf = self;
    [self.reportService submitTitle:self.titleField.stringValue description:self.descriptionField.string
                           contact:self.contactField.stringValue consent:self.consentCheckbox.state == NSControlStateValueOn
                        completion:^(NSDictionary *response) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.reportService.isSubmitting) { return; }
        // Only service-owned generic errors reach this path; no server body or NSError is shown.
        if (![response[@"ok"] boolValue]) {
            [strongSelf updateSending:NO statusKey:response[@"error"]];
        }
    }];
}
@end
