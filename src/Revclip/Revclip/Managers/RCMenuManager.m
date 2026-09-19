#import "RCHotKeyRecorderView.h"
#import "RCMenuStyle.h"
#import "RCLinkPreviewService.h"
#import "RCSnippetMedia.h"
#import "RCFileImagePreview.h"
#import "RCLocalization.h"
#import "RCFastPreviewController.h"
//
//  RCMenuManager.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Current project: AGPL-3.0-only; legacy portions: MIT. See THIRD_PARTY_NOTICES.md.
//

#import "RCMenuManager.h"
#import "RCAppDelegate.h"
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
static NSInteger const kRCClipDataFallbackHadTooltip = 4;
static NSInteger const kRCClipDataFallbackHadColor = 8;

static os_log_t RCMenuManagerLog(void) {
    static os_log_t logger = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        logger = os_log_create("com.revclip", "RCMenuManager");
    });
    return logger;
}

@interface RCMenuManager () <NSMenuDelegate>
@property (nonatomic, strong) NSHashTable<NSMenu *> *trackingMenus;
@property (nonatomic, weak) NSMenu *trackingRootMenu;
@property BOOL pendingMenuRebuild;
// Main-thread-owned; one command waiting for every tracking menu to close. It
// stays set until it actually runs, so a second entry cannot slip in between
// menuDidClose: and the run loop turn that executes it.
@property (nonatomic, copy, nullable) dispatch_block_t afterTrackingBlock;
@property (nonatomic) NSUInteger afterTrackingGeneration;
@property (nonatomic) BOOL afterTrackingScheduled;
// Main-thread-owned state of one Services request. While active, choosing an item
// records it here instead of pasting.
@property (nonatomic) BOOL serviceSessionActive;
@property (nonatomic) BOOL serviceSessionTimedOut;
@property (nonatomic, strong, nullable) NSMenuItem *serviceSelectedItem;
@property (nonatomic, strong, nullable) NSMenu *serviceMenu;
// Main-thread-owned; a newer hotkey request supersedes an unpresented one.
@property (nonatomic) NSUInteger presentationRequest;
// Main-thread-owned; advances each time the status menu's root opens, so a
// preflight completion can only refresh the session that started it.
@property (nonatomic) NSUInteger statusMenuSession;
@property (nonatomic, copy) NSDictionary *menuPreferences;

@property (nonatomic, strong, nullable) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenu *statusMenu;
@property (nonatomic, strong) NSMapTable<NSMenuItem *, NSString *> *previewTexts;
@property (nonatomic, strong) NSMapTable<NSMenuItem *, NSData *> *previewImageData;
@property (nonatomic, strong) NSMapTable<NSMenuItem *, NSURL *> *previewURLs;
@property (nonatomic) NSUInteger cacheGeneration;
@property (nonatomic, strong) NSMutableSet<NSString *> *fallbackInFlightKeys;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSURL *> *historyLinkURLs;
@property (nonatomic) BOOL historyClearInProgress;
@property (nonatomic, strong) NSLock *cacheLock;
@property (nonatomic, strong) NSMapTable<NSMenuItem *, RCClipItem *> *clipItemsByMenuItem;
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
- (void)prefetchClipDataFallbackForClipItems:(NSArray<RCClipItem *> *)clipItems
                                  completion:(nullable dispatch_block_t)completion;
- (NSUInteger)cacheGenerationSnapshot;
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
- (nullable NSRunningApplication *)frontmostApplication;
- (void)capturePasteTargetApplication;
- (void)populateStatusMenuContents;
- (void)prepareVisibleItemsOfOpenedMenu:(NSMenu *)menu;
- (BOOL)statusMenuHasHighlightedItem;
- (NSTimeInterval)secondsSinceLastUserInput;
- (void)refreshStatusMenuAfterClipboardSynchronization;
- (void)configureClipMenuItem:(NSMenuItem *)item clipItem:(RCClipItem *)clipItem loadThumbnail:(BOOL)loadThumbnail;
- (nullable NSImage *)templateSymbolNamed:(NSString *)symbolName;

@end

@implementation RCMenuManager

+ (instancetype)shared {
    static RCMenuManager *sharedManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedManager = [[self alloc] init];
        // Only the app's manager gates the OCR hotkey; test managers never do.
        RCMenuManager *manager = sharedManager;
        [RCOCRCoordinator shared].menuTrackingGate = ^(dispatch_block_t block) {
            [manager performAfterMenuTrackingEnds:block];
        };
    });
    return sharedManager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _trackingMenus = [NSHashTable weakObjectsHashTable];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(menuTrackingDidEnd:) name:NSMenuDidEndTrackingNotification object:nil];
        _menuPreferences = [self menuPreferenceSnapshot];
        _previewImageData = [NSMapTable weakToStrongObjectsMapTable];
        _previewURLs = [NSMapTable weakToStrongObjectsMapTable];
        _cacheLock = [NSLock new];
        _previewTexts = [NSMapTable weakToStrongObjectsMapTable];
        _clipItemsByMenuItem = [NSMapTable weakToStrongObjectsMapTable];
        _previewController = [RCFastPreviewController new];
        _statusMenu = [self menuWithTitle:@"Revclip"];
        _thumbnailCache = [[NSCache alloc] init];
        _thumbnailCache.countLimit = 128;
        _thumbnailCache.totalCostLimit = 32 * 1024 * 1024;
        _colorPreviewEligibilityCache = [[NSCache alloc] init];
        _clipDataColorStringCache = [[NSCache alloc] init];
        _clipDataTooltipCache = [[NSCache alloc] init];
        _clipDataFallbackPrefetchStateCache = [[NSCache alloc] init];
        // Bounded reusable results. In-flight ownership is separate: NSCache may
        // evict at any time and must not admit duplicate queued archive reads.
        _colorPreviewEligibilityCache.countLimit = 512;
        _clipDataColorStringCache.countLimit = 512;
        _clipDataColorStringCache.totalCostLimit = 1024 * 1024;
        _clipDataTooltipCache.countLimit = 512;
        _clipDataTooltipCache.totalCostLimit = 4 * 1024 * 1024;
        _clipDataFallbackPrefetchStateCache.countLimit = 512;
        _fallbackInFlightKeys = [NSMutableSet set];
        _historyLinkURLs = [NSMutableDictionary dictionary];
        _thumbnailGenerationQueue = dispatch_queue_create("com.revclip.menu.thumbnail", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        _clipDataFallbackQueue = dispatch_queue_create("com.revclip.menu.clipdata-fallback", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));

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
    [[RCHotKeyService shared] endMenuPreferencesShortcutForOwner:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Public

- (void)setupStatusItem {
    [self performOnMainThread:^{
        if (self.trackingMenus.count) { self.pendingMenuRebuild = YES; return; }
        [self applyStatusItemPreference];
        [self rebuildMenuInternal];
    }];
}

- (void)rebuildMenu {
    [self performOnMainThread:^{
        if (self.trackingMenus.count) { self.pendingMenuRebuild = YES; return; }
        [self applyStatusItemPreference];
        [self rebuildMenuInternal];
    }];
}

#pragma mark - Notification

- (void)handleClipboardDidChange:(NSNotification *)notification {
    if ([notification.userInfo[@"historyRemoved"] boolValue]) {
        NSArray *removed = notification.userInfo[@"removedItems"];
        if ([removed isKindOfClass:NSArray.class]) [self invalidateRemovedHistoryItems:removed];
        else [self clearThumbnailCache]; // Compatibility for whole-history invalidation.
    }
    [self rebuildMenu];
}

- (void)invalidateRemovedHistoryItems:(NSArray<RCClipItem *> *)items {
    NSAssert(NSThread.isMainThread, @"Main-thread history invalidation");
    NSMutableSet<NSString *> *removedKeys = [NSMutableSet set];
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    [self.cacheLock lock];
    self.cacheGeneration++;
    // Cancel old publications while retaining unrelated completed payloads.
    for (NSString *key in self.fallbackInFlightKeys) [self.clipDataFallbackPrefetchStateCache removeObjectForKey:key];
    [self.fallbackInFlightKeys removeAllObjects];
    for (RCClipItem *item in items) {
        NSString *key = [self colorPreviewCacheKeyForClipItem:item];
        [removedKeys addObject:key];
        [self.colorPreviewEligibilityCache removeObjectForKey:key];
        [self.clipDataColorStringCache removeObjectForKey:key];
        [self.clipDataTooltipCache removeObjectForKey:key];
        [self.clipDataFallbackPrefetchStateCache removeObjectForKey:key];
        NSString *thumbnailKey = [self thumbnailCacheKeyForClipItem:item];
        [self.thumbnailCache removeObjectForKey:thumbnailKey];
        [self.thumbnailCache removeObjectForKey:[@"hover:" stringByAppendingString:thumbnailKey]];
        NSURL *url = self.historyLinkURLs[key];
        if (url) [urls addObject:url];
        [self.historyLinkURLs removeObjectForKey:key];
    }
    [self.cacheLock unlock];
    for (NSMenuItem *row in self.clipItemsByMenuItem.keyEnumerator.allObjects) {
        RCClipItem *clip = [self.clipItemsByMenuItem objectForKey:row];
        if (![removedKeys containsObject:[self colorPreviewCacheKeyForClipItem:clip]]) continue;
        if (row.menu.highlightedItem == row) [self.previewController hide];
        [self.previewImageData removeObjectForKey:row];
        [self.previewTexts removeObjectForKey:row];
        [self.previewURLs removeObjectForKey:row];
        row.toolTip = nil; row.image = nil; row.enabled = NO;
    }
    [[RCLinkPreviewService shared] removeURLs:urls];
}

- (NSDictionary *)menuPreferenceSnapshot {
    // Framework/user defaults notifications are not menu configuration changes.
    NSArray *keys = @[RCLinkPreviewModeKey, kRCOCRKeyComboKey, kRCOCREnabledKey, @"RCAppAppearance",kRCAddNumericKeyEquivalentsKey,kRCMaxLengthOfToolTipKey,kRCMenuItemsAreMarkedWithNumbersKey,kRCPrefAddClearHistoryMenuItemKey,kRCPrefMaxHistorySizeKey,kRCPrefMaxMenuItemTitleLengthKey,kRCPrefMenuIconSizeKey,kRCPrefMenuItemsTitleStartWithZeroKey,kRCPrefNumberOfItemsPlaceInlineKey,kRCPrefNumberOfItemsPlaceInsideFolderKey,kRCPrefShowAlertBeforeClearHistoryKey,kRCPrefShowColorPreviewInTheMenu,kRCPrefShowIconInTheMenuKey,kRCPrefShowStatusItemKey,kRCShowImageInTheMenuKey,kRCShowToolTipOnMenuItemKey,kRCThumbnailHeightKey,kRCThumbnailWidthKey];
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    for (NSString *key in keys) snapshot[key] = [NSUserDefaults.standardUserDefaults objectForKey:key] ?: NSNull.null;
    return snapshot;
}

- (void)handleUserDefaultsDidChange:(NSNotification *)notification {
    (void)notification;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self handleUserDefaultsDidChange:nil]; });
        return;
    }
    NSDictionary *snapshot = [self menuPreferenceSnapshot];
    os_log_debug(RCMenuManagerLog(), "defaults changed: relevant=%d tracking=%lu", ![snapshot isEqual:self.menuPreferences], (unsigned long)self.trackingMenus.count);
    if ([snapshot isEqual:self.menuPreferences]) return;
    self.menuPreferences = snapshot;
    [self clearMenuCaches];
    if (RCLinkPreviewService.shared.previewMode == RCLinkPreviewModeDisabled) [self.historyLinkURLs removeAllObjects];

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
    [self.thumbnailCache removeAllObjects];
    [self rebuildMenu];
}

- (void)handleApplicationDidReceiveMemoryWarning:(NSNotification *)notification {
    (void)notification;
    [self clearThumbnailCache];
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
        [self presentHistoryAfterClipboardSynchronization:^{
            [self applyStatusItemPreference];

            if (self.statusItem != nil) {
                [self rebuildMenuInternal];
                [self popUpMenuAtMouseLocation:self.statusMenu];
            } else {
                [self popUpMenuAtMouseLocation:[self buildStandaloneMenu]];
            }
        }];
    }];
}

- (void)popUpHistoryMenuFromHotKey {
    [self performOnMainThread:^{
        [self capturePasteTargetApplication];
        [self presentHistoryAfterClipboardSynchronization:^{
            [self applyStatusItemPreference];
            NSMenu *menu = [self menuWithTitle:@"History"];
            [self appendClipHistorySectionToMenu:menu];
            [menu addItem:[NSMenuItem separatorItem]];
            [self appendApplicationSectionToMenu:menu];
            [self popUpTransientMenu:menu];
        }];
    }];
}

// Copy immediately followed by the hotkey: the polling timer may not have
// observed the new generation yet, and an open menu is never rebuilt (rows keep
// their identity and position until it closes). So observe and persist the
// current generation first, then build the list from the database.
//
// The completion is delivered through the run loop, not the main dispatch
// queue: the pop-up runs AppKit's tracking loop, which must keep servicing
// main-queue work (hover previews, favicons) and cannot do so from inside a
// main-queue block. A request superseded by a newer press, or completing while
// another menu already tracks, is dropped rather than stacking pop-ups; the
// capture itself is never dropped. Nothing here waits on the main thread.
- (void)presentHistoryAfterClipboardSynchronization:(dispatch_block_t)present {
    NSUInteger request = ++self.presentationRequest;
    NSTimeInterval requestedAt = NSProcessInfo.processInfo.systemUptime;
    NSRunningApplication *invocationFront = [self frontmostApplication];
    RCClipboardService *clipboard = [RCClipboardService shared];
    NSUInteger lifecycle = clipboard.monitoringGeneration;
    __weak typeof(self) weakSelf = self;
    [clipboard observePendingClipboardChangeWithCompletion:^{
        CFRunLoopRef mainRunLoop = CFRunLoopGetMain();
        CFRunLoopPerformBlock(mainRunLoop,
                              (__bridge CFArrayRef)@[NSRunLoopCommonModes, NSModalPanelRunLoopMode], ^{
            typeof(self) self = weakSelf;
            if (self == nil || request != self.presentationRequest || self.trackingMenus.count) return;
            // Monitoring stops only for quit drain, clear history and panic
            // erase. A stop, or a stop+restart, since the request invalidates it.
            if (!clipboard.isMonitoring || clipboard.monitoringGeneration != lifecycle ||
                self.historyClearInProgress) return;
            // The application in front at the hotkey is the paste target. If the
            // user moved on (or it quit) while the preflight ran, the intent is
            // stale: never present, and never paste, to a switched application.
            NSRunningApplication *front = [self frontmostApplication];
            if (invocationFront.terminated || front.processIdentifier != invocationFront.processIdentifier) return;
            // Escape, typing or a click after the hotkey (possible while a slow
            // save runs) means the user moved on: never surface a late menu.
            NSTimeInterval elapsed = NSProcessInfo.processInfo.systemUptime - requestedAt;
            if ([self secondsSinceLastUserInput] < elapsed) return;
            present();
        });
        CFRunLoopWakeUp(mainRunLoop);
    }];
}

// Age of the newest key-down or mouse-down anywhere in the login session.
// Session-wide event ages are permission-free and need no event monitor or tap;
// the hotkey's own key-down predates the request it created.
- (NSTimeInterval)secondsSinceLastUserInput {
    CGEventType types[] = { kCGEventKeyDown, kCGEventLeftMouseDown, kCGEventRightMouseDown, kCGEventOtherMouseDown };
    NSTimeInterval age = DBL_MAX;
    for (size_t index = 0; index < sizeof(types) / sizeof(types[0]); index++) {
        age = MIN(age, CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState, types[index]));
    }
    return age;
}

// Native status-bar click. AppKit opens statusItem.menu synchronously on
// mouse-down, before any preflight can run, so the native open, anchor,
// geometry, press-drag-release, right-click and accessibility wiring are kept
// untouched. Instead the same poll+persist preflight starts when the root
// status menu opens. If a save landed while this same session is still open,
// the list is refreshed in place, but only while nothing is highlighted and
// no submenu tracks (nothing under the cursor or keyboard focus can move).
// Otherwise the refresh stays deferred to close, exactly as before. A session
// that closed, a stopped or restarted monitor, or a clear in progress leaves
// the completion ignored; nothing here reopens or cancels a menu.
- (void)refreshStatusMenuAfterClipboardSynchronization {
    NSUInteger session = ++self.statusMenuSession;
    RCClipboardService *clipboard = [RCClipboardService shared];
    NSUInteger lifecycle = clipboard.monitoringGeneration;
    __weak typeof(self) weakSelf = self;
    [clipboard observePendingClipboardChangeWithCompletion:^{
        // Main-queue delivery is ordered behind the save notification that set
        // pendingMenuRebuild; the tracking loop of a natively opened menu
        // services it. No nested loop runs from here.
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (self == nil || session != self.statusMenuSession || !self.pendingMenuRebuild) return;
            if (!clipboard.isMonitoring || clipboard.monitoringGeneration != lifecycle ||
                self.historyClearInProgress) return;
            if (self.trackingMenus.count != 1 || ![self.trackingMenus containsObject:self.statusMenu] ||
                [self statusMenuHasHighlightedItem]) return;
            self.pendingMenuRebuild = NO;
            [self populateStatusMenuContents];
            [self prepareVisibleItemsOfOpenedMenu:self.statusMenu];
        });
    }];
}

- (BOOL)statusMenuHasHighlightedItem {
    return self.statusMenu.highlightedItem != nil;
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

// Cocoa screen coordinates increase upward. Reserve the full menu height below
// its top anchor instead of letting AppKit create a tiny scrolling menu at the edge.
- (NSPoint)popupLocationForMenuSize:(NSSize)size mouse:(NSPoint)mouse visibleFrame:(NSRect)frame {
    NSRect usable = NSInsetRect(frame, 8, 8);
    CGFloat height = MIN(size.height + 12, NSHeight(usable));
    CGFloat width = MIN(size.width, NSWidth(usable));
    return NSMakePoint(MAX(NSMinX(usable), MIN(mouse.x, NSMaxX(usable) - width)),
        MIN(NSMaxY(usable), MAX(mouse.y, NSMinY(usable) + height)));
}

- (NSPoint)popupLocationForMenu:(NSMenu *)menu mouse:(NSPoint)mouse {
    NSScreen *screen = NSScreen.mainScreen;
    for (NSScreen *candidate in NSScreen.screens) {
        if (NSPointInRect(mouse, candidate.frame)) { screen = candidate; break; }
    }
    return [self popupLocationForMenuSize:menu.size mouse:mouse visibleFrame:screen.visibleFrame];
}

- (void)popUpTransientMenu:(NSMenu *)menu {
    if (menu == nil) {
        return;
    }

    [self capturePasteTargetApplication];
    [self configureMenuForSimpleTransparentBackground:menu];
    [self popUpMenuAtMouseLocation:menu];
}

// Every hotkey pop-up enters AppKit's tracking session here. While a Services request
// waits for its answer, no other menu is opened from here: the snippet and folder
// hotkeys have no tracking check of their own, and a choice made in a second menu would
// paste at the same moment the requesting application inserts the answer.
- (void)popUpMenuAtMouseLocation:(NSMenu *)menu {
    if (self.serviceSessionActive && menu != self.serviceMenu) { return; }
    NSPoint mouseLocation = [NSEvent mouseLocation];
    [self trackMenu:menu atLocation:[self popupLocationForMenu:menu mouse:mouseLocation]];
}

- (void)trackMenu:(NSMenu *)menu atLocation:(NSPoint)location {
    @try {
        [menu popUpMenuPositioningItem:nil atLocation:location inView:nil];
    } @finally {
        // The synchronous popup return is an independent teardown boundary.
        [self finishTrackingRootMenu:menu];
    }
}

#pragma mark - Menu Build

- (void)rebuildMenuInternal {
    if (self.trackingMenus.count) { self.pendingMenuRebuild = YES; return; }
    [self.previewController hide];
    if (self.statusItem == nil) {
        return;
    }
    [self configureMenuForSimpleTransparentBackground:self.statusMenu];
    [self populateStatusMenuContents];
    self.statusItem.menu = self.statusMenu;
}

// Replaces the status menu's items only. It never touches the native status
// item, the menu's appearance or attachment, so it is also safe for the
// in-place refresh of a menu AppKit is tracking (callers guarantee that no
// tracking menu has an active selection).
- (void)populateStatusMenuContents {
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
            [self setToolTip:[RCLinkPreviewService URLForText:snippetContent] ? snippetContent : [self truncatedString:snippetContent maxLength:200] onMenuItem:snippetItem];
        }
        snippetItem.representedObject = @{
            kRCSnippetMenuFolderIdentifierKey: folderIdentifier,
            kRCSnippetMenuSnippetIdentifierKey: snippetIdentifier,
        };
        NSImage *snippetImage = [self templateSymbolNamed:@"doc.text"];
        NSURL *snippetURL = [RCLinkPreviewService URLForText:snippetContent];
        if (snippetURL) {
            [self.previewURLs setObject:snippetURL forKey:snippetItem];
            snippetImage = [[RCLinkPreviewService shared] cachedFaviconForURL:snippetURL] ?: [self templateSymbolNamed:@"link"];
        }
        NSData *mediaData = snippet[@"media_data"];
        NSColor *snippetColor = [NSColor colorWithColorString:snippetContent];
        if (snippetColor != nil) {
            snippetImage = [NSImage imageWithColor:snippetColor
                                             size:NSMakeSize(16.0, 16.0)
                                     cornerRadius:3.0];
        }
        if (mediaData.length > 0) {
            [self.previewImageData setObject:mediaData forKey:snippetItem];
            NSString *cacheKey = [@"snippet-media:" stringByAppendingString:snippetIdentifier];
            NSImage *preview = [self.thumbnailCache objectForKey:cacheKey];
            if (!preview) {
                preview = [RCSnippetMedia thumbnailForData:mediaData size:16.0];
                if (preview) [self.thumbnailCache setObject:preview forKey:cacheKey cost:4096];
            }
            snippetImage = preview ?: snippetImage;
        }
        [self applyNativeAppearanceToMenuItem:snippetItem
                                title:snippetTitle
                               number:nil
                                image:snippetImage
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

// A styled row dispatches its action while AppKit is still tearing the menu down,
// so OCR waits for the tracking session instead of capturing a fading menu.
- (void)invokeOCR:(id)sender {
    NSRunningApplication *target = self.pasteTargetApplication;
    // The coordinator routes every request through performAfterMenuTrackingEnds:.
    [[RCOCRCoordinator shared] requestFromApplication:target];
}

- (void)performAfterMenuTrackingEnds:(dispatch_block_t)block {
    NSAssert(NSThread.isMainThread, @"Menu tracking state is main-only");
    if (block == nil) { return; }
    // The menu item's key equivalent and the global hotkey describe one request.
    // Checked first: a waiting command may already have seen its last menu close.
    NSArray<NSMenu *> *tracking = self.trackingMenus.allObjects;
    if (self.afterTrackingBlock != nil) {
        // Its menus are gone but nothing scheduled it (a menu released without
        // menuDidClose:). The next request is the event that revives it, so the slot
        // cannot stay occupied for ever and no timer is needed.
        if (tracking.count == 0 && !self.afterTrackingScheduled) { [self scheduleAfterTrackingBlock]; }
        return;
    }
    if (tracking.count == 0) { block(); return; }
    self.afterTrackingBlock = block;
    self.afterTrackingGeneration++;
    self.afterTrackingScheduled = NO;
    os_log_debug(RCMenuManagerLog(), "command deferred until %lu tracking menus close", (unsigned long)tracking.count);
    for (NSMenu *menu in tracking) {
        if (menu.supermenu == nil) { [menu cancelTrackingWithoutAnimation]; }
    }
}

- (void)appendApplicationSectionToMenu:(NSMenu *)menu {
    NSMenuItem *ocrItem = [[NSMenuItem alloc] initWithTitle:RCLocalizedString(@"OCR Copy Screen Text", nil) action:@selector(invokeOCR:) keyEquivalent:@""];
    ocrItem.target = self;
    // The same default-aware value the preferences and the hot key service use.
    RCKeyCombo ocrCombo = [[RCHotKeyService shared] configuredKeyComboForSlot:RCHotKeySlotOCR];
    if (RCIsValidKeyCombo(ocrCombo) && (![NSUserDefaults.standardUserDefaults objectForKey:kRCOCREnabledKey] || [NSUserDefaults.standardUserDefaults boolForKey:kRCOCREnabledKey])) {
        ocrItem.keyEquivalent = [RCHotKeyRecorderView keyEquivalentForKeyCombo:ocrCombo];
        ocrItem.keyEquivalentModifierMask = [RCHotKeyService cocoaModifiersFromCarbonModifiers:ocrCombo.modifiers];
    }
    [self applyNativeAppearanceToMenuItem:ocrItem title:ocrItem.title number:nil image:[self templateSymbolNamed:@"viewfinder"] submenuChevron:NO];
    [menu addItem:ocrItem];
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
    for (NSMenuItem *row in menu.itemArray) { row.view.needsDisplay = YES; }
    [self.previewController highlightItem:item text:[self previewTextForMenuItem:item] imageData:item ? [self.previewImageData objectForKey:item] : nil];
    RCClipItem *clipItem = item ? [self.clipItemsByMenuItem objectForKey:item] : nil;
    if (clipItem == nil) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    BOOL hasFileType = [clipItem.primaryType isEqualToString:NSPasteboardTypeFileURL] ||
        [clipItem.primaryType isEqualToString:NSFilenamesPboardType];
#pragma clang diagnostic pop
    if (clipItem.thumbnailPath.length > 0 || hasFileType) {
        [self loadHistoryImagePreviewForItem:item clip:clipItem];
    }

    // A tooltip needs the payload only for the item the user is inspecting.
    // Never restore every image/archive just to construct an unopened menu.
    NSUInteger generation = [self cacheGenerationSnapshot];
    __weak typeof(self) weakSelf = self;
    __weak NSMenuItem *weakItem = item;
    [self prefetchClipDataFallbackForClipItems:@[clipItem] completion:^{
        RCMenuManager *strongSelf = weakSelf;
        NSMenuItem *strongItem = weakItem;
        // Clear/Panic can leave a row alive while its archive read finishes.
        // Reject the UI completion too, not only the background cache writes.
        if (strongSelf == nil || strongItem == nil || [strongSelf cacheGenerationSnapshot] != generation) return;
        [strongSelf configureClipMenuItem:strongItem clipItem:clipItem loadThumbnail:NO];
        if (strongItem.menu.highlightedItem == strongItem) {
            [strongSelf.previewController highlightItem:strongItem text:[strongSelf previewTextForMenuItem:strongItem] imageData:[strongSelf.previewImageData objectForKey:strongItem]];
        }
    }];
}

// Restore only the hovered image's encrypted archive, downsample off the UI
// thread, and cache the bounded preview. Small menu thumbnails are fallback only.
- (void)loadHistoryImagePreviewForItem:(NSMenuItem *)item clip:(RCClipItem *)clip {
    if ([self.previewImageData objectForKey:item]) return;
    NSString *key = [@"hover:" stringByAppendingString:[self thumbnailCacheKeyForClipItem:clip]];
    NSString *path = clip.thumbnailPath;
    NSString *archivePath = clip.dataPath;
    NSString *hash = clip.dataHash;
    NSUInteger generation = self.cacheGeneration;
    __weak typeof(self) weakSelf = self;
    __weak NSMenuItem *weakItem = item;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        RCMenuManager *owner = weakSelf;
        NSMenuItem *row = weakItem;
        if (!owner || owner.cacheGeneration != generation || !row.menu || row.menu.highlightedItem != row) return;
        dispatch_async(owner.thumbnailGenerationQueue, ^{
            NSImage *image = [owner.thumbnailCache objectForKey:key];
            if (!image) {
                @autoreleasepool {
                    RCClipData *data = [owner clipDataForPath:archivePath];
                    image = [RCFileImagePreview imageForClip:data size:360];
                    // Legacy archives may contain Finder's icon TIFF. Prefer the
                    // source file, then the saved snapshot if the file is gone.
                    if (!image && [RCFileImagePreview hasFileReference:data])
                        image = [owner resizedThumbnailImageAtPath:path targetSize:NSMakeSize(360,360)];
                    if (!image) image = [RCSnippetMedia historyThumbnailForData:data.TIFFData size:360];
                    if (!image) image = [owner resizedThumbnailImageAtPath:path targetSize:NSMakeSize(360,360)];
                }
            }
            NSData *data = image.TIFFRepresentation;
            dispatch_async(dispatch_get_main_queue(), ^{
                NSMenuItem *current = weakItem;
                if (owner.cacheGeneration != generation || !data || !current.menu || current.menu.highlightedItem != current || ![current.representedObject isEqual:hash]) return;
                [owner.thumbnailCache setObject:image forKey:key cost:720*720*4];
                [owner.previewImageData setObject:data forKey:current];
                NSImage *rowImage = [image resizedImageToFitSize:[owner thumbnailPreviewSize]];
                if (rowImage) {
                    [owner.thumbnailCache setObject:rowImage forKey:[owner thumbnailCacheKeyForClipItem:clip]];
                    [owner configureClipMenuItem:current clipItem:clip loadThumbnail:NO];
                }
                [owner.previewController highlightItem:current text:[owner previewTextForMenuItem:current] imageData:data];
            });
        });
    });
}

- (void)menuTrackingDidEnd:(NSNotification *)notification {
    NSMenu *menu = notification.object;
    if ([menu isKindOfClass:NSMenu.class] && menu.supermenu == nil) [self finishTrackingRootMenu:menu];
}
- (void)finishTrackingRootMenu:(NSMenu *)menu {
    if (self.trackingRootMenu != menu) return;
    for (NSMenu *tracked in self.trackingMenus.allObjects) [self menuDidClose:tracked];
    self.trackingRootMenu = nil;
}
- (void)menuDidClose:(NSMenu *)menu {
    [self.trackingMenus removeObject:menu];
    if (!self.trackingMenus.count) {
        [[RCHotKeyService shared] endMenuPreferencesShortcutForOwner:self];
        self.trackingRootMenu = nil;
    }
    os_log_debug(RCMenuManagerLog(), "menu closed; tracking=%lu pending=%d", (unsigned long)self.trackingMenus.count, self.pendingMenuRebuild);
    [self.previewController hide];
    if (!self.trackingMenus.count && self.pendingMenuRebuild) {
        self.pendingMenuRebuild = NO;
        dispatch_async(dispatch_get_main_queue(), ^{ [self setupStatusItem]; });
    }
    if (!self.trackingMenus.allObjects.count && self.afterTrackingBlock != nil && !self.afterTrackingScheduled) {
        [self scheduleAfterTrackingBlock];
    }
}

- (void)scheduleAfterTrackingBlock {
    self.afterTrackingScheduled = YES;
    NSUInteger generation = self.afterTrackingGeneration;
    // The main dispatch queue is also drained inside the event-tracking run loop.
    // These modes only run once AppKit's menu tracking loop has returned.
    CFRunLoopPerformBlock(CFRunLoopGetMain(), (__bridge CFArrayRef)@[NSDefaultRunLoopMode, NSModalPanelRunLoopMode], ^{
        if (generation != self.afterTrackingGeneration || self.afterTrackingBlock == nil) { return; }
        dispatch_block_t block = self.afterTrackingBlock;
        self.afterTrackingBlock = nil;
        self.afterTrackingScheduled = NO;
        block();
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

- (NSString *)previewTextForMenuItem:(NSMenuItem *)item {
    NSString *text = item ? [self.previewTexts objectForKey:item] : nil;
    RCClipItem *clip = item ? [self.clipItemsByMenuItem objectForKey:item] : nil;
    NSURL *url = clip ? [RCLinkPreviewService URLForText:text] : nil;
    if (url && RCLinkPreviewService.shared.previewMode != RCLinkPreviewModeDisabled) {
        NSString *key = [self colorPreviewCacheKeyForClipItem:clip];
        // Keep provenance independently from payload eviction. At the bounded
        // registry limit, clear remote results before forgetting their owners.
        if (!self.historyLinkURLs[key] && self.historyLinkURLs.count >= 512) {
            [[RCLinkPreviewService shared] clearCache];
            [self.historyLinkURLs removeAllObjects];
        }
        self.historyLinkURLs[key] = url;
    }
    return text;
}

- (void)menuWillOpen:(NSMenu *)menu {
    BOOL firstMenu = self.trackingMenus.count == 0;
    [self.trackingMenus addObject:menu];
    if (firstMenu) {
        self.trackingRootMenu = menu;
        while (self.trackingRootMenu.supermenu) self.trackingRootMenu = self.trackingRootMenu.supermenu;
        __weak typeof(self) weakSelf = self;
        [[RCHotKeyService shared] beginMenuPreferencesShortcutForOwner:self action:^{
            RCMenuManager *owner = weakSelf;
            if (!owner || !owner.trackingMenus.count || owner.serviceSessionActive) return;
            [owner performAfterMenuTrackingEnds:^{ [weakSelf openPreferences:nil]; }];
        }];
    }
    os_log_debug(RCMenuManagerLog(), "menu opened; tracking=%lu", (unsigned long)self.trackingMenus.count);
    [self.previewController hide];
    if (menu.supermenu == nil) {
        // A command left over from an earlier session must not fire when this
        // unrelated session ends.
        self.afterTrackingBlock = nil;
        self.afterTrackingGeneration++;
        self.afterTrackingScheduled = NO;
        [self capturePasteTargetApplication];
    }
    [self configureMenuForSimpleTransparentBackground:menu];
    [self prepareVisibleItemsOfOpenedMenu:menu];
    if (menu == self.statusMenu) {
        [self refreshStatusMenuAfterClipboardSynchronization];
    }
}

// On-open treatment of a menu's direct children: native style, favicons and
// thumbnails. Only the opened menu's direct children need thumbnails. Closed
// history folders and startup menu construction perform no payload/thumbnail
// I/O. The in-place refresh reuses this because menuWillOpen: is not re-sent.
- (void)prepareVisibleItemsOfOpenedMenu:(NSMenu *)menu {
    [RCMenuStyle refreshMenu:menu];
    for (NSMenuItem *item in menu.itemArray) {
        [self loadFaviconForMenuItem:item];
        RCClipItem *clipItem = [self.clipItemsByMenuItem objectForKey:item];
        if (clipItem != nil) {
            [self configureClipMenuItem:item clipItem:clipItem loadThumbnail:YES];
        }
    }
}

- (void)loadFaviconForMenuItem:(NSMenuItem *)item {
    NSURL *url = [self.previewURLs objectForKey:item];
    if (!url || [self.previewImageData objectForKey:item]) return;
    NSUInteger generation = self.cacheGeneration;
    __weak typeof(self) weakSelf = self;
    __weak NSMenuItem *weakItem = item;
    [[RCLinkPreviewService shared] assetsForURL:url completion:^(RCLinkPreviewAssets *assets) {
        RCMenuManager *owner = weakSelf; NSMenuItem *row = weakItem;
        if (!owner || owner.cacheGeneration != generation || !row.menu || !assets.favicon ||
            ![[owner.previewURLs objectForKey:row] isEqual:url]) return;
        row.image = assets.favicon;
    }];
}

- (nullable NSRunningApplication *)frontmostApplication {
    return [NSWorkspace sharedWorkspace].frontmostApplication;
}

- (void)capturePasteTargetApplication {
    NSRunningApplication *front = [self frontmostApplication];
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

    item.tag = (NSInteger)globalIndex;
    [self.clipItemsByMenuItem setObject:clipItem forKey:item];
    [self configureClipMenuItem:item clipItem:clipItem loadThumbnail:NO];

    if ([self boolPreferenceForKey:kRCAddNumericKeyEquivalentsKey defaultValue:NO]) {
        NSString *numericKey = [self numericKeyEquivalentForGlobalIndex:globalIndex];
        if (numericKey.length > 0) {
            item.keyEquivalent = numericKey;
            item.keyEquivalentModifierMask = 0;
        }
    }

    return item;
}

- (void)configureClipMenuItem:(NSMenuItem *)item clipItem:(RCClipItem *)clipItem loadThumbnail:(BOOL)loadThumbnail {
    NSString *baseTitle = [self menuBaseTitleForClipItem:clipItem];
    NSString *numberPrefix = [self menuNumberPrefixForGlobalIndex:(NSUInteger)item.tag];
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
        if (showImagePreview && thumbnailCacheKey.length > 0) {
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

                if (loadThumbnail) [self loadThumbnailForClipItem:clipItem
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

// Reserve room for native menu chrome. Wrap whole grapheme clusters without
// discarding title text; AppKit owns multiline sizing and menu tracking.
- (NSString *)boundedMenuTitle:(NSString *)title {
    NSDictionary *attributes = @{NSFontAttributeName:[NSFont menuFontOfSize:0]};
    NSString *text = [[title stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
        stringByReplacingOccurrencesOfString:@"\t" withString:@" "];
    NSMutableString *result = [NSMutableString string];
    NSMutableString *line = [NSMutableString string];
    [text enumerateSubstringsInRange:NSMakeRange(0,text.length)
        options:NSStringEnumerationByComposedCharacterSequences
        usingBlock:^(NSString *part, NSRange range, NSRange enclosingRange, BOOL *stop) {
            if ([part rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) {
                [result appendString:@"\n"]; [line setString:@""]; return;
            }
            NSString *candidate = [line stringByAppendingString:part];
            if (line.length && [candidate sizeWithAttributes:attributes].width > 340) {
                [result appendString:@"\n"]; [line setString:@""];
            }
            [result appendString:part]; [line appendString:part];
        }];
    return result;
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

    NSString *displayTitle = [self boundedMenuTitle:plainTitle];
    item.title = displayTitle;
    item.accessibilityLabel = plainTitle;

    // Keep image rendering native: template tint, accessibility, key equivalents,
    // hover help and activation all remain owned by AppKit.
    if (![RCMenuStyle isEnabled]) { item.view = nil; }
    item.image = image;
    item.attributedTitle = [[NSAttributedString alloc] initWithString:displayTitle attributes:@{
        NSFontAttributeName: [NSFont menuFontOfSize:0]
    }];
    [RCMenuStyle applyToItem:item];
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
    NSUInteger generation = [self cacheGenerationSnapshot];
    NSMutableArray<RCClipItem *> *pendingItems = [NSMutableArray arrayWithCapacity:clipItems.count];
    for (RCClipItem *clipItem in clipItems) {
        NSString *type = clipItem.primaryType;
        if (![type isEqualToString:NSPasteboardTypeString] &&
            ![type isEqualToString:NSPasteboardTypeURL] &&
            ![type isEqualToString:NSPasteboardTypeRTF] &&
            ![type isEqualToString:NSPasteboardTypeRTFD]) continue;
        NSString *cacheKey = [self colorPreviewCacheKeyForClipItem:clipItem];
        if (cacheKey.length == 0) {
            continue;
        }

        // Admission and invalidation share a lock. An old request must never
        // install its InFlight marker in a newer generation for the same hash.
        [self.cacheLock lock];
        BOOL current = self.cacheGeneration == generation;
        NSNumber *cachedState = [self.clipDataFallbackPrefetchStateCache objectForKey:cacheKey];
        NSInteger state = cachedState.integerValue;
        // NSCache may evict payloads independently from the completion marker.
        // Retry only a previously produced value that is now missing; retain
        // negative results so unreadable archives are not reread on every hover.
        BOOL payloadEvicted = (needsTooltipFallback && (state & kRCClipDataFallbackHadTooltip) &&
                               ![self.clipDataTooltipCache objectForKey:cacheKey]) ||
                              (needsColorFallback && (state & kRCClipDataFallbackHadColor) &&
                               ![self.clipDataColorStringCache objectForKey:cacheKey]);
        BOOL shouldPrefetch = current && self.fallbackInFlightKeys.count < 32 &&
            ![self.fallbackInFlightKeys containsObject:cacheKey] &&
            (cachedState == nil || payloadEvicted);
        if (shouldPrefetch) {
            [self.fallbackInFlightKeys addObject:cacheKey];
            [self.clipDataFallbackPrefetchStateCache setObject:@(kRCClipDataFallbackPrefetchStateInFlight) forKey:cacheKey];
        }
        [self.cacheLock unlock];
        if (!current) break;
        if (shouldPrefetch) [pendingItems addObject:clipItem];
    }

    if (pendingItems.count == 0) {
        if (completion != nil) {
            // The same clip may still be loading for an older menu item.
            // Queue behind that work before updating the new hovered item.
            dispatch_async(self.clipDataFallbackQueue, ^{
                dispatch_async(dispatch_get_main_queue(), completion);
            });
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
            @autoreleasepool {
                // A cancelled batch need not read any remaining archives. A read
                // already in flight is allowed to finish, but cannot publish.
                if ([strongSelf cacheGenerationSnapshot] != generation) break;
                NSString *cacheKey = [strongSelf colorPreviewCacheKeyForClipItem:clipItem];
                if (cacheKey.length == 0) {
                    continue;
                }

                // File I/O, decryption, formatting and color parsing stay outside
                // cacheLock. Only the resulting references are committed below.
                RCClipData *clipData = clipItem.dataPath.length > 0 ? [strongSelf clipDataForPath:clipItem.dataPath] : nil;
                NSString *tooltip = nil;
                NSString *colorString = nil;
                BOOL shouldCacheEligibility = NO;
                BOOL colorEligible = NO;
                if (needsTooltipFallback) {
                    if (clipData.stringValue.length > 0) {
                        tooltip = clipData.stringValue;
                    } else if (clipData.URLString.length > 0) {
                        tooltip = clipData.URLString;
                    }
                    if (tooltip.length > 0) {
                        tooltip = [strongSelf truncatedString:tooltip maxLength:maxTooltipLength];
                    }
                }

                if (needsColorFallback && clipData.stringValue.length > 0) {
                    NSColor *payloadColor = [NSColor colorWithColorString:clipData.stringValue];
                    if (payloadColor != nil) {
                        colorString = clipData.stringValue;
                        shouldCacheEligibility = !clipItem.isColorCode;
                        colorEligible = YES;
                    } else if (!clipItem.isColorCode) {
                        BOOL titleLooksLikeColor = [NSColor isPotentialColorStringCandidate:(clipItem.title ?: @"")];
                        if (!titleLooksLikeColor) {
                            shouldCacheEligibility = YES;
                        }
                    }
                }

                // Checking separately from insertion would still race Clear or
                // Panic. Include Done (also for an unreadable archive), so an old
                // completion cannot overwrite a new same-hash InFlight marker.
                [strongSelf.cacheLock lock];
                if (strongSelf.cacheGeneration == generation) {
                    if (tooltip.length > 0) [strongSelf.clipDataTooltipCache setObject:tooltip forKey:cacheKey cost:tooltip.length * sizeof(unichar)];
                    if (colorString != nil) [strongSelf.clipDataColorStringCache setObject:colorString forKey:cacheKey cost:colorString.length * sizeof(unichar)];
                    if (shouldCacheEligibility) [strongSelf.colorPreviewEligibilityCache setObject:@(colorEligible) forKey:cacheKey];
                    NSInteger state = kRCClipDataFallbackPrefetchStateDone |
                        (tooltip.length > 0 ? kRCClipDataFallbackHadTooltip : 0) |
                        (colorString != nil ? kRCClipDataFallbackHadColor : 0);
                    [strongSelf.clipDataFallbackPrefetchStateCache setObject:@(state) forKey:cacheKey];
                    [strongSelf.fallbackInFlightKeys removeObject:cacheKey];
                }
                [strongSelf.cacheLock unlock];
            }
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
    NSUInteger generation = self.cacheGeneration;
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
            [strongSelf.cacheLock lock];
            if (resizedImage && strongSelf.cacheGeneration == generation) [strongSelf.thumbnailCache setObject:resizedImage forKey:cacheKey];
            [strongSelf.cacheLock unlock];
        }

        if (resizedImage == nil) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            NSMenuItem *strongMenuItem = weakMenuItem;
            if (strongSelf.cacheGeneration != generation) return;
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
    CGFloat iconSide = (CGFloat)MIN(64, MAX(8, preferredIconSize));
    NSImage *icon = [[self primaryTypeIconForType:clipItem.primaryType] copy];
    CGFloat longestSide = MAX(icon.size.width, icon.size.height);
    if (longestSide <= 0) return nil;
    // Type icons may grow as well as shrink. Thumbnail fitting deliberately never
    // enlarges images, so it must not be used for the user's icon-size setting.
    CGFloat scale = iconSide / longestSide;
    icon.size = NSMakeSize(icon.size.width * scale, icon.size.height * scale);
    icon.template = YES;
    return icon;
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
    if (dataHash.length == 0 || self.historyClearInProgress) {
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

    [[RCPasteService shared] pasteClipData:clipData toApplication:application historyDataHash:dataHash];
}

#pragma mark - Actions

- (void)selectClipMenuItem:(NSMenuItem *)menuItem {
    if ([self captureServiceSelection:menuItem]) { return; }
    NSString *dataHash = nil;
    if ([menuItem.representedObject isKindOfClass:[NSString class]]) {
        dataHash = (NSString *)menuItem.representedObject;
    }
    [self pasteClipWithDataHash:dataHash targetApplication:self.pasteTargetApplication];
}

- (void)selectSnippetMenuItem:(NSMenuItem *)menuItem {
    if ([self captureServiceSelection:menuItem]) { return; }
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

    for (NSDictionary *snippet in [[RCDatabaseManager shared] fetchSnippetsForFolder:folderIdentifier]) {
        if ([snippet[@"identifier"] isEqual:snippetIdentifier] && [snippet[@"media_data"] length] > 0) {
            NSData *tiff = [RCSnippetMedia pasteboardTIFFForData:snippet[@"media_data"]];
            if (tiff) {
                RCClipData *clipData = [[RCClipData alloc] init];
                clipData.TIFFData = tiff;
                clipData.primaryType = NSPasteboardTypeTIFF;
                [[RCPasteService shared] pasteClipData:clipData toApplication:self.pasteTargetApplication];
            } else { NSBeep(); }
            return;
        }
    }
    NSString *content = [self snippetContentForFolderIdentifier:folderIdentifier snippetIdentifier:snippetIdentifier];
    if (content.length == 0) {
        return;
    }
    [[RCPasteService shared] pastePlainText:content toApplication:self.pasteTargetApplication];
}

#pragma mark - Services entry

// The Services API is synchronous: the answer has to be on the service pasteboard when
// this method returns. The hotkey presentation is not reused, because its clipboard
// preflight is asynchronous; the menu call itself blocks until a choice or a cancel.
static NSTimeInterval const kRCServiceMenuLimit = 50.0; // below NSTimeout (60 s) in Info.plist

- (BOOL)serviceMonitoringActive { return [RCClipboardService shared].isMonitoring && ![RCPanicEraseService shared].isPanicInProgress; }
- (NSUInteger)serviceMonitoringGeneration { return [RCClipboardService shared].monitoringGeneration; }
- (BOOL)serviceModalWindowPresent { return NSApp.modalWindow != nil; }
- (NSTimeInterval)serviceNow { return NSProcessInfo.processInfo.systemUptime; }
- (void)presentServiceMenu:(NSMenu *)menu { [self popUpMenuAtMouseLocation:menu]; }
- (void)recordServiceHistoryUse:(NSString *)dataHash { [[RCClipboardService shared] recordHistoryUseWithDataHash:dataHash]; }

- (NSMenu *)buildServiceMenu {
    // History and templates only: nothing here clears, quits or opens a window.
    NSMenu *menu = [self menuWithTitle:@"Revclip"];
    [self appendClipHistorySectionToMenu:menu];
    [menu addItem:[NSMenuItem separatorItem]];
    [self appendSnippetSectionToMenu:menu];
    return menu;
}

// YES while a Services request is waiting for a choice: the item is recorded and the
// caller must not paste. Only the two item kinds that carry content are taken.
- (BOOL)captureServiceSelection:(NSMenuItem *)item {
    if (!self.serviceSessionActive || item == nil || ![self serviceMenuContainsItem:item]) { return NO; }
    if (item.action != @selector(selectClipMenuItem:) && item.action != @selector(selectSnippetMenuItem:)) { return NO; }
    self.serviceSelectedItem = item;
    return YES;
}

// Only the menu this request opened. An item of any other Revclip menu (the status
// item, a hotkey menu) keeps its ordinary meaning even while a request is waiting.
- (BOOL)serviceMenuContainsItem:(NSMenuItem *)item {
    NSMenu *root = item.menu;
    while (root.supermenu != nil) { root = root.supermenu; }
    return root != nil && root == self.serviceMenu;
}

// A text service can only return text, so items that hold none are disabled up front
// rather than refused after the click.
- (BOOL)serviceItemCanReturnText:(NSMenuItem *)item {
    if (item.action == @selector(selectClipMenuItem:)) {
        NSString *type = [self.clipItemsByMenuItem objectForKey:item].primaryType;
        if (type.length == 0) { return YES; } // unknown: decided when the data is read
        return ![@[NSPasteboardTypeTIFF, NSPasteboardTypePDF, NSPasteboardTypeFileURL, @"NSFilenamesPboardType"] containsObject:type];
    }
    // Validation runs per row and per display: no database read here. A media template
    // registered its data for the preview when the row was built; the choice itself is
    // still read fresh in serviceTextForItem:.
    if (item.action == @selector(selectSnippetMenuItem:)) { return [self.previewImageData objectForKey:item] == nil; }
    return YES;
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (!self.serviceSessionActive || ![self serviceMenuContainsItem:item]) { return YES; }
    return [self serviceItemCanReturnText:item];
}

// Text for the recorded item, read now rather than when the menu was built. nil for
// images, PDFs, files and media templates: a text service cannot return them, and they
// are not placed on the general pasteboard as a substitute.
- (nullable NSString *)serviceTextForItem:(NSMenuItem *)item historyDataHash:(NSString * _Nullable * _Nonnull)outHash {
    *outHash = nil;
    if (item.action == @selector(selectClipMenuItem:)) {
        NSString *dataHash = [item.representedObject isKindOfClass:NSString.class] ? item.representedObject : nil;
        if (dataHash.length == 0) { return nil; }
        NSDictionary *row = [[RCDatabaseManager shared] clipItemWithDataHash:dataHash];
        if (![row isKindOfClass:NSDictionary.class]) { return nil; }
        RCClipItem *clipItem = [[RCClipItem alloc] initWithDictionary:row];
        RCClipData *clipData = clipItem.dataPath.length ? [RCClipData clipDataFromPath:clipItem.dataPath] : nil;
        if (clipData.stringValue.length == 0) { return nil; }
        *outHash = dataHash;
        return clipData.stringValue;
    }
    NSDictionary *info = [item.representedObject isKindOfClass:NSDictionary.class] ? item.representedObject : nil;
    NSString *folder = [self stringValueFromDictionary:info key:kRCSnippetMenuFolderIdentifierKey defaultValue:@""];
    NSString *snippet = [self stringValueFromDictionary:info key:kRCSnippetMenuSnippetIdentifierKey defaultValue:@""];
    if (folder.length == 0 || snippet.length == 0) { return nil; }
    for (NSDictionary *candidate in [[RCDatabaseManager shared] fetchSnippetsForFolder:folder]) {
        if ([candidate[@"identifier"] isEqual:snippet] && [candidate[@"media_data"] length] > 0) { return nil; }
    }
    NSString *content = [self snippetContentForFolderIdentifier:folder snippetIdentifier:snippet];
    return content.length ? content : nil;
}

- (void)insertFromRevclip:(NSPasteboard *)pasteboard userData:(NSString *)userData error:(NSString **)error {
    (void)userData; (void)error; // No error text: a cancel or a refusal is not a failure to report.
    if (!NSThread.isMainThread || pasteboard == nil) { return; }
    // Not ready (still launching, Clear, Panic, quit), a modal alert in front (the
    // first-run Accessibility guidance), a Revclip menu already open, or a second
    // request while one is waiting: no menu, and nothing is returned.
    if (self.serviceSessionActive || self.trackingMenus.allObjects.count || self.historyClearInProgress ||
        ![self serviceMonitoringActive] || [self serviceModalWindowPresent]) { return; }

    NSUInteger generation = [self serviceMonitoringGeneration];
    NSTimeInterval startedAt = [self serviceNow];
    __weak typeof(self) weakSelf = self;
    NSTimer *limit = nil;
    NSMenuItem *selected = nil;
    @try {
        // Everything that marks the session is inside the guard, so an exception while
        // the menu is built cannot leave the interceptor or the flag behind.
        self.serviceSessionActive = YES; self.serviceSessionTimedOut = NO; self.serviceSelectedItem = nil;
        NSMenu *menu = [self buildServiceMenu];
        self.serviceMenu = menu;
        [RCMenuStyle setSelectionInterceptor:^BOOL(NSMenuItem *item) { return [weakSelf captureServiceSelection:item]; }];
        // Exists only during this request. Menu tracking runs in the event-tracking mode.
        limit = [NSTimer timerWithTimeInterval:kRCServiceMenuLimit repeats:NO block:^(NSTimer *timer) {
            typeof(self) self = weakSelf;
            if (self == nil || !self.serviceSessionActive) { return; }
            self.serviceSessionTimedOut = YES;
            [self.serviceMenu cancelTrackingWithoutAnimation];
        }];
        [[NSRunLoop mainRunLoop] addTimer:limit forMode:NSRunLoopCommonModes];
        [[NSRunLoop mainRunLoop] addTimer:limit forMode:NSEventTrackingRunLoopMode];
        [self presentServiceMenu:menu];
        selected = self.serviceSelectedItem;
    } @finally {
        // Always back to ordinary pasting, whatever happened while the menu was open.
        [limit invalidate];
        [RCMenuStyle setSelectionInterceptor:nil];
        self.serviceSessionActive = NO; self.serviceSelectedItem = nil; self.serviceMenu = nil;
    }
    if (selected == nil || ![self serviceMayAnswerSince:startedAt generation:generation]) { return; }

    NSString *dataHash = nil;
    NSString *text = [self serviceTextForItem:selected historyDataHash:&dataHash];
    if (text.length == 0) { NSBeep(); return; }
    // Reading and decrypting takes time, and a stop can arrive from another thread
    // meanwhile: the conditions are checked again immediately before the answer.
    if (![self serviceMayAnswerSince:startedAt generation:generation]) { return; }
    // The service pasteboard only. The general pasteboard and the paste keystroke are
    // never involved, so nothing is pasted twice and no other copy is overwritten.
    [pasteboard clearContents];
    if (![pasteboard writeObjects:@[text]]) { return; }
    if (dataHash.length) { [self recordServiceHistoryUse:dataHash]; }
}

// NO after a stop, or a stop and restart, since the request began, and once the
// requesting application may have stopped waiting.
- (BOOL)serviceMayAnswerSince:(NSTimeInterval)startedAt generation:(NSUInteger)generation {
    if (self.serviceSessionTimedOut || [self serviceNow] - startedAt >= kRCServiceMenuLimit) { return NO; }
    return !self.historyClearInProgress && [self serviceMonitoringActive] && [self serviceMonitoringGeneration] == generation;
}

- (void)clearHistoryMenuItemSelected:(NSMenuItem *)sender {
    (void)sender;
    if (self.historyClearInProgress) return;

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

    self.historyClearInProgress = YES;
    // A cancelled polling timer may still have a capture in flight. Clear only
    // after that serial queue has drained, so an old capture cannot reinsert rows.
    [clipboardService flushQueueWithCompletion:^{
        __block BOOL cleared = NO;
        @try {
            RCDatabaseManager *databaseManager = [RCDatabaseManager shared];
            NSArray<NSString *> *paths = [self clipDataFilePathsSnapshotForCurrentHistoryWithDatabaseManager:databaseManager];
            cleared = [databaseManager deleteAllClipItems];
            if (cleared) {
                [databaseManager performDatabaseOperation:^BOOL(FMDatabase *db) {
                    return [db executeStatements:@"PRAGMA incremental_vacuum;"] &&
                           [db executeStatements:@"PRAGMA wal_checkpoint(TRUNCATE);"];
                }];
                [self removeClipDataFilesAtPaths:paths];
            }
        } @finally {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.historyClearInProgress = NO;
                if (cleared) { [self clearThumbnailCache]; [self rebuildMenu]; }
                if (wasMonitoring && ![RCPanicEraseService shared].isPanicInProgress) [clipboardService startMonitoring];
            });
        }
    }];
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
    [self invalidateRemovedHistoryItems:@[clipItem]];
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
    if (!NSThread.isMainThread) {
        dispatch_sync(dispatch_get_main_queue(), ^{ [self clearThumbnailCache]; });
        return;
    }
    [self clearMenuCaches];
    [self.previewController hide];
    [self.previewImageData removeAllObjects];
    [self.previewTexts removeAllObjects];
    [self.previewURLs removeAllObjects];
    [[RCLinkPreviewService shared] clearCache];
    [self.historyLinkURLs removeAllObjects];
}

// Fallback work runs off-main; use the invalidation lock instead of reading
// the nonatomic generation property concurrently with a cache clear.
- (NSUInteger)cacheGenerationSnapshot {
    [self.cacheLock lock];
    NSUInteger generation = self.cacheGeneration;
    [self.cacheLock unlock];
    return generation;
}

- (void)clearMenuCaches {
    [self.cacheLock lock];
    self.cacheGeneration++;
    [self.thumbnailCache removeAllObjects];
    [self.colorPreviewEligibilityCache removeAllObjects];
    [self.clipDataColorStringCache removeAllObjects];
    [self.clipDataTooltipCache removeAllObjects];
    [self.clipDataFallbackPrefetchStateCache removeAllObjects];
    [self.fallbackInFlightKeys removeAllObjects];
    [self.cacheLock unlock];
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
