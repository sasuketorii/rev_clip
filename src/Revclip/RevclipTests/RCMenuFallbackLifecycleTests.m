// Copyright (c) 2024-2026 Revclip. Current project: AGPL-3.0-only; legacy portions: MIT. See THIRD_PARTY_NOTICES.md.

#import <XCTest/XCTest.h>
#import <AppKit/AppKit.h>
#import "RCMenuManager.h"
#import "RCClipData.h"
#import "RCClipItem.h"
#import "RCConstants.h"

// Existing private seams only: the real admission, cache, menu construction and
// completion paths run. No general pasteboard, database, file or network is used.
@interface RCMenuManager (FallbackLifecycleTests)
- (void)prefetchClipDataFallbackForClipItems:(NSArray<RCClipItem *> *)items completion:(dispatch_block_t)completion;
- (RCClipData *)clipDataForPath:(NSString *)path;
- (BOOL)boolPreferenceForKey:(NSString *)key defaultValue:(BOOL)value;
- (NSInteger)integerPreferenceForKey:(NSString *)key defaultValue:(NSInteger)value;
- (NSString *)cachedTooltipForClipItem:(RCClipItem *)item;
- (NSString *)cachedColorStringForClipItem:(RCClipItem *)item;
- (NSString *)previewTextForMenuItem:(NSMenuItem *)item;
- (NSMenuItem *)clipMenuItemForClipItem:(RCClipItem *)item globalIndex:(NSUInteger)index;
- (void)configureClipMenuItem:(NSMenuItem *)item clipItem:(RCClipItem *)clip loadThumbnail:(BOOL)load;
- (void)appendClipItems:(NSArray<RCClipItem *> *)items toMenu:(NSMenu *)menu;
- (void)prepareVisibleItemsOfOpenedMenu:(NSMenu *)menu;
- (void)menu:(NSMenu *)menu willHighlightItem:(NSMenuItem *)item;
- (void)loadFaviconForMenuItem:(NSMenuItem *)item;
- (void)loadThumbnailForClipItem:(RCClipItem *)clip cacheKey:(NSString *)key
              updatingMenuItem:(NSMenuItem *)item numberPrefix:(NSString *)number baseTitle:(NSString *)title;
@end

@interface RCMenuFallbackProbe : RCMenuManager
@property (nonatomic, copy) RCClipData *(^reader)(NSString *path);
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *fixturePreferences;
@property (atomic) NSUInteger archiveReads;
@property (nonatomic) NSUInteger configurations;
@property (nonatomic) NSUInteger thumbnailRequests;
@end

@implementation RCMenuFallbackProbe
- (instancetype)init {
    self = [super init];
    if (self) {
        // Do not react to the test host's settings or create preview windows.
        [NSNotificationCenter.defaultCenter removeObserver:self];
        [self setValue:nil forKey:@"previewController"];
        _fixturePreferences = @{
            kRCShowToolTipOnMenuItemKey: @YES,
            kRCPrefShowColorPreviewInTheMenu: @YES,
            kRCShowImageInTheMenuKey: @YES,
            kRCPrefShowIconInTheMenuKey: @NO,
            kRCPrefNumberOfItemsPlaceInlineKey: @0,
            kRCPrefNumberOfItemsPlaceInsideFolderKey: @10,
        };
    }
    return self;
}
- (BOOL)boolPreferenceForKey:(NSString *)key defaultValue:(BOOL)value {
    NSNumber *stored = self.fixturePreferences[key];
    return stored ? stored.boolValue : value;
}
- (NSInteger)integerPreferenceForKey:(NSString *)key defaultValue:(NSInteger)value {
    NSNumber *stored = self.fixturePreferences[key];
    return stored ? stored.integerValue : value;
}
- (RCClipData *)clipDataForPath:(NSString *)path {
    self.archiveReads += 1; // Written only by the serial fallback queue.
    return self.reader ? self.reader(path) : nil;
}
- (void)configureClipMenuItem:(NSMenuItem *)item clipItem:(RCClipItem *)clip loadThumbnail:(BOOL)load {
    self.configurations += 1; // Menu construction and completion remain main-only.
    [super configureClipMenuItem:item clipItem:clip loadThumbnail:load];
}
- (void)loadFaviconForMenuItem:(NSMenuItem *)item { (void)item; }
- (void)loadThumbnailForClipItem:(RCClipItem *)clip cacheKey:(NSString *)key
              updatingMenuItem:(NSMenuItem *)item numberPrefix:(NSString *)number baseTitle:(NSString *)title {
    self.thumbnailRequests += 1;
}
@end

@interface RCMenuFallbackLifecycleTests : XCTestCase
@property (nonatomic, strong) RCMenuFallbackProbe *manager;
@end

@implementation RCMenuFallbackLifecycleTests
- (void)setUp {
    [super setUp];
    XCTAssertTrue(NSThread.isMainThread);
    self.manager = [RCMenuFallbackProbe new];
}
- (void)tearDown {
    // Even a failed no-work assertion must finish queued reads before the
    // reader and its captured test fixtures are released.
    if (self.manager != nil) [self drainFallbackQueue];
    self.manager.reader = nil;
    self.manager = nil;
    [super tearDown];
}
- (RCClipItem *)clipWithKey:(NSString *)key {
    RCClipItem *clip = [RCClipItem new];
    clip.itemId = 1;
    clip.dataHash = key;
    clip.dataPath = [key stringByAppendingString:@".rcclip"];
    clip.title = @"Synthetic fixture";
    clip.primaryType = NSPasteboardTypeString;
    clip.thumbnailPath = @"";
    return clip;
}
- (id)cachedValue:(NSString *)cache key:(NSString *)key {
    NSCache *store = [self.manager valueForKey:cache];
    return [store objectForKey:key];
}
- (void)assertNoPayloadCachedForKey:(NSString *)key {
    for (NSString *cache in @[@"clipDataTooltipCache", @"clipDataColorStringCache", @"colorPreviewEligibilityCache"]) {
        XCTAssertNil([self cachedValue:cache key:key], @"Invalidated fallback must not populate %@", cache);
    }
}
- (void)waitForWorkerRelease:(dispatch_semaphore_t)gate {
    // A deadlock watchdog, not a performance threshold. Only the synthetic
    // archive reader (or its queue gate) may wait; main must stay responsive.
    if (NSThread.isMainThread) { XCTFail(@"Archive work must not wait on main"); return; }
    XCTAssertEqual(dispatch_semaphore_wait(gate, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)), 0L);
}
- (void)drainFallbackQueue {
    XCTestExpectation *drained = [self expectationWithDescription:@"fallback and its main completions drained"];
    dispatch_queue_t queue = [self.manager valueForKey:@"clipDataFallbackQueue"];
    dispatch_async(queue, ^{ dispatch_async(dispatch_get_main_queue(), ^{ [drained fulfill]; }); });
    [self waitForExpectations:@[drained] timeout:5];
}

- (void)testClearDuringReadRejectsPayloadAndStopsRemainingBatch {
    RCClipItem *first = [self clipWithKey:@"first"];
    RCClipItem *second = [self clipWithKey:@"second"];
    dispatch_semaphore_t release = dispatch_semaphore_create(0);
    XCTestExpectation *reading = [self expectationWithDescription:@"first archive in flight"];
    XCTestExpectation *completed = [self expectationWithDescription:@"cancelled batch still completes"];
    __block NSUInteger reads = 0, completions = 0;
    __block __weak RCClipData *releasedPayload = nil;
    self.manager.reader = ^RCClipData *(NSString *path) {
        RCClipData *data = [RCClipData new];
        data.stringValue = @"#12AB34";
        releasedPayload = data;
        if (++reads == 1) { [reading fulfill]; [self waitForWorkerRelease:release]; }
        return data;
    };
    @try {
        [self.manager prefetchClipDataFallbackForClipItems:@[first, second] completion:^{
            XCTAssertTrue(NSThread.isMainThread); completions++; [completed fulfill];
        }];
        [self waitForExpectations:@[reading] timeout:5];
        [self.manager clearThumbnailCache];
        dispatch_semaphore_signal(release);
        [self waitForExpectations:@[completed] timeout:5];
        XCTAssertEqual(self.manager.archiveReads, 1u);
        XCTAssertEqual(completions, 1u);
        for (RCClipItem *clip in @[first, second]) {
            [self assertNoPayloadCachedForKey:clip.dataHash];
            XCTAssertNil([self cachedValue:@"clipDataFallbackPrefetchStateCache" key:clip.dataHash]);
        }
    } @finally {
        dispatch_semaphore_signal(release);
        [self drainFallbackQueue];
    }
    // The per-item autorelease pool may release the cancelled archive; this is
    // an ownership assertion, not an RSS, allocation-count or secure-zero test.
    XCTAssertNil(releasedPayload);
}

- (void)testClearBeforeQueuedFallbackStartsPerformsNoArchiveRead {
    RCClipItem *clip = [self clipWithKey:@"queued"];
    dispatch_semaphore_t release = dispatch_semaphore_create(0);
    XCTestExpectation *gated = [self expectationWithDescription:@"queue held before admission"];
    XCTestExpectation *completed = [self expectationWithDescription:@"stale queued batch completed"];
    dispatch_queue_t queue = [self.manager valueForKey:@"clipDataFallbackQueue"];
    dispatch_async(queue, ^{ [gated fulfill]; [self waitForWorkerRelease:release]; });
    @try {
        [self waitForExpectations:@[gated] timeout:5];
        [self.manager prefetchClipDataFallbackForClipItems:@[clip] completion:^{ [completed fulfill]; }];
        [self.manager clearThumbnailCache];
        dispatch_semaphore_signal(release);
        [self waitForExpectations:@[completed] timeout:5];
        XCTAssertEqual(self.manager.archiveReads, 0u);
        XCTAssertNil([self cachedValue:@"clipDataFallbackPrefetchStateCache" key:clip.dataHash]);
    } @finally {
        dispatch_semaphore_signal(release);
        [self drainFallbackQueue];
    }
}

- (void)assertSameKeyRestartWithUnreadableOldArchive:(BOOL)unreadable {
    RCClipItem *clip = [self clipWithKey:unreadable ? @"restart-missing" : @"restart-text"];
    dispatch_semaphore_t oldRelease = dispatch_semaphore_create(0), newRelease = dispatch_semaphore_create(0);
    XCTestExpectation *oldReading = [self expectationWithDescription:@"old read started"];
    XCTestExpectation *newReading = [self expectationWithDescription:@"new generation read started"];
    XCTestExpectation *oldDone = [self expectationWithDescription:@"old completion delivered"];
    XCTestExpectation *newDone = [self expectationWithDescription:@"new completion delivered"];
    __block NSUInteger ordinal = 0;
    NSUInteger readsBefore = self.manager.archiveReads;
    self.manager.reader = ^RCClipData *(NSString *path) {
        BOOL old = ++ordinal == 1;
        RCClipData *data = [RCClipData new]; data.stringValue = old ? @"#12AB34" : @"#5678AB";
        [(old ? oldReading : newReading) fulfill];
        [self waitForWorkerRelease:old ? oldRelease : newRelease];
        return old && unreadable ? nil : data;
    };
    @try {
        [self.manager prefetchClipDataFallbackForClipItems:@[clip] completion:^{ [oldDone fulfill]; }];
        [self waitForExpectations:@[oldReading] timeout:5];
        [self.manager clearThumbnailCache];
        [self.manager prefetchClipDataFallbackForClipItems:@[clip] completion:^{ [newDone fulfill]; }];
        NSNumber *newFlight = [self cachedValue:@"clipDataFallbackPrefetchStateCache" key:clip.dataHash];
        XCTAssertEqualObjects(newFlight, @1);
        dispatch_semaphore_signal(oldRelease);
        [self waitForExpectations:@[newReading, oldDone] timeout:5];
        [self assertNoPayloadCachedForKey:clip.dataHash];
        XCTAssertEqualObjects([self cachedValue:@"clipDataFallbackPrefetchStateCache" key:clip.dataHash], newFlight,
                              @"An old Done marker must not overwrite the new InFlight marker");
        dispatch_semaphore_signal(newRelease);
        [self waitForExpectations:@[newDone] timeout:5];
        XCTAssertEqualObjects([self.manager cachedTooltipForClipItem:clip], @"#5678AB");
        XCTAssertEqualObjects([self.manager cachedColorStringForClipItem:clip], @"#5678AB");
        XCTAssertEqualObjects([self cachedValue:@"colorPreviewEligibilityCache" key:clip.dataHash], @YES);
        XCTAssertEqualObjects([self cachedValue:@"clipDataFallbackPrefetchStateCache" key:clip.dataHash], @2);
        XCTAssertEqual(self.manager.archiveReads - readsBefore, 2u);
    } @finally {
        dispatch_semaphore_signal(oldRelease); dispatch_semaphore_signal(newRelease);
        [self drainFallbackQueue];
    }
}
- (void)testClearAndSameKeyRestartKeepNewFlightForPayloadAndUnreadableResult {
    [self assertSameKeyRestartWithUnreadableOldArchive:NO];
    [self assertSameKeyRestartWithUnreadableOldArchive:YES];
}

- (void)testStaleHoverCompletionCannotRestorePreviewText {
    RCClipItem *clip = [self clipWithKey:@"hover"];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Fixture"];
    NSMenuItem *row = [self.manager clipMenuItemForClipItem:clip globalIndex:0];
    [menu addItem:row]; // Keep the row alive across invalidation, as an open menu can.
    dispatch_semaphore_t release = dispatch_semaphore_create(0);
    XCTestExpectation *reading = [self expectationWithDescription:@"hover read started"];
    self.manager.reader = ^RCClipData *(NSString *path) {
        RCClipData *data = [RCClipData new]; data.stringValue = @"Synthetic full text";
        [reading fulfill]; [self waitForWorkerRelease:release]; return data;
    };
    @try {
        [self.manager menu:menu willHighlightItem:row];
        [self waitForExpectations:@[reading] timeout:5];
        [self.manager clearThumbnailCache];
        NSUInteger configurations = self.manager.configurations;
        dispatch_semaphore_signal(release);
        [self drainFallbackQueue];
        XCTAssertEqual(self.manager.configurations, configurations,
                       @"A stale completion must not reconfigure even a still-live row");
        XCTAssertNil([self.manager previewTextForMenuItem:row]);
    } @finally {
        dispatch_semaphore_signal(release);
        [self drainFallbackQueue];
    }
}

- (void)testCurrentGenerationPreservesFallbackAndCoalescesReads {
    RCClipItem *color = [self clipWithKey:@"color"];
    RCClipItem *url = [self clipWithKey:@"url"]; url.primaryType = NSPasteboardTypeURL;
    RCClipItem *missing = [self clipWithKey:@"missing"];
    NSMutableDictionary *preferences = [self.manager.fixturePreferences mutableCopy];
    preferences[kRCMaxLengthOfToolTipKey] = @8;
    self.manager.fixturePreferences = preferences;
    self.manager.reader = ^RCClipData *(NSString *path) {
        if ([path isEqual:missing.dataPath]) return nil;
        RCClipData *data = [RCClipData new];
        if ([path isEqual:color.dataPath]) data.stringValue = @"#12AB34";
        else data.URLString = @"https://example.invalid/fixture";
        return data;
    };
    NSArray *clips = @[color, url, missing];
    XCTestExpectation *first = [self expectationWithDescription:@"original fallback completed"];
    XCTestExpectation *coalesced = [self expectationWithDescription:@"coalesced fallback completed"];
    [self.manager prefetchClipDataFallbackForClipItems:clips completion:^{ [first fulfill]; }];
    [self.manager prefetchClipDataFallbackForClipItems:clips completion:^{ [coalesced fulfill]; }];
    [self waitForExpectations:@[first, coalesced] timeout:5];
    [self drainFallbackQueue];
    XCTAssertEqual(self.manager.archiveReads, 3u);
    XCTAssertEqualObjects([self.manager cachedTooltipForClipItem:color], @"#12AB34");
    XCTAssertEqualObjects([self.manager cachedColorStringForClipItem:color], @"#12AB34");
    XCTAssertEqualObjects([self.manager cachedTooltipForClipItem:url], @"https...");
    XCTAssertNil([self.manager cachedTooltipForClipItem:missing]);
    for (RCClipItem *clip in clips) {
        XCTAssertEqualObjects([self cachedValue:@"clipDataFallbackPrefetchStateCache" key:clip.dataHash], @2);
    }
}

- (void)testUnopenedHistoryConstructionDoesNoPayloadOrThumbnailWork {
    NSMutableArray<RCClipItem *> *clips = [NSMutableArray array];
    for (NSUInteger index = 0; index < 30; index++) {
        RCClipItem *clip = [self clipWithKey:[NSString stringWithFormat:@"row-%lu", (unsigned long)index]];
        clip.itemId = (NSInteger)index + 1;
        clip.thumbnailPath = [clip.dataHash stringByAppendingString:@".thumb"];
        [clips addObject:clip];
    }
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Fixture"];
    [self.manager appendClipItems:clips toMenu:menu];
    // A zero counter before the worker runs is not evidence of zero work.
    // Finish submitted fallback work and its main completions at each phase.
    [self drainFallbackQueue];
    XCTAssertEqual(menu.numberOfItems, 3);
    for (NSMenuItem *folder in menu.itemArray) XCTAssertEqual(folder.submenu.numberOfItems, 10);
    XCTAssertEqual(self.manager.configurations, 30u);
    XCTAssertEqual(self.manager.archiveReads, 0u);
    XCTAssertEqual(self.manager.thumbnailRequests, 0u);
    [self.manager prepareVisibleItemsOfOpenedMenu:menu];
    [self drainFallbackQueue];
    XCTAssertEqual(self.manager.archiveReads, 0u);
    XCTAssertEqual(self.manager.thumbnailRequests, 0u);
    [self.manager prepareVisibleItemsOfOpenedMenu:menu.itemArray.firstObject.submenu];
    [self drainFallbackQueue];
    XCTAssertEqual(self.manager.thumbnailRequests, 10u);
    XCTAssertEqual(self.manager.archiveReads, 0u);
}
@end
