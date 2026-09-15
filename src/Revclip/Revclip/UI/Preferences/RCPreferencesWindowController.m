#import "RCGlassBackground.h"
#import "RCPreferencesPage.h"
#import "RCLocalization.h"
//
//  RCPreferencesWindowController.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import "RCPreferencesWindowController.h"
#import "Revclip-Swift.h"

#import "RCExcludePreferencesViewController.h"
#import "RCGeneralPreferencesViewController.h"
#import "RCMenuPreferencesViewController.h"
#import "RCPanicPreferencesViewController.h"
#import "RCShortcutsPreferencesViewController.h"
#import "RCTypePreferencesViewController.h"
#import "RCUpdatesPreferencesViewController.h"

NSString * const RCPreferencesTabGeneral = @"general";
NSString * const RCPreferencesTabMenu = @"menu";
NSString * const RCPreferencesTabType = @"type";
NSString * const RCPreferencesTabExclude = @"exclude";
NSString * const RCPreferencesTabShortcuts = @"shortcuts";
NSString * const RCPreferencesTabUpdates = @"updates";
NSString * const RCPreferencesTabPanic = @"panic";
static NSString * const RCPreferencesTabAppearance = @"appearance";


@interface RCPreferencesSidebarRow : NSTableRowView
@end
@implementation RCPreferencesSidebarRow
- (NSBackgroundStyle)interiorBackgroundStyle { return NSBackgroundStyleNormal; }
- (void)drawSelectionInRect:(NSRect)dirtyRect {
    [[NSColor.controlAccentColor colorWithAlphaComponent:self.emphasized ? 0.22 : 0.12] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 4, 2) xRadius:10 yRadius:10] fill];
}
@end

@interface RCPreferencesWindowController () <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, strong, nullable) RCGeneralPreferencesViewController *generalViewController;
@property (nonatomic, strong, nullable) RCMenuPreferencesViewController *menuViewController;
@property (nonatomic, strong, nullable) RCTypePreferencesViewController *typeViewController;
@property (nonatomic, strong, nullable) RCExcludePreferencesViewController *excludeViewController;
@property (nonatomic, strong, nullable) RCShortcutsPreferencesViewController *shortcutsViewController;
@property (nonatomic, strong, nullable) RCUpdatesPreferencesViewController *updatesViewController;
@property (nonatomic, strong, nullable) RCPanicPreferencesViewController *panicViewController;
@property (nonatomic, strong) NSViewController *appearanceViewController;
@property (nonatomic, assign) BOOL centeredOnFirstShow;
@property (nonatomic, copy) NSString *selectedTab;
@property (nonatomic, strong) NSTableView *sidebar;
@property (nonatomic, strong) NSScrollView *pageScrollView;
@property (nonatomic, strong) NSTextField *pageTitle;
@property (nonatomic, strong) NSArray<NSLayoutConstraint *> *documentConstraints;


@end

@implementation RCPreferencesWindowController

+ (instancetype)shared {
    static RCPreferencesWindowController *sharedController = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedController = [[self alloc] init];
    });
    return sharedController;
}

- (instancetype)init {
    self = [super initWithWindowNibName:@"RCPreferencesWindow"];
    return self;
}

- (void)windowDidLoad {
    [super windowDidLoad];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(languageDidChange:) name:RCLanguageDidChangeNotification object:nil];
    [self configureWindow];
    [self configureSidebar];
    [self showTab:RCPreferencesTabGeneral];
}

- (void)languageDidChange:(NSNotification *)notification {
    // Defer replacement until the popup action returns; no template editor state is replaced.
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *tab = self.selectedTab;
        self.generalViewController = nil;
        self.menuViewController = nil;
        self.typeViewController = nil;
        self.excludeViewController = nil;
        self.shortcutsViewController = nil;
        self.updatesViewController = nil;
        self.panicViewController = nil;
        self.appearanceViewController = nil;
        self.window.title = RCLocalizedString(@"Preferences", nil);
        [self configureSidebar];
        [self showTab:tab];
    });
}

- (void)showWindow:(id)sender {
    if (!self.centeredOnFirstShow) {
        [self.window center];
        self.centeredOnFirstShow = YES;
    }

    [super showWindow:sender];
    if (@available(macOS 14.0, *)) {
        [NSApp activate];
    } else {
        [NSApp activateIgnoringOtherApps:YES];
    }
    [self.window makeKeyAndOrderFront:sender];
}

- (void)showTab:(NSString *)tabIdentifier {
    NSString *resolvedTabIdentifier = tabIdentifier.length > 0 ? tabIdentifier : RCPreferencesTabGeneral;
    NSViewController *viewController = [self viewControllerForTabIdentifier:resolvedTabIdentifier];
    if (viewController == nil) {
        resolvedTabIdentifier = RCPreferencesTabGeneral;
        viewController = [self viewControllerForTabIdentifier:resolvedTabIdentifier];
    }
    if (viewController == nil) {
        return;
    }

    [self switchToViewController:viewController];
    self.selectedTab = resolvedTabIdentifier;
    self.pageTitle.stringValue = [self titleForTabIdentifier:resolvedTabIdentifier];
    NSInteger row = [self.tabIdentifiers indexOfObject:resolvedTabIdentifier];
    if (self.sidebar.selectedRow != row) {
        [self.sidebar selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    }
}

#pragma mark - Sidebar

- (void)configureSidebar {
    // A single shell is used by every distribution. Native materials follow accessibility settings.
    self.window.toolbar = nil;
    NSView *background = [[NSView alloc] initWithFrame:self.window.contentView.bounds];
    NSView *shell = [RCGlassBackground wrapContent:background];
    NSView *sidebarBackground = [[NSView alloc] initWithFrame:NSZeroRect];
    sidebarBackground.translatesAutoresizingMaskIntoConstraints = NO;
    [background addSubview:sidebarBackground];

    NSImageView *brandIcon = [[NSImageView alloc] initWithFrame:NSZeroRect];
    brandIcon.image = [NSImage imageNamed:NSImageNameApplicationIcon];
    brandIcon.imageScaling = NSImageScaleProportionallyUpOrDown;
    brandIcon.translatesAutoresizingMaskIntoConstraints = NO;
    brandIcon.wantsLayer = YES;
    brandIcon.layer.cornerRadius = 18;
    brandIcon.layer.masksToBounds = YES;
    [brandIcon setAccessibilityLabel:@"Revclip"];
    [sidebarBackground addSubview:brandIcon];
    [NSLayoutConstraint activateConstraints:@[
        [brandIcon.leadingAnchor constraintEqualToAnchor:sidebarBackground.leadingAnchor constant:20],
        [brandIcon.topAnchor constraintEqualToAnchor:sidebarBackground.topAnchor constant:40],
        [brandIcon.widthAnchor constraintEqualToConstant:36],
        [brandIcon.heightAnchor constraintEqualToConstant:36],
    ]];

    NSScrollView *navigation = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    navigation.drawsBackground = NO;
    navigation.hasVerticalScroller = YES;
    navigation.autohidesScrollers = YES;
    navigation.translatesAutoresizingMaskIntoConstraints = NO;
    self.sidebar = [[NSTableView alloc] initWithFrame:NSZeroRect];
    self.sidebar.headerView = nil;
    self.sidebar.backgroundColor = NSColor.clearColor;
    self.sidebar.style = NSTableViewStylePlain;
    self.sidebar.rowHeight = 40;
    self.sidebar.intercellSpacing = NSMakeSize(0, 4);
    [self.sidebar addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"section"]];
    self.sidebar.delegate = self;
    self.sidebar.dataSource = self;
    self.sidebar.allowsEmptySelection = NO;
    [self.sidebar setAccessibilityLabel:RCLocalizedString(@"Preferences", nil)];
    navigation.documentView = self.sidebar;
    [sidebarBackground addSubview:navigation];

    RCPreferencesSurface *pane = [[RCPreferencesSurface alloc] initWithFrame:NSZeroRect];
    pane.cornerRadius = 24;
    pane.drawsBorder = YES;
    pane.translatesAutoresizingMaskIntoConstraints = NO;
    [background addSubview:pane];
    [NSLayoutConstraint activateConstraints:@[
        [pane.leadingAnchor constraintEqualToAnchor:sidebarBackground.trailingAnchor constant:8],
        [pane.trailingAnchor constraintEqualToAnchor:background.trailingAnchor constant:-12],
        [pane.topAnchor constraintEqualToAnchor:background.topAnchor constant:36],
        [pane.bottomAnchor constraintEqualToAnchor:background.bottomAnchor constant:-12],
    ]];
    self.pageTitle = [NSTextField labelWithString:@""];
    self.pageTitle.font = [NSFont systemFontOfSize:24 weight:NSFontWeightSemibold];
    self.pageTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [background addSubview:self.pageTitle];
    self.pageScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.pageScrollView.drawsBackground = NO;
    self.pageScrollView.hasVerticalScroller = YES;
    self.pageScrollView.scrollerStyle = NSScrollerStyleOverlay;
    self.pageScrollView.autohidesScrollers = YES;
    self.pageScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [background addSubview:self.pageScrollView];
    self.window.contentView = shell;
    [NSLayoutConstraint activateConstraints:@[
        [sidebarBackground.leadingAnchor constraintEqualToAnchor:background.leadingAnchor],
        [sidebarBackground.topAnchor constraintEqualToAnchor:background.topAnchor],
        [sidebarBackground.bottomAnchor constraintEqualToAnchor:background.bottomAnchor],
        [sidebarBackground.widthAnchor constraintEqualToConstant:208],
        [navigation.leadingAnchor constraintEqualToAnchor:sidebarBackground.leadingAnchor constant:8],
        [navigation.trailingAnchor constraintEqualToAnchor:sidebarBackground.trailingAnchor constant:-8],
        [navigation.topAnchor constraintEqualToAnchor:brandIcon.bottomAnchor constant:12],
        [navigation.bottomAnchor constraintEqualToAnchor:background.bottomAnchor constant:-16],
        [self.pageTitle.leadingAnchor constraintEqualToAnchor:pane.leadingAnchor constant:24],
        [self.pageTitle.topAnchor constraintEqualToAnchor:pane.topAnchor constant:24],
        [self.pageTitle.trailingAnchor constraintLessThanOrEqualToAnchor:background.trailingAnchor constant:-24],
        [self.pageScrollView.topAnchor constraintEqualToAnchor:self.pageTitle.bottomAnchor constant:20],
        [self.pageScrollView.leadingAnchor constraintEqualToAnchor:pane.leadingAnchor],
        [self.pageScrollView.trailingAnchor constraintEqualToAnchor:pane.trailingAnchor],
        [self.pageScrollView.bottomAnchor constraintEqualToAnchor:pane.bottomAnchor constant:-12],
    ]];
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    return [[RCPreferencesSidebarRow alloc] initWithFrame:NSZeroRect];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return self.tabIdentifiers.count; }

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NSString *identifier = self.tabIdentifiers[row];
    NSTableCellView *cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
    NSTextField *label = [NSTextField labelWithString:[self titleForTabIdentifier:identifier]];
    label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSZeroRect];
    icon.image = [NSImage imageWithSystemSymbolName:[self symbolNameForTabIdentifier:identifier] accessibilityDescription:nil];
    icon.contentTintColor = NSColor.controlAccentColor;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [cell addSubview:icon];
    [cell addSubview:label];
    cell.textField = label;
    cell.imageView = icon;
    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:8],
        [icon.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:20],
        [icon.heightAnchor constraintEqualToConstant:20],
        [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:10],
        [label.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-8],
        [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
    ]];
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSInteger row = self.sidebar.selectedRow;
    if (row >= 0) { [self showTab:self.tabIdentifiers[row]]; }
}

- (BOOL)selectionShouldChangeInTableView:(NSTableView *)tableView {
    NSResponder *responder = self.window.firstResponder;
    if ([responder isKindOfClass:NSTextView.class] && [(NSTextView *)responder isFieldEditor]) {
        return [self.window makeFirstResponder:tableView];
    }
    return YES;
}

#pragma mark - View Controller Switch

- (void)switchToViewController:(NSViewController *)viewController {
    NSView *newView = viewController.view;
    if (self.pageScrollView.documentView == newView) { return; }
    newView.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint deactivateConstraints:self.documentConstraints ?: @[]];
    self.pageScrollView.documentView = newView;
    NSClipView *clip = self.pageScrollView.contentView;
    self.documentConstraints = @[
        [newView.widthAnchor constraintEqualToAnchor:clip.widthAnchor],
        [newView.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor],
        [newView.topAnchor constraintEqualToAnchor:clip.topAnchor],
    ];
    [NSLayoutConstraint activateConstraints:self.documentConstraints];
    [newView scrollPoint:NSZeroPoint];
}

#pragma mark - Private

- (void)configureWindow {
    NSWindow *window = self.window;
    window.title = RCLocalizedString(@"Preferences", nil);
    window.titlebarAppearsTransparent = YES;
    window.titleVisibility = NSWindowTitleHidden;
    window.opaque = NO;
    window.backgroundColor = NSColor.clearColor;
    window.styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView;
    window.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace;
    window.releasedWhenClosed = NO;
    window.contentMinSize = NSMakeSize(860, 520);
    [window setContentSize:NSMakeSize(920, 680)];
}

- (NSArray<NSString *> *)tabIdentifiers {
    return @[
        RCPreferencesTabGeneral,
        RCPreferencesTabAppearance,
        RCPreferencesTabMenu,
        RCPreferencesTabType,
        RCPreferencesTabExclude,
        RCPreferencesTabShortcuts,
        RCPreferencesTabUpdates,
        RCPreferencesTabPanic,
    ];
}

- (nullable NSViewController *)viewControllerForTabIdentifier:(NSString *)tabIdentifier {
    if ([tabIdentifier isEqualToString:RCPreferencesTabAppearance]) {
        if (self.appearanceViewController == nil) {
            self.appearanceViewController = [RCAppearanceController makePreferencesController];
        }
        return self.appearanceViewController;
    }
    if ([tabIdentifier isEqualToString:RCPreferencesTabGeneral]) {
        if (self.generalViewController == nil) {
            self.generalViewController = [[RCGeneralPreferencesViewController alloc] initWithNibName:@"RCGeneralPreferencesView" bundle:nil];
        }
        return self.generalViewController;
    }

    if ([tabIdentifier isEqualToString:RCPreferencesTabMenu]) {
        if (self.menuViewController == nil) {
            self.menuViewController = [[RCMenuPreferencesViewController alloc] initWithNibName:@"RCMenuPreferencesView" bundle:nil];
        }
        return self.menuViewController;
    }

    if ([tabIdentifier isEqualToString:RCPreferencesTabType]) {
        if (self.typeViewController == nil) {
            self.typeViewController = [[RCTypePreferencesViewController alloc] initWithNibName:@"RCTypePreferencesView" bundle:nil];
        }
        return self.typeViewController;
    }

    if ([tabIdentifier isEqualToString:RCPreferencesTabExclude]) {
        if (self.excludeViewController == nil) {
            self.excludeViewController = [[RCExcludePreferencesViewController alloc] initWithNibName:@"RCExcludePreferencesView" bundle:nil];
        }
        return self.excludeViewController;
    }

    if ([tabIdentifier isEqualToString:RCPreferencesTabShortcuts]) {
        if (self.shortcutsViewController == nil) {
            self.shortcutsViewController = [[RCShortcutsPreferencesViewController alloc] initWithNibName:@"RCShortcutsPreferencesView" bundle:nil];
        }
        return self.shortcutsViewController;
    }

    if ([tabIdentifier isEqualToString:RCPreferencesTabUpdates]) {
        if (self.updatesViewController == nil) {
            self.updatesViewController = [[RCUpdatesPreferencesViewController alloc] initWithNibName:@"RCUpdatesPreferencesView" bundle:nil];
        }
        return self.updatesViewController;
    }


    if ([tabIdentifier isEqualToString:RCPreferencesTabPanic]) {
        if (self.panicViewController == nil) {
            self.panicViewController = [[RCPanicPreferencesViewController alloc] initWithNibName:@"RCPanicPreferencesView" bundle:nil];
        }
        return self.panicViewController;
    }

    return nil;
}

- (NSString *)titleForTabIdentifier:(NSString *)tabIdentifier {
    if ([tabIdentifier isEqualToString:RCPreferencesTabAppearance]) return RCLocalizedString(@"Appearance", nil);
    if ([tabIdentifier isEqualToString:RCPreferencesTabGeneral]) {
        return RCLocalizedString(@"General", nil);
    }
    if ([tabIdentifier isEqualToString:RCPreferencesTabMenu]) {
        return RCLocalizedString(@"Menu", nil);
    }
    if ([tabIdentifier isEqualToString:RCPreferencesTabType]) {
        return RCLocalizedString(@"Type", nil);
    }
    if ([tabIdentifier isEqualToString:RCPreferencesTabExclude]) {
        return RCLocalizedString(@"Excluded Apps", nil);
    }
    if ([tabIdentifier isEqualToString:RCPreferencesTabShortcuts]) {
        return RCLocalizedString(@"Shortcuts", nil);
    }
    if ([tabIdentifier isEqualToString:RCPreferencesTabUpdates]) {
        return RCLocalizedString(@"Updates", nil);
    }
    if ([tabIdentifier isEqualToString:RCPreferencesTabPanic]) {
        return RCLocalizedString(@"Panic", nil);
    }
    return @"";
}

- (NSString *)symbolNameForTabIdentifier:(NSString *)tabIdentifier {
    if ([tabIdentifier isEqualToString:RCPreferencesTabAppearance]) return @"circle.lefthalf.filled";
    if ([tabIdentifier isEqualToString:RCPreferencesTabGeneral]) {
        return @"gearshape";
    }
    if ([tabIdentifier isEqualToString:RCPreferencesTabMenu]) {
        return @"list.bullet";
    }
    if ([tabIdentifier isEqualToString:RCPreferencesTabType]) {
        return @"doc.on.doc";
    }
    if ([tabIdentifier isEqualToString:RCPreferencesTabExclude]) {
        return @"xmark.app";
    }
    if ([tabIdentifier isEqualToString:RCPreferencesTabShortcuts]) {
        return @"keyboard";
    }
    if ([tabIdentifier isEqualToString:RCPreferencesTabUpdates]) {
        return @"arrow.triangle.2.circlepath";
    }
    if ([tabIdentifier isEqualToString:RCPreferencesTabPanic]) {
        return @"exclamationmark.triangle";
    }
    return @"";
}

@end
