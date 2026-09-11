#import "RCLocalization.h"
#import "RCFastPreviewController.h"
//
//  RCMenuManager.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import "RCMenuManager.h"
#import "Revclip-Swift.h"
#import "RCStorageMigration.h"

#import "RCClipboardService.h"
#import "RCClipData.h"
#import "RCClipItem.h"
#import "RCConstants.h"
#import "RCDatabaseManager.h"
#import "RCHotKeyService.h"
#import "RCPanicEraseService.h"
#import "RCPasteService.h"
#import "FMDB.h"
#import "NSColor+HexString.h"
#import "NSImage+Color.h"
#import "NSImage+Resize.h"
#import "RCUtilities.h"
#import <os/log.h>

static NSString * const kRCStatusBarIconAssetName = @"StatusBarIcon";
static NSInteger const kRCMaximumNumberedMenuItems = 9;
static NSString * const kRCMemoryWarningNotificationName = @"NSApplicationDidReceiveMemoryWarningNotification";
static NSString * const kRCClipDataFileExtension = @"rcclip";
static NSString * const kRCThumbnailFileExtension = @"thumb";
static NSString * const kRCLegacyThumbnailFileSuffix = @".thumbnail.tiff";
static NSString * const kRCSnippetMenuFolderIdentifierKey = @"folderIdentifier";
static NSString * const kRCSnippetMenuSnippetIdentifierKey = @"snippetIdentifier";
static NSInteger const kRCClipDataFallbackPrefetchStateInFlight = 1;
static NSInteger const kRCClipDataFallbackPrefetchStateDone = 2;

static os_log_t RCMenuManagerLog(void) {
    static os_log_t logger = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        logger = os_log_create("com.revclip", "RCMenuManager");
    });
    return logger;
}

@interface RCMenuManager () <NSMenuDelegate>

@property (nonatomic, strong, nullable) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenu *statusMenu;
@property (nonatomic, strong) NSMapTable<NSMenuItem *, NSString *> *previewTexts;
@property (nonatomic, strong) RCFastPreviewController *previewController;
@property (nonatomic, strong, nullable) dispatch_block_t defaultsChangeDebounceBlock;
@property (nonatomic, strong) NSCache<NSString *, NSImage *> *thumbnailCache;
@property (nonatomic, strong) NSCache<NSString *, NSNumber *> *colorPreviewEligibilityCache;
@property (nonatomic, strong) NSCache<NSString *, NSString *> *clipDataColorStringCache;
@property (nonatomic, strong) NSCache<NSString *, NSString *> *clipDataTooltipCache;
@property (nonatomic, strong) NSCache<NSString *, NSNumber *> *clipDataFallbackPrefetchStateCache;
@property (nonatomic, strong) dispatch_queue_t thumbnailGenerationQueue;
@property (nonatomic, strong) dispatch_queue_t clipDataFallbackQueue;
@property (nonatomic, strong, nullable) NSRunningApplication *pasteTargetApplication;

- (void)prefetchThumbnailsForClipItems:(NSArray<RCClipItem *> *)clipItems;
- (NSString *)thumbnailCacheKeyForClipItem:(RCClipItem *)clipItem;
- (void)loadThumbnailForClipItem:(RCClipItem *)clipItem
                        cacheKey:(NSString *)cacheKey
                updatingMenuItem:(NSMenuItem *)menuItem
                    numberPrefix:(NSString *)numberPrefix
                       baseTitle:(NSString *)baseTitle;
- (nullable NSImage *)resizedThumbnailImageAtPath:(NSString *)thumbnailPath targetSize:(NSSize)targetSize;
- (NSString *)colorPreviewCacheKeyForClipItem:(RCClipItem *)clipItem;
- (BOOL)shouldTreatClipItemAsColorCandidate:(RCClipItem *)clipItem;
- (void)cacheColorPreviewEligibility:(BOOL)isEligible forClipItem:(RCClipItem *)clipItem;
- (void)prefetchClipDataFallbackForClipItems:(NSArray<RCClipItem *> *)clipItems;
- (void)prefetchClipDataFallbackForClipItems:(NSArray<RCClipItem *> *)clipItems
                                  completion:(nullable dispatch_block_t)completion;
- (nullable NSString *)cachedTooltipForClipItem:(RCClipItem *)clipItem;
- (nullable NSString *)cachedColorStringForClipItem:(RCClipItem *)clipItem;
- (nullable NSImage *)colorPreviewImageForClipItem:(RCClipItem *)clipItem;
- (nullable RCClipData *)clipDataForPath:(NSString *)dataPath;
- (NSArray<NSString *> *)clipDataFilePathsSnapshotForCurrentHistoryWithDatabaseManager:(RCDatabaseManager *)databaseManager;
- (void)removeClipDataFilesAtPaths:(NSArray<NSString *> *)paths;
- (nullable NSString *)snippetContentForFolderIdentifier:(NSString *)folderIdentifier snippetIdentifier:(NSString *)snippetIdentifier;
- (void)handleMissingClipDataForClipItem:(RCClipItem *)clipItem reason:(NSString *)reason;
- (BOOL)isKnownClipDataFileName:(NSString *)fileName;
- (NSRange)composedSafePrefixRangeForString:(NSString *)string maxLength:(NSUInteger)maxLength;
- (NSString *)menuBaseTitleForClipItem:(RCClipItem *)clipItem;
- (NSString *)menuNumberPrefixForGlobalIndex:(NSUInteger)globalIndex;
- (void)pasteClipWithDataHash:(NSString *)dataHash
            targetApplication:(nullable NSRunningApplication *)application;
- (void)appendSnippetDictionaries:(NSArray<NSDictionary *> *)snippets
                 folderIdentifier:(NSString *)folderIdentifier
                           toMenu:(NSMenu *)menu;
- (void)handleSnippetsDidChange:(NSNotification *)notification;
- (void)applyMenuItemTitleForItem:(NSMenuItem *)item
                     numberPrefix:(NSString *)numberPrefix
                        baseTitle:(NSString *)baseTitle
                            image:(nullable NSImage *)image;
- (void)applyNativeAppearanceToMenuItem:(NSMenuItem *)item
                          title:(NSString *)title
                         number:(nullable NSString *)number
                          image:(nullable NSImage *)image
                submenuChevron:(BOOL)submenuChevron;
- (void)setToolTip:(nullable NSString *)toolTip onMenuItem:(NSMenuItem *)item;
- (void)capturePasteTargetApplication;
- (nullable NSImage *)templateSymbolNamed:(NSString *)symbolName;

@end

@implementation RCMenuManager

+ (instancetype)shared {
    static RCMenuManager *sharedManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedManager = [[self alloc] init];
    });
    return sharedManager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _previewTexts = [NSMapTable weakToStrongObjectsMapTable];
        _previewController = [RCFastPreviewController new];
        _statusMenu = [self menuWithTitle:@"Revclip"];
        _thumbnailCache = [[NSCache alloc] init];
        _colorPreviewEligibilityCache = [[NSCache alloc] init];
        _clipDataColorStringCache = [[NSCache alloc] init];
        _clipDataTooltipCache = [[NSCache alloc] init];
        _clipDataFallbackPrefetchStateCache = [[NSCache alloc] init];
        _thumbnailGenerationQueue = dispatch_queue_create("com.revclip.menu.thumbnail", DISPATCH_QUEUE_CONCURRENT);
        _clipDataFallbackQueue = dispatch_queue_create("com.revclip.menu.clipdata-fallback", DISPATCH_QUEUE_SERIAL);

        NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
        [notificationCenter addObserver:self
                               selector:@selector(handleClipboardDidChange:)
                                   name:RCClipboardDidChangeNotification
                                 object:nil];
        [notificationCenter addObserver:self
                               selector:@selector(handleUserDefaultsDidChange:)
                                   name:NSUserDefaultsDidChangeNotification
                                 object:nil];
        [notificationCenter addObserver:self
                               selector:@selector(handleHotKeyMainTriggered:)
                                   name:RCHotKeyMainTriggeredNotification
                                 object:nil];
        [notificationCenter addObserver:self
                               selector:@selector(handleHotKeyHistoryTriggered:)
                                   name:RCHotKeyHistoryTriggeredNotification
                                 object:nil];
        [notificationCenter addObserver:self
                               selector:@selector(handleHotKeySnippetTriggered:)
                                   name:RCHotKeySnippetTriggeredNotification
                                 object:nil];
        [notificationCenter addObserver:self
                               selector:@selector(handleHotKeyClearHistoryTriggered:)
                                   name:RCHotKeyClearHistoryTriggeredNotification
                                 object:nil];
        [notificationCenter addObserver:self
                               selector:@selector(handleHotKeySnippetFolderTriggered:)
                                   name:RCHotKeySnippetFolderTriggeredNotification
                                 object:nil];
        [notificationCenter addObserver:self
                               selector:@selector(handleApplicationDidReceiveMemoryWarning:)
                                   name:kRCMemoryWarningNotificationName
                                 object:nil];
        [notificationCenter addObserver:self
                               selector:@selector(handleSnippetsDidChange:)
                                   name:RCSnippetsDidChangeNotification
                                 object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Public

- (void)setupStatusItem {
    [self performOnMainThread:^{
        [self applyStatusItemPreference];
        [self rebuildMenuInternal];
    }];
}

- (void)rebuildMenu {
    [self performOnMainThread:^{
        [self applyStatusItemPreference];
        [self rebuildMenuInternal];
    }];
}

#pragma mark - Notification

- (void)handleClipboardDidChange:(NSNotification *)notification {
    (void)notification;
    [self rebuildMenu];
}

- (void)handleUserDefaultsDidChange:(NSNotification *)notification {
    (void)notification;

    [self.thumbnailCache removeAllObjects];
    [self.colorPreviewEligibilityCache removeAllObjects];
    [self.clipDataColorStringCache removeAllObjects];
    [self.clipDataTooltipCache removeAllObjects];
    [self.clipDataFallbackPrefetchStateCache removeAllObjects];

    if (self.defaultsChangeDebounceBlock != nil) {
        dispatch_block_cancel(self.defaultsChangeDebounceBlock);
    }

    dispatch_block_t debounceBlock = dispatch_block_create(0, ^{
        [self setupStatusItem];
    });
    self.defaultsChangeDebounceBlock = debounceBlock;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(),
                   debounceBlock);
}

- (void)handleHotKeyMainTriggered:(NSNotification *)notification {
    (void)notification;
    [self popUpStatusMenuFromHotKey];
}

- (void)handleHotKeyHistoryTriggered:(NSNotification *)notification {
    (void)notification;
    [self popUpHistoryMenuFromHotKey];
}

- (void)handleHotKeySnippetTriggered:(NSNotification *)notification {
    (void)notification;
    [self popUpSnippetMenuFromHotKey];
}

- (void)handleHotKeyClearHistoryTriggered:(NSNotification *)notification {
    (void)notification;
    [self performOnMainThread:^{
        [self clearHistoryMenuItemSelected:nil];
    }];
}

- (void)handleHotKeySnippetFolderTriggered:(NSNotification *)notification {
    id rawIdentifier = notification.userInfo[RCHotKeyFolderIdentifierUserInfoKey];
    NSString *identifier = [rawIdentifier isKindOfClass:[NSString class]] ? (NSString *)rawIdentifier : @"";
    if (identifier.length == 0) {
        return;
    }

    [self popUpSnippetFolderMenuFromHotKeyWithIdentifier:identifier];
}

- (void)handleSnippetsDidChange:(NSNotification *)notification {
    (void)notification;
    [self rebuildMenu];
}

- (void)handleApplicationDidReceiveMemoryWarning:(NSNotification *)notification {
    (void)notification;
    [self.thumbnailCache removeAllObjects];
    [self.colorPreviewEligibilityCache removeAllObjects];
    [self.clipDataColorStringCache removeAllObjects];
    [self.clipDataTooltipCache removeAllObjects];
    [self.clipDataFallbackPrefetchStateCache removeAllObjects];
}

#pragma mark - Status Item

- (void)applyStatusItemPreference {
    NSInteger statusItemStyle = [self integerPreferenceForKey:kRCPrefShowStatusItemKey defaultValue:1];

    if (statusItemStyle == 0) {
        [self removeStatusItemIfNeeded];
        return;
    }

    if (self.statusItem == nil) {
        self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    }

    NSStatusBarButton *button = self.statusItem.button;
    if (button != nil) {
        button.image = [self statusBarIconImage];
        button.imagePosition = NSImageOnly;
        button.target = nil;
        button.action = nil;
    }

    [self configureMenuForSimpleTransparentBackground:self.statusMenu];
    self.statusItem.menu = self.statusMenu;
}

- (void)removeStatusItemIfNeeded {
    if (self.statusItem == nil) {
        return;
    }

    [[NSStatusBar systemStatusBar] removeStatusItem:self.statusItem];
    self.statusItem = nil;
}

- (NSImage *)statusBarIconImage {
    NSImage *image = [NSImage imageNamed:kRCStatusBarIconAssetName];
    if (image == nil) {
        image = [NSImage imageNamed:NSImageNameSmartBadgeTemplate];
    }
    if (image == nil) {
        image = [NSImage imageWithSystemSymbolName:@"doc.on.clipboard" accessibilityDescription:@"Revclip"];
    }

    if (image == nil) {
        image = [[NSImage alloc] initWithSize:NSMakeSize(18.0, 18.0)];
    }

    image.template = YES;
    return image;
}

- (void)popUpStatusMenuFromHotKey {
    [self performOnMainThread:^{
        [self capturePasteTargetApplication];
        [self applyStatusItemPreference];

        if (self.statusItem != nil) {
            [self rebuildMenuInternal];
            NSPoint mouseLocation = [NSEvent mouseLocation];
            [self.statusMenu popUpMenuPositioningItem:nil atLocation:mouseLocation inView:nil];
        } else {
            NSMenu *fallbackMenu = [self buildStandaloneMenu];
            NSPoint mouseLocation = [NSEvent mouseLocation];
            [fallbackMenu popUpMenuPositioningItem:nil atLocation:mouseLocation inView:nil];
        }
    }];
}

- (void)popUpHistoryMenuFromHotKey {
    [self performOnMainThread:^{
        [self capturePasteTargetApplication];
        [self applyStatusItemPreference];
        NSMenu *menu = [self menuWithTitle:@"History"];
        [self appendClipHistorySectionToMenu:menu];
        [menu addItem:[NSMenuItem separatorItem]];
        [self appendApplicationSectionToMenu:menu];
        [self popUpTransientMenu:menu];
    }];
}

- (void)popUpSnippetMenuFromHotKey {
    [self performOnMainThread:^{
        [self capturePasteTargetApplication];
        [self applyStatusItemPreference];
        NSMenu *menu = [self menuWithTitle:@"Snippets"];
        [self appendSnippetSectionToMenu:menu];
        [menu addItem:[NSMenuItem separatorItem]];
        [self appendApplicationSectionToMenu:menu];
        [self popUpTransientMenu:menu];
    }];
}

- (void)popUpSnippetFolderMenuFromHotKeyWithIdentifier:(NSString *)folderIdentifier {
    if (folderIdentifier.length == 0) {
        return;
    }

    [self performOnMainThread:^{
        [self applyStatusItemPreference];
        NSDictionary *targetFolder = nil;
        for (NSDictionary *folder in [[RCDatabaseManager shared] fetchAllSnippetFolders]) {
            NSString *identifier = [self stringValueFromDictionary:folder key:@"identifier" defaultValue:@""];
            if (![identifier isEqualToString:folderIdentifier]) {
                continue;
            }

            BOOL enabled = [self boolValueFromDictionary:folder key:@"enabled" defaultValue:YES];
            if (!enabled) {
                return;
            }

            targetFolder = folder;
            break;
        }

        if (targetFolder == nil) {
            return;
        }

        NSString *title = [self stringValueFromDictionary:targetFolder key:@"title" defaultValue:@""];
        if (title.length == 0) {
            title = RCLocalizedString(@"Untitled Folder", nil);
        }

        NSMenu *menu = [self menuWithTitle:title];
        [self appendSnippetsForFolderIdentifier:folderIdentifier toMenu:menu];
        [menu addItem:[NSMenuItem separatorItem]];
        [self appendApplicationSectionToMenu:menu];
        [self popUpTransientMenu:menu];
    }];
}

- (void)popUpTransientMenu:(NSMenu *)menu {
    if (menu == nil) {
        return;
    }

    [self capturePasteTargetApplication];
    [self configureMenuForSimpleTransparentBackground:menu];
    NSPoint mouseLocation = [NSEvent mouseLocation];
    [menu popUpMenuPositioningItem:nil atLocation:mouseLocation inView:nil];
}

#pragma mark - Menu Build

- (void)rebuildMenuInternal {
    [self.previewController hide];
    if (self.statusItem == nil) {
        return;
    }

    [self configureMenuForSimpleTransparentBackground:self.statusMenu];
    [self.statusMenu removeAllItems];
    [self appendClipHistorySectionToMenu:self.statusMenu];
    [self.statusMenu addItem:[NSMenuItem separatorItem]];
    [self appendSnippetSectionToMenu:self.statusMenu];

    BOOL addClearHistory = [self boolPreferenceForKey:kRCPrefAddClearHistoryMenuItemKey defaultValue:YES];
    [self.statusMenu addItem:[NSMenuItem separatorItem]];
    if (addClearHistory) {
        NSMenuItem *clearHistoryItem = [[NSMenuItem alloc] initWithTitle:RCLocalizedString(@"Clear History", nil)
                                                                   action:@selector(clearHistoryMenuItemSelected:)
                                                            keyEquivalent:@""];
        clearHistoryItem.target = self;
        [self applyNativeAppearanceToMenuItem:clearHistoryItem
                                title:RCLocalizedString(@"Clear History", nil)
                               number:nil
                                image:[self templateSymbolNamed:@"trash"]
                      submenuChevron:NO];
        [self.statusMenu addItem:clearHistoryItem];
    }

    [self.statusMenu addItem:[NSMenuItem separatorItem]];
    [self appendApplicationSectionToMenu:self.statusMenu];
    self.statusItem.menu = self.statusMenu;
}

- (NSMenu *)buildStandaloneMenu {
    NSMenu *menu = [self menuWithTitle:@"Revclip"];
    [self appendClipHistorySectionToMenu:menu];
    [menu addItem:[NSMenuItem separatorItem]];
    [self appendSnippetSectionToMenu:menu];

    BOOL addClearHistory = [self boolPreferenceForKey:kRCPrefAddClearHistoryMenuItemKey defaultValue:YES];
    [menu addItem:[NSMenuItem separatorItem]];
    if (addClearHistory) {
        NSMenuItem *clearHistoryItem = [[NSMenuItem alloc] initWithTitle:RCLocalizedString(@"Clear History", nil)
                                                                   action:@selector(clearHistoryMenuItemSelected:)
                                                            keyEquivalent:@""];
        clearHistoryItem.target = self;
        [self applyNativeAppearanceToMenuItem:clearHistoryItem
                                title:RCLocalizedString(@"Clear History", nil)
                               number:nil
                                image:[self templateSymbolNamed:@"trash"]
                      submenuChevron:NO];
        [menu addItem:clearHistoryItem];
    }

    [menu addItem:[NSMenuItem separatorItem]];
    [self appendApplicationSectionToMenu:menu];
    return menu;
}

- (void)appendClipHistorySectionToMenu:(NSMenu *)menu {
    RCDatabaseManager *databaseManager = [RCDatabaseManager shared];
    NSInteger maxHistorySize = [self integerPreferenceForKey:kRCPrefMaxHistorySizeKey defaultValue:30];
    NSInteger limit = MAX(1, maxHistorySize);
    NSArray<NSDictionary *> *clipRows = @[];
    if ([databaseManager clipItemCount] > 0) {
        clipRows = [databaseManager fetchClipItemsWithLimit:limit];
    }

    if (clipRows.count == 0) {
        NSMenuItem *noHistoryItem = [[NSMenuItem alloc] initWithTitle:RCLocalizedString(@"No History", nil)
                                                               action:nil
                                                        keyEquivalent:@""];
        noHistoryItem.enabled = NO;
        [menu addItem:noHistoryItem];
        return;
    }

    NSMutableArray<RCClipItem *> *clipItems = [NSMutableArray arrayWithCapacity:clipRows.count];
    for (NSDictionary *row in clipRows) {
        [clipItems addObject:[[RCClipItem alloc] initWithDictionary:row]];
    }
    [self prefetchThumbnailsForClipItems:clipItems];
    [self prefetchClipDataFallbackForClipItems:clipItems];
    [self appendClipItems:clipItems toMenu:menu];
}

- (void)appendClipItems:(NSArray<RCClipItem *> *)clipItems toMenu:(NSMenu *)menu {
    NSUInteger inlineLimit = (NSUInteger)MAX(0, [self integerPreferenceForKey:kRCPrefNumberOfItemsPlaceInlineKey defaultValue:0]);
    NSUInteger folderChunkSize = (NSUInteger)MAX(1, [self integerPreferenceForKey:kRCPrefNumberOfItemsPlaceInsideFolderKey defaultValue:10]);

    NSUInteger inlineCount = MIN(inlineLimit, clipItems.count);
    for (NSUInteger index = 0; index < inlineCount; index++) {
        NSMenuItem *menuItem = [self clipMenuItemForClipItem:clipItems[index] globalIndex:index];
        [menu addItem:menuItem];
    }

    for (NSUInteger groupStart = inlineCount; groupStart < clipItems.count; groupStart += folderChunkSize) {
        NSUInteger groupEnd = MIN(groupStart + folderChunkSize, clipItems.count);
        NSString *folderTitle = [NSString stringWithFormat:RCLocalizedString(@"Items %lu-%lu", nil),
                                 (unsigned long)(groupStart + 1),
                                 (unsigned long)groupEnd];

        NSMenuItem *folderItem = [[NSMenuItem alloc] initWithTitle:folderTitle
                                                             action:nil
                                                      keyEquivalent:@""];
        NSMenu *folderMenu = [self menuWithTitle:folderTitle];
        folderItem.submenu = folderMenu;
        [self applyNativeAppearanceToMenuItem:folderItem
                                title:folderTitle
                               number:nil
                                image:nil
                      submenuChevron:YES];

        for (NSUInteger index = groupStart; index < groupEnd; index++) {
            NSMenuItem *menuItem = [self clipMenuItemForClipItem:clipItems[index] globalIndex:index];
            [folderMenu addItem:menuItem];
        }

        [menu addItem:folderItem];
    }
}

- (void)appendSnippetSectionToMenu:(NSMenu *)menu {
    NSArray<NSDictionary *> *folders = [[RCDatabaseManager shared] fetchSnippetCatalog];
    if (folders == nil) {
        NSMenuItem *errorItem = [[NSMenuItem alloc] initWithTitle:RCLocalizedString(@"Failed to read snippets. Please try again.", nil)
                                                                       action:nil keyEquivalent:@""];
        errorItem.enabled = NO;
        [menu addItem:errorItem];
        return;
    }
    BOOL hasAtLeastOneFolder = NO;

    for (NSDictionary *folder in folders) {
        BOOL enabled = [self boolValueFromDictionary:folder key:@"enabled" defaultValue:YES];
        if (!enabled) {
            continue;
        }

        NSString *identifier = [self stringValueFromDictionary:folder key:@"identifier" defaultValue:@""];
        if (identifier.length == 0) {
            continue;
        }

        NSString *title = [self stringValueFromDictionary:folder key:@"title" defaultValue:@""];
        if (title.length == 0) {
            title = RCLocalizedString(@"Untitled Folder", nil);
        }

        NSMenuItem *folderItem = [[NSMenuItem alloc] initWithTitle:title
                                                             action:nil
                                                      keyEquivalent:@""];
        NSMenu *folderMenu = [self menuWithTitle:title];
        folderItem.submenu = folderMenu;
        [self applyNativeAppearanceToMenuItem:folderItem
                                title:title
                               number:nil
                                image:[self templateSymbolNamed:@"folder"]
                      submenuChevron:YES];
        [menu addItem:folderItem];
        hasAtLeastOneFolder = YES;
        id rawSnippets = folder[@"snippets"];
        NSArray<NSDictionary *> *snippets = [rawSnippets isKindOfClass:[NSArray class]] ? rawSnippets : @[];
        [self appendSnippetDictionaries:snippets
                       folderIdentifier:identifier
                                 toMenu:folderMenu];
    }

    if (!hasAtLeastOneFolder) {
        NSMenuItem *noSnippetsItem = [[NSMenuItem alloc] initWithTitle:RCLocalizedString(@"No Snippets", nil)
                                                                 action:nil
                                                          keyEquivalent:@""];
        noSnippetsItem.enabled = NO;
        [menu addItem:noSnippetsItem];
    }
}

- (void)appendSnippetsForFolderIdentifier:(NSString *)folderIdentifier toMenu:(NSMenu *)menu {
    if (folderIdentifier.length == 0 || menu == nil) {
        return;
    }

    NSArray<NSDictionary *> *snippets = [[RCDatabaseManager shared] fetchSnippetsForFolder:folderIdentifier];
    [self appendSnippetDictionaries:snippets folderIdentifier:folderIdentifier toMenu:menu];
}

- (void)appendSnippetDictionaries:(NSArray<NSDictionary *> *)snippets
                 folderIdentifier:(NSString *)folderIdentifier
                           toMenu:(NSMenu *)menu {
    if (menu == nil) {
        return;
    }

    BOOL hasSnippet = NO;
    for (NSDictionary *snippet in snippets) {
        BOOL snippetEnabled = [self boolValueFromDictionary:snippet key:@"enabled" defaultValue:YES];
        if (!snippetEnabled) {
            continue;
        }

        NSString *snippetIdentifier = [self stringValueFromDictionary:snippet key:@"identifier" defaultValue:@""];
        if (snippetIdentifier.length == 0) {
            continue;
        }

        NSString *snippetTitle = [self stringValueFromDictionary:snippet key:@"title" defaultValue:@""];
        NSString *snippetContent = [self stringValueFromDictionary:snippet key:@"content" defaultValue:@""];

        if (snippetTitle.length == 0 && snippetContent.length > 0) {
            snippetTitle = [self truncatedString:snippetContent maxLength:24];
        }
        if (snippetTitle.length == 0) {
            snippetTitle = RCLocalizedString(@"Untitled Snippet", nil);
        }

        NSMenuItem *snippetItem = [[NSMenuItem alloc] initWithTitle:snippetTitle
                                                              action:@selector(selectSnippetMenuItem:)
                                                       keyEquivalent:@""];
        snippetItem.target = self;
        if (snippetContent.length > 0) {
            [self setToolTip:[self truncatedString:snippetContent maxLength:200] onMenuItem:snippetItem];
        }
        snippetItem.representedObject = @{
            kRCSnippetMenuFolderIdentifierKey: folderIdentifier,
            kRCSnippetMenuSnippetIdentifierKey: snippetIdentifier,
        };
        [self applyNativeAppearanceToMenuItem:snippetItem
                                title:snippetTitle
                               number:nil
                                image:[self templateSymbolNamed:@"doc.text"]
                      submenuChevron:NO];
        [menu addItem:snippetItem];
        hasSnippet = YES;
    }

    if (!hasSnippet) {
        NSMenuItem *emptyItem = [[NSMenuItem alloc] initWithTitle:RCLocalizedString(@"(Empty)", nil)
                                                           action:nil
                                                    keyEquivalent:@""];
        emptyItem.enabled = NO;
        [menu addItem:emptyItem];
    }
}

- (void)appendApplicationSectionToMenu:(NSMenu *)menu {
    NSMenuItem *preferencesItem = [[NSMenuItem alloc] initWithTitle:RCLocalizedString(@"Preferences...", nil)
                                                              action:@selector(openPreferences:)
                                                       keyEquivalent:@","];
    preferencesItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    preferencesItem.target = self;
    [self applyNativeAppearanceToMenuItem:preferencesItem
                            title:RCLocalizedString(@"Preferences...", nil)
                           number:nil
                            image:[self templateSymbolNamed:@"gearshape"]
                  submenuChevron:NO];
    [menu addItem:preferencesItem];

    NSMenuItem *editSnippetsItem = [[NSMenuItem alloc] initWithTitle:RCLocalizedString(@"Edit Templates...", nil)
                                                               action:@selector(openSnippetEditor:)
                                                        keyEquivalent:@""];
    editSnippetsItem.target = self;
    [self applyNativeAppearanceToMenuItem:editSnippetsItem
                            title:RCLocalizedString(@"Edit Templates...", nil)
                           number:nil
                            image:[self templateSymbolNamed:@"square.and.pencil"]
                  submenuChevron:NO];
    [menu addItem:editSnippetsItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:RCLocalizedString(@"Quit Revclip", nil)
                                                       action:@selector(terminate:)
                                                keyEquivalent:@"q"];
    quitItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    quitItem.target = NSApp;
    [self applyNativeAppearanceToMenuItem:quitItem
                            title:RCLocalizedString(@"Quit Revclip", nil)
                           number:nil
                            image:nil
                  submenuChevron:NO];
    [menu addItem:quitItem];
}

- (NSMenu *)menuWithTitle:(NSString *)title {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:title ?: @""];
    menu.delegate = self;
    menu.minimumWidth = 300.0;
    [self configureMenuForSimpleTransparentBackground:menu];
    return menu;
}

- (void)menu:(NSMenu *)menu willHighlightItem:(NSMenuItem *)item {
    [self.previewController highlightItem:item text:[self previewTextForMenuItem:item]];
}

- (void)menuDidClose:(NSMenu *)menu {
    [self.previewController hide];
}

- (NSString *)previewTextForMenuItem:(NSMenuItem *)item {
    return item ? [self.previewTexts objectForKey:item] : nil;
}

- (void)menuWillOpen:(NSMenu *)menu {
    [self.previewController hide];
    if (menu.supermenu == nil) {
        [self capturePasteTargetApplication];
    }
    [self configureMenuForSimpleTransparentBackground:menu];
}

- (void)capturePasteTargetApplication {
    NSRunningApplication *front = [NSWorkspace sharedWorkspace].frontmostApplication;
    NSString *ownBundle = NSBundle.mainBundle.bundleIdentifier;
    self.pasteTargetApplication = (front != nil && !front.terminated &&
        ![front.bundleIdentifier isEqualToString:ownBundle]) ? front : nil;
}

- (void)configureMenuForSimpleTransparentBackground:(NSMenu *)menu {
    if (menu == nil) {
        return;
    }

    // Keep native menu behavior while honoring the app-wide appearance preference.
    menu.appearance = NSApp.appearance;
}

#pragma mark - Clip Menu Item

- (NSMenuItem *)clipMenuItemForClipItem:(RCClipItem *)clipItem globalIndex:(NSUInteger)globalIndex {
    NSString *baseTitle = [self menuBaseTitleForClipItem:clipItem];
    NSString *numberPrefix = [self menuNumberPrefixForGlobalIndex:globalIndex];
    NSString *menuTitle = [self menuTitleForClipItem:clipItem globalIndex:globalIndex];

    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:menuTitle
                                                  action:@selector(selectClipMenuItem:)
                                           keyEquivalent:@""];
    item.target = self;
    item.representedObject = clipItem.dataHash ?: @"";
    [self applyNativeAppearanceToMenuItem:item
                            title:baseTitle
                           number:numberPrefix
                            image:nil
                  submenuChevron:NO];

    BOOL needsTooltip = [self boolPreferenceForKey:kRCShowToolTipOnMenuItemKey defaultValue:YES];
    BOOL showImagePreview = [self boolPreferenceForKey:kRCShowImageInTheMenuKey defaultValue:YES];
    BOOL showColorPreview = [self boolPreferenceForKey:kRCPrefShowColorPreviewInTheMenu defaultValue:YES];
    BOOL showMenuIcon = [self boolPreferenceForKey:kRCPrefShowIconInTheMenuKey defaultValue:YES];
    BOOL shouldTreatAsColorForPreview = [self shouldTreatClipItemAsColorCandidate:clipItem];

    if (needsTooltip) {
        NSString *toolTip = [self cachedTooltipForClipItem:clipItem];
        if (toolTip.length == 0 && clipItem.title.length > 0) {
            toolTip = clipItem.title;
        }

        if (toolTip.length > 0) {
            NSInteger maxLength = [self integerPreferenceForKey:kRCMaxLengthOfToolTipKey defaultValue:10000];
            [self setToolTip:[self truncatedString:toolTip maxLength:MAX(1, maxLength)] onMenuItem:item];
        }
    }

    BOOL imageSatisfied = NO;
    if (showColorPreview && shouldTreatAsColorForPreview) {
        NSImage *colorPreview = [self colorPreviewImageForClipItem:clipItem];
        if (colorPreview != nil) {
            [self applyMenuItemTitleForItem:item numberPrefix:numberPrefix baseTitle:baseTitle image:colorPreview];
            imageSatisfied = YES;
        }
    }

    if (!imageSatisfied && !shouldTreatAsColorForPreview) {
        NSString *thumbnailCacheKey = [self thumbnailCacheKeyForClipItem:clipItem];
        if (showImagePreview && clipItem.thumbnailPath.length > 0 && thumbnailCacheKey.length > 0) {
            NSImage *cachedThumbnail = [self.thumbnailCache objectForKey:thumbnailCacheKey];
            if (cachedThumbnail != nil) {
                [self applyMenuItemTitleForItem:item numberPrefix:numberPrefix baseTitle:baseTitle image:cachedThumbnail];
                imageSatisfied = YES;
            } else {
                if (showMenuIcon) {
                    NSImage *placeholderImage = [self typeIconForClipItem:clipItem];
                    if (placeholderImage != nil) {
                        [self applyMenuItemTitleForItem:item numberPrefix:numberPrefix baseTitle:baseTitle image:placeholderImage];
                        imageSatisfied = YES;
                    }
                }

                [self loadThumbnailForClipItem:clipItem
                                      cacheKey:thumbnailCacheKey
                              updatingMenuItem:item
                                  numberPrefix:numberPrefix
                                     baseTitle:baseTitle];
            }
        }
    }

    if (!imageSatisfied && showMenuIcon) {
        NSImage *iconImage = [self typeIconForClipItem:clipItem];
        if (iconImage != nil) {
            [self applyMenuItemTitleForItem:item numberPrefix:numberPrefix baseTitle:baseTitle image:iconImage];
            imageSatisfied = YES;
        }
    }

    if ([self boolPreferenceForKey:kRCAddNumericKeyEquivalentsKey defaultValue:NO]) {
        NSString *numericKey = [self numericKeyEquivalentForGlobalIndex:globalIndex];
        if (numericKey.length > 0) {
            item.keyEquivalent = numericKey;
            item.keyEquivalentModifierMask = 0;
        }
    }

    return item;
}

- (NSString *)menuTitleForClipItem:(RCClipItem *)clipItem globalIndex:(NSUInteger)globalIndex {
    NSString *baseTitle = [self menuBaseTitleForClipItem:clipItem];
    NSString *numberPrefix = [self menuNumberPrefixForGlobalIndex:globalIndex];
    if (numberPrefix.length == 0) {
        return baseTitle;
    }
    return [numberPrefix stringByAppendingString:baseTitle];
}

- (NSString *)menuBaseTitleForClipItem:(RCClipItem *)clipItem {
    NSString *title = clipItem.title ?: @"";
    if (title.length == 0) {
        title = [self fallbackTitleForPrimaryType:clipItem.primaryType];
    }

    NSInteger maxLength = [self integerPreferenceForKey:kRCPrefMaxMenuItemTitleLengthKey defaultValue:40];
    return [self truncatedString:title maxLength:MAX(1, maxLength)];
}

- (NSString *)menuNumberPrefixForGlobalIndex:(NSUInteger)globalIndex {
    BOOL shouldPrefixIndex = [self boolPreferenceForKey:kRCMenuItemsAreMarkedWithNumbersKey defaultValue:YES];
    if (!shouldPrefixIndex) {
        return @"";
    }

    BOOL startWithZero = [self boolPreferenceForKey:kRCPrefMenuItemsTitleStartWithZeroKey defaultValue:NO];
    NSInteger number = startWithZero ? (NSInteger)globalIndex : ((NSInteger)globalIndex + 1);
    return [NSString stringWithFormat:@"%ld. ", (long)number];
}

- (void)applyNativeAppearanceToMenuItem:(NSMenuItem *)item
                          title:(NSString *)title
                         number:(NSString *)number
                          image:(NSImage *)image
                submenuChevron:(BOOL)submenuChevron {
    if (item == nil) {
        return;
    }

    (void)submenuChevron; // NSMenu draws the submenu indicator and handles tracking.
    [self applyMenuItemTitleForItem:item numberPrefix:number baseTitle:title image:image];
}

- (void)setToolTip:(NSString *)toolTip onMenuItem:(NSMenuItem *)item {
    if (item == nil) {
        return;
    }
    // The preview has one owner; no native tooltip can appear a second time.
    item.toolTip = nil;
    item.accessibilityHelp = toolTip;
    if (toolTip.length) [self.previewTexts setObject:toolTip forKey:item];
    else [self.previewTexts removeObjectForKey:item];
}

- (NSImage *)templateSymbolNamed:(NSString *)symbolName {
    if (symbolName.length == 0) {
        return nil;
    }
    NSImage *image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil];
    image.template = YES;
    return image;
}

- (void)applyMenuItemTitleForItem:(NSMenuItem *)item
                     numberPrefix:(NSString *)numberPrefix
                        baseTitle:(NSString *)baseTitle
                            image:(nullable NSImage *)image {
    if (item == nil) {
        return;
    }

    NSString *safeNumberPrefix = numberPrefix ?: @"";
    NSString *safeBaseTitle = baseTitle ?: @"";
    NSString *plainTitle = (safeNumberPrefix.length > 0) ? [safeNumberPrefix stringByAppendingString:safeBaseTitle] : safeBaseTitle;

    item.title = plainTitle;

    // Keep image rendering native: template tint, accessibility, key equivalents,
    // hover help and activation all remain owned by AppKit.
    item.view = nil;
    item.image = image;
    item.attributedTitle = [[NSAttributedString alloc] initWithString:plainTitle attributes:@{
        NSFontAttributeName: [NSFont menuFontOfSize:0]
    }];
}

- (NSString *)fallbackTitleForPrimaryType:(NSString *)primaryType {
    if ([primaryType isEqualToString:NSPasteboardTypeTIFF]) {
        return RCLocalizedString(@"Image", nil);
    }
    if ([primaryType isEqualToString:NSPasteboardTypeURL]) {
        return RCLocalizedString(@"URL", nil);
    }
    if ([primaryType isEqualToString:NSPasteboardTypePDF]) {
        return RCLocalizedString(@"PDF", nil);
    }
    if ([primaryType isEqualToString:NSPasteboardTypeRTF] || [primaryType isEqualToString:NSPasteboardTypeRTFD]) {
        return RCLocalizedString(@"Rich Text", nil);
    }
    if ([primaryType isEqualToString:NSPasteboardTypeFileURL]) {
        return RCLocalizedString(@"Files", nil);
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if ([primaryType isEqualToString:NSFilenamesPboardType]) {
        return RCLocalizedString(@"Files", nil);
    }
#pragma clang diagnostic pop
    return RCLocalizedString(@"Clip", nil);
}

- (NSSize)thumbnailPreviewSize {
    CGFloat thumbnailWidth = (CGFloat)MIN(512, MAX(16, [self integerPreferenceForKey:kRCThumbnailWidthKey defaultValue:100]));
    CGFloat thumbnailHeight = (CGFloat)MIN(512, MAX(16, [self integerPreferenceForKey:kRCThumbnailHeightKey defaultValue:32]));
    return NSMakeSize(thumbnailWidth, thumbnailHeight);
}

- (NSString *)colorPreviewCacheKeyForClipItem:(RCClipItem *)clipItem {
    if (clipItem.dataHash.length > 0) {
        return clipItem.dataHash;
    }

    NSString *dataPath = clipItem.dataPath ?: @"";
    if (clipItem.itemId <= 0 && dataPath.length == 0) {
        return @"";
    }

    return [NSString stringWithFormat:@"%ld|%@", (long)clipItem.itemId, dataPath];
}

- (BOOL)shouldTreatClipItemAsColorCandidate:(RCClipItem *)clipItem {
    if (clipItem.isColorCode) {
        return YES;
    }

    NSString *cacheKey = [self colorPreviewCacheKeyForClipItem:clipItem];
    if (cacheKey.length > 0) {
        NSNumber *cachedValue = [self.colorPreviewEligibilityCache objectForKey:cacheKey];
        if (cachedValue != nil) {
            return cachedValue.boolValue;
        }
    }

    return [NSColor isPotentialColorStringCandidate:(clipItem.title ?: @"")];
}

- (void)cacheColorPreviewEligibility:(BOOL)isEligible forClipItem:(RCClipItem *)clipItem {
    if (clipItem.isColorCode) {
        return;
    }

    NSString *cacheKey = [self colorPreviewCacheKeyForClipItem:clipItem];
    if (cacheKey.length == 0) {
        return;
    }

    [self.colorPreviewEligibilityCache setObject:@(isEligible) forKey:cacheKey];
}

- (nullable NSString *)cachedTooltipForClipItem:(RCClipItem *)clipItem {
    NSString *cacheKey = [self colorPreviewCacheKeyForClipItem:clipItem];
    if (cacheKey.length == 0) {
        return nil;
    }
    return [self.clipDataTooltipCache objectForKey:cacheKey];
}

- (nullable NSString *)cachedColorStringForClipItem:(RCClipItem *)clipItem {
    NSString *cacheKey = [self colorPreviewCacheKeyForClipItem:clipItem];
    if (cacheKey.length == 0) {
        return nil;
    }
    return [self.clipDataColorStringCache objectForKey:cacheKey];
}

- (nullable NSImage *)colorPreviewImageForClipItem:(RCClipItem *)clipItem {
    NSArray<NSString *> *candidateStrings = @[
        [self cachedColorStringForClipItem:clipItem] ?: @"",
        clipItem.title ?: @""
    ];

    for (NSString *candidate in candidateStrings) {
        if (candidate.length == 0) {
            continue;
        }

        NSColor *color = [NSColor colorWithColorString:candidate];
        if (color != nil) {
            [self cacheColorPreviewEligibility:YES forClipItem:clipItem];
            NSSize colorPreviewSize = NSMakeSize(16.0, 16.0);
            return [NSImage imageWithColor:color size:colorPreviewSize cornerRadius:3.0];
        }
    }

    if (!clipItem.isColorCode) {
        [self cacheColorPreviewEligibility:NO forClipItem:clipItem];
    }
    return nil;
}

- (void)prefetchClipDataFallbackForClipItems:(NSArray<RCClipItem *> *)clipItems {
    [self prefetchClipDataFallbackForClipItems:clipItems completion:nil];
}

- (nullable RCClipData *)clipDataForPath:(NSString *)dataPath {
    if (dataPath.length == 0) {
        return nil;
    }
    return [RCClipData clipDataFromPath:dataPath];
}

- (void)prefetchClipDataFallbackForClipItems:(NSArray<RCClipItem *> *)clipItems
                                  completion:(nullable dispatch_block_t)completion {
    if (clipItems.count == 0) {
        if (completion != nil) {
            dispatch_async(dispatch_get_main_queue(), completion);
        }
        return;
    }

    BOOL needsTooltipFallback = [self boolPreferenceForKey:kRCShowToolTipOnMenuItemKey defaultValue:YES];
    BOOL needsColorFallback = [self boolPreferenceForKey:kRCPrefShowColorPreviewInTheMenu defaultValue:YES];
    if (!needsTooltipFallback && !needsColorFallback) {
        if (completion != nil) {
            dispatch_async(dispatch_get_main_queue(), completion);
        }
        return;
    }

    NSInteger maxTooltipLength = MAX(1, [self integerPreferenceForKey:kRCMaxLengthOfToolTipKey defaultValue:10000]);
    NSMutableArray<RCClipItem *> *pendingItems = [NSMutableArray arrayWithCapacity:clipItems.count];
    for (RCClipItem *clipItem in clipItems) {
        NSString *cacheKey = [self colorPreviewCacheKeyForClipItem:clipItem];
        if (cacheKey.length == 0) {
            continue;
        }

        NSNumber *state = [self.clipDataFallbackPrefetchStateCache objectForKey:cacheKey];
        if (state != nil) {
            continue;
        }

        [self.clipDataFallbackPrefetchStateCache setObject:@(kRCClipDataFallbackPrefetchStateInFlight) forKey:cacheKey];
        [pendingItems addObject:clipItem];
    }

    if (pendingItems.count == 0) {
        if (completion != nil) {
            dispatch_async(dispatch_get_main_queue(), completion);
        }
        return;
    }

    NSArray<RCClipItem *> *itemsToPrefetch = [pendingItems copy];
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.clipDataFallbackQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            if (completion != nil) {
                dispatch_async(dispatch_get_main_queue(), completion);
            }
            return;
        }

        for (RCClipItem *clipItem in itemsToPrefetch) {
            NSString *cacheKey = [strongSelf colorPreviewCacheKeyForClipItem:clipItem];
            if (cacheKey.length == 0) {
                continue;
            }
            if (clipItem.dataPath.length == 0) {
                [strongSelf.clipDataFallbackPrefetchStateCache setObject:@(kRCClipDataFallbackPrefetchStateDone) forKey:cacheKey];
                continue;
            }

            RCClipData *clipData = [strongSelf clipDataForPath:clipItem.dataPath];
            if (clipData == nil) {
                [strongSelf.clipDataFallbackPrefetchStateCache setObject:@(kRCClipDataFallbackPrefetchStateDone) forKey:cacheKey];
                continue;
            }

            if (needsTooltipFallback) {
                NSString *tooltip = nil;
                if (clipData.stringValue.length > 0) {
                    tooltip = clipData.stringValue;
                } else if (clipData.URLString.length > 0) {
                    tooltip = clipData.URLString;
                }
                if (tooltip.length > 0) {
                    NSString *truncatedTooltip = [strongSelf truncatedString:tooltip maxLength:maxTooltipLength];
                    [strongSelf.clipDataTooltipCache setObject:truncatedTooltip forKey:cacheKey];
                }
            }

            if (needsColorFallback && clipData.stringValue.length > 0) {
                NSColor *payloadColor = [NSColor colorWithColorString:clipData.stringValue];
                if (payloadColor != nil) {
                    [strongSelf.clipDataColorStringCache setObject:clipData.stringValue forKey:cacheKey];
                    [strongSelf cacheColorPreviewEligibility:YES forClipItem:clipItem];
                } else if (!clipItem.isColorCode) {
                    BOOL titleLooksLikeColor = [NSColor isPotentialColorStringCandidate:(clipItem.title ?: @"")];
                    if (!titleLooksLikeColor) {
                        [strongSelf cacheColorPreviewEligibility:NO forClipItem:clipItem];
                    }
                }
            }

            [strongSelf.clipDataFallbackPrefetchStateCache setObject:@(kRCClipDataFallbackPrefetchStateDone) forKey:cacheKey];
        }

        if (completion != nil) {
            dispatch_async(dispatch_get_main_queue(), completion);
        }
    });
}

- (NSString *)thumbnailCacheKeyForClipItem:(RCClipItem *)clipItem {
    NSString *dataPath = clipItem.dataPath ?: @"";
    if (clipItem.itemId <= 0 && dataPath.length == 0) {
        return @"";
    }
    return [NSString stringWithFormat:@"%ld|%@", (long)clipItem.itemId, dataPath];
}

- (void)prefetchThumbnailsForClipItems:(NSArray<RCClipItem *> *)clipItems {
    if (clipItems.count == 0) {
        return;
    }

    BOOL showImagePreview = [self boolPreferenceForKey:kRCShowImageInTheMenuKey defaultValue:YES];
    if (!showImagePreview) {
        return;
    }

    NSArray<RCClipItem *> *itemsToPrefetch = [clipItems copy];
    NSSize thumbnailSize = [self thumbnailPreviewSize];
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.thumbnailGenerationQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }

        for (RCClipItem *clipItem in itemsToPrefetch) {
            if (clipItem.isColorCode || clipItem.thumbnailPath.length == 0) {
                continue;
            }

            NSString *cacheKey = [strongSelf thumbnailCacheKeyForClipItem:clipItem];
            if (cacheKey.length == 0 || [strongSelf.thumbnailCache objectForKey:cacheKey] != nil) {
                continue;
            }

            NSImage *resizedImage = [strongSelf resizedThumbnailImageAtPath:clipItem.thumbnailPath
                                                                  targetSize:thumbnailSize];
            if (resizedImage != nil) {
                [strongSelf.thumbnailCache setObject:resizedImage forKey:cacheKey];
            }
        }
    });
}

- (void)loadThumbnailForClipItem:(RCClipItem *)clipItem
                        cacheKey:(NSString *)cacheKey
                updatingMenuItem:(NSMenuItem *)menuItem
                    numberPrefix:(NSString *)numberPrefix
                       baseTitle:(NSString *)baseTitle {
    if (clipItem.thumbnailPath.length == 0 || cacheKey.length == 0 || menuItem == nil) {
        return;
    }

    NSString *thumbnailPath = [clipItem.thumbnailPath copy];
    NSString *expectedDataHash = [clipItem.dataHash copy] ?: @"";
    NSString *numberPrefixCopy = [numberPrefix copy] ?: @"";
    NSString *baseTitleCopy = [baseTitle copy] ?: @"";
    NSSize thumbnailSize = [self thumbnailPreviewSize];
    __weak typeof(self) weakSelf = self;
    __weak NSMenuItem *weakMenuItem = menuItem;
    dispatch_async(self.thumbnailGenerationQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }

        NSImage *resizedImage = [strongSelf.thumbnailCache objectForKey:cacheKey];
        if (resizedImage == nil) {
            resizedImage = [strongSelf resizedThumbnailImageAtPath:thumbnailPath targetSize:thumbnailSize];
            if (resizedImage != nil) {
                [strongSelf.thumbnailCache setObject:resizedImage forKey:cacheKey];
            }
        }

        if (resizedImage == nil) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            NSMenuItem *strongMenuItem = weakMenuItem;
            if (strongMenuItem == nil) {
                return;
            }

            id representedObject = strongMenuItem.representedObject;
            if (![representedObject isKindOfClass:[NSString class]]
                || ![(NSString *)representedObject isEqualToString:expectedDataHash]) {
                return;
            }

            [strongSelf applyMenuItemTitleForItem:strongMenuItem
                                     numberPrefix:numberPrefixCopy
                                        baseTitle:baseTitleCopy
                                            image:resizedImage];
        });
    });
}

- (nullable NSImage *)resizedThumbnailImageAtPath:(NSString *)thumbnailPath targetSize:(NSSize)targetSize {
    if (thumbnailPath.length == 0) {
        return nil;
    }

    NSString *root = [RCUtilities clipDataDirectoryPath].stringByStandardizingPath;
    if (![thumbnailPath.stringByStandardizingPath.stringByDeletingLastPathComponent isEqualToString:root]
        || ![RCStorageMigration validatePrivateDirectory:root create:NO]) return nil;
    NSData *data = [[RCStorageCipher shared] readDataAtPath:thumbnailPath allowPlaintext:NO error:nil];
    NSImage *thumbnailImage = data ? [[NSImage alloc] initWithData:data] : nil;
    if (thumbnailImage == nil) {
        return nil;
    }

    NSImage *resizedImage = [thumbnailImage resizedImageToFitSize:targetSize];
    if (resizedImage == nil) {
        resizedImage = [thumbnailImage resizedImageToSize:targetSize];
    }
    if (resizedImage == nil) {
        return nil;
    }

    resizedImage.template = NO;
    return resizedImage;
}

- (nullable NSImage *)typeIconForClipItem:(RCClipItem *)clipItem {
    NSInteger preferredIconSize = [self integerPreferenceForKey:kRCPrefMenuIconSizeKey defaultValue:16];
    CGFloat iconSide = (CGFloat)MAX(8, preferredIconSize);
    NSSize iconSize = NSMakeSize(iconSide, iconSide);

    NSImage *typeImage = [self primaryTypeIconForType:clipItem.primaryType];
    NSImage *resizedImage = [typeImage resizedImageToFitSize:iconSize];
    if (resizedImage == nil) {
        resizedImage = [typeImage resizedImageToSize:iconSize];
    }
    if (resizedImage != nil) {
        resizedImage.template = YES;
        return resizedImage;
    }

    NSImage *iconCopy = [typeImage copy];
    iconCopy.size = iconSize;
    iconCopy.template = YES;
    return iconCopy;
}

- (NSImage *)primaryTypeIconForType:(NSString *)primaryType {
    NSString *symbolName = @"doc.on.doc";
    if ([primaryType isEqualToString:NSPasteboardTypeTIFF]) {
        symbolName = @"photo";
    } else if ([primaryType isEqualToString:NSPasteboardTypeURL]) {
        symbolName = @"link";
    } else if ([primaryType isEqualToString:NSPasteboardTypePDF]) {
        symbolName = @"doc.richtext";
    } else if ([primaryType isEqualToString:NSPasteboardTypeRTF]
               || [primaryType isEqualToString:NSPasteboardTypeRTFD]) {
        symbolName = @"doc.text";
    } else if ([primaryType isEqualToString:NSPasteboardTypeFileURL]) {
        symbolName = @"folder";
    }

    NSImage *image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil];
    if (image == nil) {
        image = [NSImage imageNamed:NSImageNameSmartBadgeTemplate];
    }
    if (image == nil) {
        image = [[NSImage alloc] initWithSize:NSMakeSize(16.0, 16.0)];
    }
    image.template = YES;
    return image;
}

- (NSString *)numericKeyEquivalentForGlobalIndex:(NSUInteger)globalIndex {
    if (globalIndex >= (NSUInteger)kRCMaximumNumberedMenuItems) {
        return @"";
    }

    return [NSString stringWithFormat:@"%lu", (unsigned long)(globalIndex + 1)];
}

- (void)pasteClipWithDataHash:(NSString *)dataHash
            targetApplication:(nullable NSRunningApplication *)application {
    if (dataHash.length == 0) {
        return;
    }

    NSDictionary *clipRow = [[RCDatabaseManager shared] clipItemWithDataHash:dataHash];
    if (![clipRow isKindOfClass:[NSDictionary class]]) {
        return;
    }

    RCClipItem *clipItem = [[RCClipItem alloc] initWithDictionary:clipRow];
    if (clipItem.dataPath.length == 0) {
        [self handleMissingClipDataForClipItem:clipItem reason:@"empty data path"];
        return;
    }

    RCClipData *clipData = [RCClipData clipDataFromPath:clipItem.dataPath];
    if (clipData == nil) {
        [self handleMissingClipDataForClipItem:clipItem reason:@"missing or unreadable clip data file"];
        return;
    }

    [[RCPasteService shared] pasteClipData:clipData toApplication:application];
}

#pragma mark - Actions

- (void)selectClipMenuItem:(NSMenuItem *)menuItem {
    NSString *dataHash = nil;
    if ([menuItem.representedObject isKindOfClass:[NSString class]]) {
        dataHash = (NSString *)menuItem.representedObject;
    }
    [self pasteClipWithDataHash:dataHash targetApplication:self.pasteTargetApplication];
}

- (void)selectSnippetMenuItem:(NSMenuItem *)menuItem {
    NSDictionary *selectionInfo = nil;
    if ([menuItem.representedObject isKindOfClass:[NSDictionary class]]) {
        selectionInfo = (NSDictionary *)menuItem.representedObject;
    }

    NSString *folderIdentifier = [self stringValueFromDictionary:selectionInfo
                                                             key:kRCSnippetMenuFolderIdentifierKey
                                                    defaultValue:@""];
    NSString *snippetIdentifier = [self stringValueFromDictionary:selectionInfo
                                                              key:kRCSnippetMenuSnippetIdentifierKey
                                                     defaultValue:@""];
    if (folderIdentifier.length == 0 || snippetIdentifier.length == 0) {
        return;
    }

    NSString *content = [self snippetContentForFolderIdentifier:folderIdentifier snippetIdentifier:snippetIdentifier];
    if (content.length == 0) {
        return;
    }
    [[RCPasteService shared] pastePlainText:content toApplication:self.pasteTargetApplication];
}

- (void)clearHistoryMenuItemSelected:(NSMenuItem *)sender {
    (void)sender;

    BOOL shouldShowAlert = [self boolPreferenceForKey:kRCPrefShowAlertBeforeClearHistoryKey defaultValue:YES];
    if (shouldShowAlert) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText = RCLocalizedString(@"Clear clipboard history?", nil);
        alert.informativeText = RCLocalizedString(@"All saved clips will be removed.", nil);
        [alert addButtonWithTitle:RCLocalizedString(@"Clear", nil)];
        [alert addButtonWithTitle:RCLocalizedString(@"Cancel", nil)];

        NSModalResponse response = [alert runModal];
        if (response != NSAlertFirstButtonReturn) {
            return;
        }
    }

    RCClipboardService *clipboardService = [RCClipboardService shared];
    BOOL wasMonitoring = clipboardService.isMonitoring;
    if (wasMonitoring) {
        [clipboardService stopMonitoring];
    }

    @try {
        RCDatabaseManager *databaseManager = [RCDatabaseManager shared];
        NSArray<NSString *> *pathsToDelete = [self clipDataFilePathsSnapshotForCurrentHistoryWithDatabaseManager:databaseManager];

        if (![databaseManager deleteAllClipItems]) {
            return;
        }

        [databaseManager performDatabaseOperation:^BOOL(FMDatabase *db) {
            [db executeStatements:@"PRAGMA incremental_vacuum;"];
            [db executeStatements:@"PRAGMA wal_checkpoint(TRUNCATE);"];
            return YES;
        }];

        [self.thumbnailCache removeAllObjects];
        [self.colorPreviewEligibilityCache removeAllObjects];
        [self.clipDataColorStringCache removeAllObjects];
        [self.clipDataTooltipCache removeAllObjects];
        [self.clipDataFallbackPrefetchStateCache removeAllObjects];

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self removeClipDataFilesAtPaths:pathsToDelete];
        });

        [self rebuildMenu];
    } @finally {
        if (wasMonitoring) {
            [clipboardService startMonitoring];
        }
    }
}

- (void)openPreferences:(NSMenuItem *)sender {
    (void)sender;

    NSArray<NSString *> *selectorNames = @[@"showPreferencesWindow:", @"showPreferences:"];
    for (NSString *selectorName in selectorNames) {
        SEL selector = NSSelectorFromString(selectorName);
        if ([NSApp sendAction:selector to:nil from:self]) {
            return;
        }
    }

    NSBeep();
}

- (void)openSnippetEditor:(NSMenuItem *)sender {
    (void)sender;

    if ([NSApp sendAction:@selector(showSnippetEditor:) to:nil from:self]) {
        return;
    }

    NSBeep();
}

#pragma mark - Helpers

- (NSArray<NSString *> *)clipDataFilePathsSnapshotForCurrentHistoryWithDatabaseManager:(RCDatabaseManager *)databaseManager {
    if (databaseManager == nil) {
        return @[];
    }

    NSInteger count = [databaseManager clipItemCount];
    if (count <= 0) {
        return @[];
    }

    NSArray<NSDictionary *> *clipRows = [databaseManager fetchClipItemsWithLimit:count];
    if (clipRows.count == 0) {
        return @[];
    }

    NSMutableOrderedSet<NSString *> *paths = [NSMutableOrderedSet orderedSet];
    for (NSDictionary *clipRow in clipRows) {
        RCClipItem *clipItem = [[RCClipItem alloc] initWithDictionary:clipRow];
        if (clipItem.dataPath.length > 0) {
            [paths addObject:clipItem.dataPath];
        }
        if (clipItem.thumbnailPath.length > 0) {
            [paths addObject:clipItem.thumbnailPath];
        }
    }

    return paths.array;
}

- (void)removeClipDataFilesAtPaths:(NSArray<NSString *> *)paths {
    NSString *clipDirectoryPath = [RCUtilities clipDataDirectoryPath];
    NSString *expandedPath = [[clipDirectoryPath stringByExpandingTildeInPath] stringByStandardizingPath];
    NSString *canonicalBase = [expandedPath stringByResolvingSymlinksInPath];
    if (canonicalBase.length == 0) {
        return;
    }
    if (![canonicalBase hasSuffix:@"/"]) {
        canonicalBase = [canonicalBase stringByAppendingString:@"/"];
    }

    for (NSString *path in paths) {
        NSString *itemPath = [[path stringByExpandingTildeInPath] stringByStandardizingPath];
        if (itemPath.length == 0) {
            continue;
        }

        NSString *canonicalPath = [itemPath stringByResolvingSymlinksInPath];
        if (![canonicalPath hasPrefix:canonicalBase]) {
            continue;
        }

        [RCPanicEraseService secureOverwriteFileAtPath:itemPath];
        [self removeFileAtPath:itemPath];
    }
}

- (nullable NSString *)snippetContentForFolderIdentifier:(NSString *)folderIdentifier snippetIdentifier:(NSString *)snippetIdentifier {
    if (folderIdentifier.length == 0 || snippetIdentifier.length == 0) {
        return nil;
    }

    NSArray<NSDictionary *> *snippets = [[RCDatabaseManager shared] fetchSnippetsForFolder:folderIdentifier];
    for (NSDictionary *snippet in snippets) {
        NSString *identifier = [self stringValueFromDictionary:snippet key:@"identifier" defaultValue:@""];
        if (![identifier isEqualToString:snippetIdentifier]) {
            continue;
        }

        BOOL enabled = [self boolValueFromDictionary:snippet key:@"enabled" defaultValue:YES];
        if (!enabled) {
            return nil;
        }

        return [self stringValueFromDictionary:snippet key:@"content" defaultValue:@""];
    }

    return nil;
}

- (void)handleMissingClipDataForClipItem:(RCClipItem *)clipItem reason:(NSString *)reason {
    NSString *dataHash = clipItem.dataHash ?: @"";
    NSString *safeReason = reason.length > 0 ? reason : @"unknown reason";

    if (dataHash.length == 0) {
        NSLog(@"[RCMenuManager] Clip data recovery skipped: missing data_hash (%@).", safeReason);
        [self rebuildMenu];
        return;
    }

    BOOL deleted = [[RCDatabaseManager shared] deleteClipItemWithDataHash:dataHash];
    if (!deleted) {
        os_log_error(RCMenuManagerLog(),
                     "Clip data recovery failed: could not delete orphaned row for data_hash=%{private}@ (%{public}@)",
                     dataHash, safeReason);
        [self rebuildMenu];
        return;
    }

    os_log_debug(RCMenuManagerLog(),
                 "Removed orphaned clip row for missing clip data. data_hash=%{private}@ (%{public}@)",
                 dataHash, safeReason);
    [self.thumbnailCache removeAllObjects];
    [self.colorPreviewEligibilityCache removeAllObjects];
    [self.clipDataColorStringCache removeAllObjects];
    [self.clipDataTooltipCache removeAllObjects];
    [self.clipDataFallbackPrefetchStateCache removeAllObjects];
    [self rebuildMenu];
}

- (void)removeAllClipDataFilesFromDisk {
    NSString *clipDirectoryPath = [RCUtilities clipDataDirectoryPath];
    NSString *expandedPath = [[clipDirectoryPath stringByExpandingTildeInPath] stringByStandardizingPath];
    if (expandedPath.length == 0) {
        return;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray<NSString *> *children = [fileManager contentsOfDirectoryAtPath:expandedPath error:nil];
    NSString *canonicalBase = [expandedPath stringByResolvingSymlinksInPath];
    if (canonicalBase.length == 0) {
        return;
    }
    if (![canonicalBase hasSuffix:@"/"]) {
        canonicalBase = [canonicalBase stringByAppendingString:@"/"];
    }
    for (NSString *child in children) {
        if (![self isKnownClipDataFileName:child]) {
            continue;
        }

        NSString *itemPath = [expandedPath stringByAppendingPathComponent:child];
        NSString *canonicalPath = [itemPath stringByResolvingSymlinksInPath];
        if (![canonicalPath hasPrefix:canonicalBase]) {
            continue;
        }

        BOOL isDirectory = NO;
        if (![fileManager fileExistsAtPath:itemPath isDirectory:&isDirectory] || isDirectory) {
            continue;
        }

        [self removeFileAtPath:itemPath];
    }
}

- (BOOL)isKnownClipDataFileName:(NSString *)fileName {
    if (fileName.length == 0) {
        return NO;
    }

    NSString *lowercaseFileName = [fileName lowercaseString];
    NSString *extension = [[fileName pathExtension] lowercaseString];
    return [extension isEqualToString:kRCClipDataFileExtension]
        || [extension isEqualToString:kRCThumbnailFileExtension]
        || [lowercaseFileName hasSuffix:kRCLegacyThumbnailFileSuffix];
}

- (void)removeFileAtPath:(NSString *)path {
    if (path.length == 0) {
        return;
    }

    NSString *expandedPath = [[path stringByExpandingTildeInPath] stringByStandardizingPath];
    if (expandedPath.length == 0) {
        return;
    }

    NSString *clipDirectoryPath = [RCUtilities clipDataDirectoryPath];
    NSString *standardizedClipDirectoryPath = [[clipDirectoryPath stringByExpandingTildeInPath] stringByStandardizingPath];
    if (standardizedClipDirectoryPath.length == 0 || ![expandedPath hasPrefix:standardizedClipDirectoryPath]) {
        return;
    }

    NSString *clipDirectoryPrefix = [standardizedClipDirectoryPath hasSuffix:@"/"]
        ? standardizedClipDirectoryPath
        : [standardizedClipDirectoryPath stringByAppendingString:@"/"];
    BOOL isExactDirectoryPath = [expandedPath isEqualToString:standardizedClipDirectoryPath];
    BOOL isNestedPath = [expandedPath hasPrefix:clipDirectoryPrefix];
    if (!isExactDirectoryPath && !isNestedPath) {
        return;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if (![fileManager fileExistsAtPath:expandedPath isDirectory:&isDirectory] || isDirectory) {
        return;
    }

    NSDictionary<NSFileAttributeKey, id> *attributes = [fileManager attributesOfItemAtPath:expandedPath error:nil];
    NSString *fileType = [attributes[NSFileType] isKindOfClass:[NSString class]] ? attributes[NSFileType] : nil;
    if (![fileType isEqualToString:NSFileTypeRegular]) {
        return;
    }

    [RCPanicEraseService secureOverwriteFileAtPath:expandedPath];

    NSError *error = nil;
    BOOL removed = [fileManager removeItemAtPath:expandedPath error:&error];
    if (!removed) {
        os_log_error(RCMenuManagerLog(),
                     "Failed to remove file at %{private}@ (%{private}@)",
                     expandedPath, error.localizedDescription);
    }
}

- (NSString *)truncatedString:(NSString *)string maxLength:(NSInteger)maxLength {
    if (string.length == 0 || maxLength <= 0 || string.length <= (NSUInteger)maxLength) {
        return string ?: @"";
    }

    if (maxLength <= 3) {
        NSRange safeRange = [self composedSafePrefixRangeForString:string maxLength:(NSUInteger)maxLength];
        return [string substringWithRange:safeRange];
    }

    NSUInteger bodyLength = (NSUInteger)(maxLength - 3);
    NSRange safeRange = [self composedSafePrefixRangeForString:string maxLength:bodyLength];
    NSString *truncated = [string substringWithRange:safeRange];
    return [truncated stringByAppendingString:@"..."];
}

- (NSRange)composedSafePrefixRangeForString:(NSString *)string maxLength:(NSUInteger)maxLength {
    if (string.length == 0 || maxLength == 0) {
        return NSMakeRange(0, 0);
    }

    NSUInteger requestedLength = MIN(maxLength, string.length);
    NSRange safeRange = [string rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, requestedLength)];

    while (safeRange.length > maxLength && safeRange.length > 0) {
        NSUInteger adjustedLength = safeRange.length;
        NSRange lastSequenceRange = [string rangeOfComposedCharacterSequenceAtIndex:(adjustedLength - 1)];
        if (lastSequenceRange.location == NSNotFound || lastSequenceRange.location >= adjustedLength) {
            adjustedLength -= 1;
        } else {
            adjustedLength = lastSequenceRange.location;
        }
        safeRange = [string rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, adjustedLength)];
    }

    return safeRange;
}

- (BOOL)boolPreferenceForKey:(NSString *)key defaultValue:(BOOL)defaultValue {
    id rawValue = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    if ([rawValue isKindOfClass:[NSNumber class]]) {
        return [rawValue boolValue];
    }
    if ([rawValue isKindOfClass:[NSString class]]) {
        return [(NSString *)rawValue boolValue];
    }
    return defaultValue;
}

- (NSInteger)integerPreferenceForKey:(NSString *)key defaultValue:(NSInteger)defaultValue {
    id rawValue = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    if ([rawValue isKindOfClass:[NSNumber class]]) {
        return [rawValue integerValue];
    }
    if ([rawValue isKindOfClass:[NSString class]]) {
        return [(NSString *)rawValue integerValue];
    }
    return defaultValue;
}

- (void)performOnMainThread:(dispatch_block_t)block {
    if ([NSThread isMainThread]) {
        block();
        return;
    }

    dispatch_async(dispatch_get_main_queue(), block);
}

- (void)clearThumbnailCache {
    [self.thumbnailCache removeAllObjects];
    [self.colorPreviewEligibilityCache removeAllObjects];
    [self.clipDataColorStringCache removeAllObjects];
    [self.clipDataTooltipCache removeAllObjects];
    [self.clipDataFallbackPrefetchStateCache removeAllObjects];
}

- (NSString *)stringValueFromDictionary:(NSDictionary *)dictionary key:(NSString *)key defaultValue:(NSString *)defaultValue {
    id rawValue = dictionary[key];
    if ([rawValue isKindOfClass:[NSString class]]) {
        return (NSString *)rawValue;
    }
    if ([rawValue respondsToSelector:@selector(stringValue)]) {
        return [rawValue stringValue];
    }
    return defaultValue;
}

- (BOOL)boolValueFromDictionary:(NSDictionary *)dictionary key:(NSString *)key defaultValue:(BOOL)defaultValue {
    id rawValue = dictionary[key];
    if ([rawValue isKindOfClass:[NSNumber class]]) {
        return [rawValue boolValue];
    }
    if ([rawValue isKindOfClass:[NSString class]]) {
        return [(NSString *)rawValue boolValue];
    }
    return defaultValue;
}

@end
