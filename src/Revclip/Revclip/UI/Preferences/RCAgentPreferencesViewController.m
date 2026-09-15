#import "RCAgentPreferencesViewController.h"
#import "RCPreferencesPage.h"
#import "RCLocalization.h"

@interface RCAgentPreferencesDocument : NSView
@end
@implementation RCAgentPreferencesDocument
- (BOOL)isFlipped { return YES; }
@end

@interface RCAgentPreferencesViewController ()
@property (nonatomic, strong) NSTextView *promptField;
@property (nonatomic, strong) NSTextField *promptCopyStatus;
@property (nonatomic, strong) NSButton *promptCopyButton;
@property (nonatomic, strong) NSTextField *installationStatus;
@property (nonatomic) BOOL inspecting;
@end

@implementation RCAgentPreferencesViewController

// POSIX single-quote escaping also protects whitespace, dollar signs and backticks.
+ (NSString *)shellQuotedArgument:(NSString *)argument {
    return [NSString stringWithFormat:@"'%@'", [argument stringByReplacingOccurrencesOfString:@"'" withString:@"'\"'\"'"]];
}

+ (NSString *)installationPromptForBundleURL:(NSURL *)bundleURL appName:(NSString *)appName {
    NSURL *installer = [bundleURL URLByAppendingPathComponent:@"Contents/Helpers/revclip"];
    NSString *command = [NSString stringWithFormat:@"%@ agent", [self shellQuotedArgument:installer.path]];
    // CLI identity follows bundle metadata, independent of the .app filename.
    NSString *target = appName.length ? appName : @"Revclip";
    NSString *option = [NSString stringWithFormat:@" --app %@", [self shellQuotedArgument:target]];
    NSString *instructions = RCLocalizedString(@"Install the Revclip skill in all detected supported agent roots using this bundled installer and providers.json. Run inspect, install with defaults, then inspect to verify. Stop on errors; never force or overwrite conflicts. Report installed paths, skips, and conflicts. Include experimental DeepSeek Harness (.dsh) only if detected and supported by the installer.", nil);
    NSString *next = RCLocalizedString(@"Explain any reload or new session needed. Then use the skill for template CRUD and supported settings; ask what I want to change first.", nil);
    return [NSString stringWithFormat:@"%@\n\n```sh\n%@ inspect%@\n%@ install%@\n%@ inspect%@\n```\n\n%@", instructions, command, option, command, option, command, option, next];
}

- (void)loadView {
    self.view = [[RCAgentPreferencesDocument alloc] initWithFrame:NSMakeRect(0, 0, 660, 1000)];
    [self buildContent];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(languageDidChange:)
                                               name:RCLanguageDidChangeNotification object:nil];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)languageDidChange:(NSNotification *)notification {
    // Preserve the document view and its host constraints when changing languages.
    for (NSView *child in self.view.subviews.copy) { [child removeFromSuperview]; }
    [self buildContent];
}

- (NSTextField *)label:(NSString *)text size:(CGFloat)size {
    NSTextField *field = [NSTextField wrappingLabelWithString:text];
    field.font = [NSFont systemFontOfSize:size];
    field.textColor = NSColor.labelColor;
    field.translatesAutoresizingMaskIntoConstraints = NO;
    [field setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationVertical];
    [field setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return field;
}

- (void)addRow:(NSView *)row toStack:(NSStackView *)stack {
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:row];
    [row.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
}

- (void)buildContent {
    NSStackView *stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    stack.identifier = @"agentContent";
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    NSLayoutConstraint *fillWidth = [stack.widthAnchor constraintEqualToAnchor:self.view.widthAnchor constant:-48];
    fillWidth.priority = NSLayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:8],
        [stack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [stack.widthAnchor constraintLessThanOrEqualToConstant:680],
        [stack.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor constant:-48],
        fillWidth,
        [stack.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-24],
    ]];
    [self addRow:[self label:RCLocalizedString(@"Manage Revclip templates and settings with your coding agent.", nil) size:13] toStack:stack];
    [self addRow:[self label:RCLocalizedString(@"Copy the prompt into Codex or Claude Code. Review the installation results, then reload your agent or start a new session.", nil) size:13] toStack:stack];
    [self addProviderGridToStack:stack];
    self.installationStatus = [self label:RCLocalizedString(@"Checking installed skills…", nil) size:13];
    self.installationStatus.identifier = @"agentInstallationStatus";
    [self addRow:self.installationStatus toStack:stack];
    NSButton *check = [NSButton buttonWithTitle:RCLocalizedString(@"Check skill updates", nil) target:self action:@selector(checkInstalledSkills:)];
    check.bezelStyle = NSBezelStyleRounded;
    [stack addArrangedSubview:check];

    self.promptCopyButton = [NSButton buttonWithTitle:RCLocalizedString(@"Copy Prompt", nil) target:self action:@selector(copyPrompt:)];
    self.promptCopyButton.identifier = @"agentCopyPrompt";
    self.promptCopyButton.bezelStyle = NSBezelStyleRounded;
    [stack addArrangedSubview:self.promptCopyButton];
    self.promptCopyStatus = [self label:@"" size:12];
    self.promptCopyStatus.identifier = @"agentCopyStatus";
    self.promptCopyStatus.textColor = NSColor.secondaryLabelColor;
    [self.promptCopyStatus.heightAnchor constraintGreaterThanOrEqualToConstant:16].active = YES;
    [self addRow:self.promptCopyStatus toStack:stack];

    RCPreferencesSurface *surface = [[RCPreferencesSurface alloc] initWithFrame:NSZeroRect];
    surface.drawsBorder = YES;
    surface.identifier = @"agentPromptSurface";
    [self addRow:surface toStack:stack];
    NSBundle *bundle = NSBundle.mainBundle;
    id name = [bundle objectForInfoDictionaryKey:@"CFBundleName"];
    NSString *prompt = [self.class installationPromptForBundleURL:bundle.bundleURL
                                                        appName:[name isKindOfClass:NSString.class] ? name : @""];
    NSScrollView *promptScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 580, 260)];
    promptScroll.identifier = @"agentPromptScroll";
    promptScroll.translatesAutoresizingMaskIntoConstraints = NO;
    promptScroll.hasVerticalScroller = YES;
    promptScroll.hasHorizontalScroller = NO;
    promptScroll.autohidesScrollers = YES;
    promptScroll.drawsBackground = NO;
    [surface addSubview:promptScroll];
    self.promptField = [[NSTextView alloc] initWithFrame:promptScroll.contentView.bounds];
    self.promptField.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    self.promptField.textColor = NSColor.labelColor;
    self.promptField.drawsBackground = NO;
    self.promptField.richText = NO;
    self.promptField.selectable = YES;
    self.promptField.editable = NO;
    self.promptField.verticallyResizable = YES;
    self.promptField.horizontallyResizable = NO;
    self.promptField.minSize = NSMakeSize(0, 0);
    self.promptField.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    self.promptField.autoresizingMask = NSViewWidthSizable;
    self.promptField.textContainerInset = NSMakeSize(12, 12);
    self.promptField.textContainer.widthTracksTextView = YES;
    self.promptField.textContainer.containerSize = NSMakeSize(promptScroll.contentSize.width, CGFLOAT_MAX);
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.lineBreakMode = NSLineBreakByCharWrapping;
    self.promptField.defaultParagraphStyle = paragraph;
    self.promptField.string = prompt;
    self.promptField.identifier = @"agentPrompt";
    self.promptField.accessibilityLabel = RCLocalizedString(@"Installation prompt", nil);
    promptScroll.documentView = self.promptField;
    [NSLayoutConstraint activateConstraints:@[
        [promptScroll.leadingAnchor constraintEqualToAnchor:surface.leadingAnchor constant:4],
        [promptScroll.trailingAnchor constraintEqualToAnchor:surface.trailingAnchor constant:-4],
        [promptScroll.topAnchor constraintEqualToAnchor:surface.topAnchor constant:4],
        [promptScroll.bottomAnchor constraintEqualToAnchor:surface.bottomAnchor constant:-4],
        [promptScroll.heightAnchor constraintEqualToConstant:260],
    ]];
}

- (void)addProviderGridToStack:(NSStackView *)stack {
    NSArray<NSArray<NSString *> *> *providers = @[
        @[@"Codex", @"openai"], @[@"Claude Code", @"claude"],
        @[@"Antigravity / Gemini", @"gemini"], @[@"Cursor", @"cursor"],
        @[@"Grok", @"grok"], @[@"Kimi", @"kimi"],
        @[@"Hermes", @"hermes"], @[@"DeepSeek Harness", @"deepseek"],
    ];
    NSStackView *pair = nil;
    for (NSUInteger index = 0; index < providers.count; index++) {
        NSArray<NSString *> *provider = providers[index];
        if (index % 2 == 0) {
            pair = [[NSStackView alloc] initWithFrame:NSZeroRect];
            pair.orientation = NSUserInterfaceLayoutOrientationHorizontal;
            pair.distribution = NSStackViewDistributionFillEqually;
            pair.alignment = NSLayoutAttributeTop;
            pair.spacing = 16;
            pair.identifier = @"agentProviderPair";
            [self addRow:pair toStack:stack];
        }
        NSView *row = [[NSView alloc] initWithFrame:NSZeroRect];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [pair addArrangedSubview:row];
        NSImageView *icon = [[NSImageView alloc] initWithFrame:NSZeroRect];
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        icon.identifier = [@"Agent-" stringByAppendingString:provider[1]];
        NSImage *image = [[NSImage imageNamed:icon.identifier] copy];
        image.template = YES;
        icon.image = image;
        icon.imageScaling = NSImageScaleProportionallyUpOrDown;
        icon.contentTintColor = NSColor.labelColor;
        [row addSubview:icon];
        NSTextField *label = [self label:provider[0] size:13];
        [row addSubview:label];
        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
            [icon.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [icon.widthAnchor constraintEqualToConstant:18],
            [icon.heightAnchor constraintEqualToConstant:18],
            [row.heightAnchor constraintGreaterThanOrEqualToConstant:24],
            [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:10],
            [label.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
            [label.topAnchor constraintEqualToAnchor:row.topAnchor constant:3],
            [label.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-3],
        ]];
    }
    NSTextField *caption = [self label:RCLocalizedString(@"Installed only for detected, supported tools. DeepSeek Harness (.dsh) is experimental (developer preview).", nil) size:12];
    caption.textColor = NSColor.secondaryLabelColor;
    [self addRow:caption toStack:stack];
}


- (void)viewWillAppear {
    [super viewWillAppear];
    [self checkInstalledSkills:nil];
}

- (void)checkInstalledSkills:(id)sender {
    if (self.inspecting || NSClassFromString(@"XCTestCase")) return;
    self.inspecting = YES;
    NSURL *executable = [NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"Contents/Helpers/revclip"];
    NSString *appName = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleName"] ?: @"Revclip";
    self.installationStatus.stringValue = RCLocalizedString(@"Checking installed skills…", nil);
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSTask *task = [NSTask new];
        task.executableURL = executable;
        task.arguments = @[@"agent", @"inspect", @"--app", appName];
        NSPipe *pipe = [NSPipe pipe];
        task.standardOutput = pipe;
        task.standardError = NSFileHandle.fileHandleWithNullDevice;
        NSDictionary *inspection = nil;
        NSError *error = nil;
        if ([task launchAndReturnError:&error]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                if (task.running) [task terminate];
            });
            @try {
                NSMutableData *data = [NSMutableData data];
                while (data.length <= 1024 * 1024) {
                    NSData *chunk = [pipe.fileHandleForReading readDataOfLength:MIN((NSUInteger)8192, 1024 * 1024 + 1 - data.length)];
                    if (chunk.length == 0) break;
                    [data appendData:chunk];
                }
                if (data.length > 1024 * 1024) [task terminate];
                [task waitUntilExit];
                if ((task.terminationStatus == 0 || task.terminationStatus == 1) && data.length <= 1024 * 1024) {
                    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    if ([value isKindOfClass:NSDictionary.class]) inspection = value;
                }
            } @catch (NSException *exception) { if (task.running) [task terminate]; }
            [pipe.fileHandleForReading closeFile];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self) return;
            self.inspecting = NO;
            NSArray *providers = !inspection[@"error"] && [inspection[@"providers"] isKindOfClass:NSArray.class] ? inspection[@"providers"] : nil;
            NSUInteger updates = 0, managed = 0, conflicts = 0;
            for (id provider in providers) {
                if (![provider isKindOfClass:NSDictionary.class]) continue;
                if ([provider[@"update_available"] isEqual:@YES]) updates++;
                if ([provider[@"state"] isEqual:@"managed"] || [provider[@"state"] isEqual:@"current"] || [provider[@"state"] isEqual:@"installed"]) managed++;
                if ([provider[@"state"] isEqual:@"conflict"]) conflicts++;
            }
            NSString *key = !providers ? @"Could not check skills. Run the setup prompt to inspect them."
                : conflicts ? @"A skill has local changes. The setup prompt will report conflicts without overwriting them."
                : updates ? @"Skill updates are available. Copy and run the setup prompt to update them."
                : managed ? @"Installed skills are up to date. Python is not required."
                : @"Run the setup prompt to install skills. Python is not required.";
            self.installationStatus.stringValue = RCLocalizedString(key, nil);
        });
    });
}

- (NSPasteboard *)promptPasteboard { return NSPasteboard.generalPasteboard; }

- (IBAction)copyPrompt:(id)sender {
    NSPasteboard *pasteboard = [self promptPasteboard];
    [pasteboard clearContents];
    BOOL copied = [pasteboard setString:self.promptField.string forType:NSPasteboardTypeString];
    self.promptCopyStatus.stringValue = copied ? RCLocalizedString(@"Prompt copied. Paste it into your agent.", nil)
                                        : RCLocalizedString(@"Could not copy the prompt. Select and copy the text below.", nil);
}

@end
