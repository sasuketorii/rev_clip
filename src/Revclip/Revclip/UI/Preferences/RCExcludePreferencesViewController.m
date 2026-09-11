#import "RCLocalization.h"
//
//  RCExcludePreferencesViewController.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import "RCExcludePreferencesViewController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "RCExcludeAppService.h"

static NSString * const kRCExcludeColumnIdentifierIcon = @"icon";
static NSString * const kRCExcludeColumnIdentifierName = @"name";

@interface RCExcludePreferencesViewController () <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, strong) RCExcludeAppService *excludeAppService;
@property (nonatomic, strong) NSMutableArray<NSString *> *excludedBundleIdentifiers;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSImage *> *iconCache;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *displayNameCache;

@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSButton *removeButton;
@property (nonatomic, strong, nullable) id activationObserver;

@end

@implementation RCExcludePreferencesViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.excludeAppService = [RCExcludeAppService shared];
    self.excludedBundleIdentifiers = [NSMutableArray array];
    self.iconCache = [NSMutableDictionary dictionary];
    self.displayNameCache = [NSMutableDictionary dictionary];

    [self startTrackingActiveApplication];
    [self configureUserInterface];
    [self reloadExcludedApplications];
}

- (void)dealloc {
    if (self.activationObserver != nil) {
        [[NSWorkspace sharedWorkspace].notificationCenter removeObserver:self.activationObserver];
        self.activationObserver = nil;
    }
}

- (void)startTrackingActiveApplication {
    NSString *ownBundleIdentifier = [NSBundle mainBundle].bundleIdentifier ?: @"";
    __weak typeof(self) weakSelf = self;
    self.activationObserver = [[NSWorkspace sharedWorkspace].notificationCenter
        addObserverForName:NSWorkspaceDidActivateApplicationNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *notification) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        NSRunningApplication *activatedApp = notification.userInfo[NSWorkspaceApplicationKey];
        NSString *activatedBundleId = activatedApp.bundleIdentifier ?: @"";
        if (activatedBundleId.length > 0 && ![activatedBundleId isEqualToString:ownBundleIdentifier]) {
            strongSelf.previousActiveApplication = activatedApp;
        }
    }];
}

#pragma mark - Layout

- (void)configureUserInterface {
    NSTextField *headerLabel = [NSTextField labelWithString:RCLocalizedString(@"Excluded Applications", nil)];
    headerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    headerLabel.font = [NSFont boldSystemFontOfSize:13.0];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.borderType = NSBezelBorder;
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = NO;
    scrollView.autohidesScrollers = YES;

    self.tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    self.tableView.usesAlternatingRowBackgroundColors = NO;
    self.tableView.allowsMultipleSelection = NO;
    self.tableView.allowsEmptySelection = YES;
    self.tableView.focusRingType = NSFocusRingTypeNone;
    self.tableView.rowHeight = 24.0;
    self.tableView.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    self.tableView.delegate = self;
    self.tableView.dataSource = self;

    NSTableColumn *iconColumn = [[NSTableColumn alloc] initWithIdentifier:kRCExcludeColumnIdentifierIcon];
    iconColumn.width = 24.0;
    iconColumn.minWidth = 24.0;
    iconColumn.maxWidth = 24.0;
    iconColumn.resizingMask = NSTableColumnNoResizing;
    iconColumn.editable = NO;
    iconColumn.title = @"";

    NSImageCell *iconCell = [[NSImageCell alloc] initImageCell:nil];
    iconCell.imageAlignment = NSImageAlignCenter;
    iconCell.imageScaling = NSImageScaleProportionallyDown;
    [iconColumn setDataCell:iconCell];

    NSTableColumn *nameColumn = [[NSTableColumn alloc] initWithIdentifier:kRCExcludeColumnIdentifierName];
    nameColumn.title = RCLocalizedString(@"Application", nil);
    nameColumn.minWidth = 120.0;
    nameColumn.editable = NO;

    NSTextFieldCell *nameCell = [[NSTextFieldCell alloc] initTextCell:@""];
    nameCell.editable = NO;
    nameCell.selectable = NO;
    nameCell.bordered = NO;
    nameCell.drawsBackground = NO;
    nameCell.lineBreakMode = NSLineBreakByTruncatingTail;
    [nameColumn setDataCell:nameCell];

    [self.tableView addTableColumn:iconColumn];
    [self.tableView addTableColumn:nameColumn];

    scrollView.documentView = self.tableView;

    NSButton *addButton = [NSButton buttonWithTitle:@"+" target:self action:@selector(addApplication:)];
    addButton.translatesAutoresizingMaskIntoConstraints = NO;
    addButton.bezelStyle = NSBezelStyleRounded;

    self.removeButton = [NSButton buttonWithTitle:@"-" target:self action:@selector(removeApplication:)];
    self.removeButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.removeButton.bezelStyle = NSBezelStyleRounded;
    self.removeButton.enabled = NO;

    NSButton *addCurrentButton = [NSButton buttonWithTitle:RCLocalizedString(@"Add Current App", nil) target:self action:@selector(addCurrentApplication:)];
    addCurrentButton.translatesAutoresizingMaskIntoConstraints = NO;
    addCurrentButton.bezelStyle = NSBezelStyleRounded;

    [self.view addSubview:headerLabel];
    [self.view addSubview:scrollView];
    [self.view addSubview:addButton];
    [self.view addSubview:self.removeButton];
    [self.view addSubview:addCurrentButton];

    [NSLayoutConstraint activateConstraints:@[
        [headerLabel.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:16.0],
        [headerLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20.0],

        [scrollView.topAnchor constraintEqualToAnchor:headerLabel.bottomAnchor constant:10.0],
        [scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20.0],
        [scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20.0],
        [scrollView.heightAnchor constraintEqualToConstant:250.0],

        [addButton.topAnchor constraintEqualToAnchor:scrollView.bottomAnchor constant:12.0],
        [addButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20.0],
        [addButton.widthAnchor constraintEqualToConstant:30.0],

        [self.removeButton.centerYAnchor constraintEqualToAnchor:addButton.centerYAnchor],
        [self.removeButton.leadingAnchor constraintEqualToAnchor:addButton.trailingAnchor constant:8.0],
        [self.removeButton.widthAnchor constraintEqualToConstant:30.0],

        [addCurrentButton.centerYAnchor constraintEqualToAnchor:addButton.centerYAnchor],
        [addCurrentButton.leadingAnchor constraintEqualToAnchor:self.removeButton.trailingAnchor constant:12.0],
        [addCurrentButton.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-20.0],

        [addButton.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.bottomAnchor constant:-16.0],
    ]];
}

#pragma mark - Actions

- (IBAction)addApplication:(id)sender {
    (void)sender;

    NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    openPanel.prompt = RCLocalizedString(@"Add", nil);
    openPanel.canChooseFiles = YES;
    openPanel.canChooseDirectories = NO;
    openPanel.canCreateDirectories = NO;
    openPanel.allowsMultipleSelection = NO;
    openPanel.resolvesAliases = YES;
    openPanel.treatsFilePackagesAsDirectories = NO;
    openPanel.directoryURL = [NSURL fileURLWithPath:@"/Applications" isDirectory:YES];
    openPanel.allowedContentTypes = @[UTTypeApplicationBundle];

    __weak typeof(self) weakSelf = self;
    NSWindow *window = self.view.window;
    if (window != nil) {
        [openPanel beginSheetModalForWindow:window completionHandler:^(NSModalResponse result) {
            if (result != NSModalResponseOK) {
                return;
            }
            [weakSelf addApplicationAtURL:openPanel.URL];
        }];
        return;
    }

    if ([openPanel runModal] != NSModalResponseOK) {
        return;
    }
    [self addApplicationAtURL:openPanel.URL];
}

- (IBAction)removeApplication:(id)sender {
    (void)sender;

    NSInteger selectedRow = self.tableView.selectedRow;
    if (selectedRow < 0 || selectedRow >= (NSInteger)self.excludedBundleIdentifiers.count) {
        return;
    }

    NSString *bundleIdentifier = self.excludedBundleIdentifiers[(NSUInteger)selectedRow];
    [self.excludeAppService removeExcludedBundleIdentifier:bundleIdentifier];
    [self reloadExcludedApplications];

    NSInteger nextRow = MIN(selectedRow, (NSInteger)self.excludedBundleIdentifiers.count - 1);
    if (nextRow >= 0) {
        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)nextRow] byExtendingSelection:NO];
    }
}

- (IBAction)addCurrentApplication:(id)sender {
    (void)sender;

    // First try the tracked previously active application (before Revclip came to front)
    NSRunningApplication *targetApp = self.previousActiveApplication;
    NSString *bundleIdentifier = targetApp.bundleIdentifier ?: @"";
    NSString *ownBundleIdentifier = [NSBundle mainBundle].bundleIdentifier ?: @"";

    // Fall back to frontmostApplication if tracking didn't capture anything
    if (bundleIdentifier.length == 0 || [bundleIdentifier isEqualToString:ownBundleIdentifier]) {
        targetApp = [NSWorkspace sharedWorkspace].frontmostApplication;
        bundleIdentifier = targetApp.bundleIdentifier ?: @"";
    }

    if (bundleIdentifier.length == 0 || [bundleIdentifier isEqualToString:ownBundleIdentifier]) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleInformational;
        alert.messageText = RCLocalizedString(@"Cannot add current application", nil);
        alert.informativeText = RCLocalizedString(@"No other application was detected. Please switch to the application you want to exclude, then click this button.", nil);
        [alert addButtonWithTitle:RCLocalizedString(@"OK", nil)];

        NSWindow *window = self.view.window;
        if (window != nil) {
            [alert beginSheetModalForWindow:window completionHandler:nil];
        } else {
            [alert runModal];
        }
        return;
    }

    [self addExcludedBundleIdentifier:bundleIdentifier];
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView;
    return (NSInteger)self.excludedBundleIdentifiers.count;
}

- (nullable id)tableView:(NSTableView *)tableView objectValueForTableColumn:(nullable NSTableColumn *)tableColumn row:(NSInteger)row {
    (void)tableView;

    if (tableColumn == nil || row < 0 || row >= (NSInteger)self.excludedBundleIdentifiers.count) {
        return nil;
    }

    NSString *bundleIdentifier = self.excludedBundleIdentifiers[(NSUInteger)row];
    if ([tableColumn.identifier isEqualToString:kRCExcludeColumnIdentifierIcon]) {
        return [self iconForBundleIdentifier:bundleIdentifier];
    }

    return [self displayNameForBundleIdentifier:bundleIdentifier];
}

#pragma mark - NSTableViewDelegate

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    (void)notification;
    [self updateRemoveButtonState];
}

#pragma mark - Private

- (void)reloadExcludedApplications {
    NSArray<NSString *> *bundleIdentifiers = [self.excludeAppService excludedBundleIdentifiers];
    [self.excludedBundleIdentifiers removeAllObjects];
    [self.excludedBundleIdentifiers addObjectsFromArray:bundleIdentifiers];
    [self.iconCache removeAllObjects];
    [self.displayNameCache removeAllObjects];

    [self.tableView reloadData];
    [self updateRemoveButtonState];
}

- (void)addApplicationAtURL:(nullable NSURL *)applicationURL {
    if (applicationURL == nil) {
        return;
    }

    NSBundle *applicationBundle = [NSBundle bundleWithURL:applicationURL];
    NSString *bundleIdentifier = applicationBundle.bundleIdentifier ?: @"";
    [self addExcludedBundleIdentifier:bundleIdentifier];
}

- (void)addExcludedBundleIdentifier:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0) {
        NSBeep();
        return;
    }

    [self.excludeAppService addExcludedBundleIdentifier:bundleIdentifier];
    [self reloadExcludedApplications];
    [self selectRowForBundleIdentifier:bundleIdentifier];
}

- (void)selectRowForBundleIdentifier:(NSString *)bundleIdentifier {
    NSUInteger rowIndex = [self.excludedBundleIdentifiers indexOfObject:bundleIdentifier];
    if (rowIndex == NSNotFound) {
        [self.tableView deselectAll:nil];
        return;
    }

    [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:rowIndex] byExtendingSelection:NO];
    [self.tableView scrollRowToVisible:(NSInteger)rowIndex];
}

- (void)updateRemoveButtonState {
    self.removeButton.enabled = self.tableView.selectedRow >= 0;
}

- (NSString *)displayNameForBundleIdentifier:(NSString *)bundleIdentifier {
    NSString *cachedName = self.displayNameCache[bundleIdentifier];
    if (cachedName.length > 0) {
        return cachedName;
    }

    NSString *displayName = @"";
    NSURL *applicationURL = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:bundleIdentifier];
    if (applicationURL.path.length > 0) {
        displayName = [[NSFileManager defaultManager] displayNameAtPath:applicationURL.path];
        if (displayName.length == 0) {
            displayName = applicationURL.lastPathComponent.stringByDeletingPathExtension ?: @"";
        }
    }

    if (displayName.length == 0) {
        displayName = bundleIdentifier;
    }

    self.displayNameCache[bundleIdentifier] = displayName;
    return displayName;
}

- (NSImage *)iconForBundleIdentifier:(NSString *)bundleIdentifier {
    NSImage *cachedIcon = self.iconCache[bundleIdentifier];
    if (cachedIcon != nil) {
        return cachedIcon;
    }

    NSURL *applicationURL = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:bundleIdentifier];
    NSImage *icon = nil;
    if (applicationURL.path.length > 0) {
        icon = [[NSWorkspace sharedWorkspace] iconForFile:applicationURL.path];
    }
    if (icon == nil) {
        icon = [NSImage imageNamed:NSImageNameApplicationIcon];
    }

    NSImage *scaledIcon = [icon copy];
    scaledIcon.size = NSMakeSize(16.0, 16.0);
    self.iconCache[bundleIdentifier] = scaledIcon;
    return scaledIcon;
}

@end
