#import <Cocoa/Cocoa.h>
#import <XCTest/XCTest.h>

#import "RCClipboardService.h"
#import "RCClipData.h"
#import "RCClipItem.h"
#import "RCConstants.h"
#import "RCDatabaseManager.h"
#import "RCMenuManager.h"
#import "RCUtilities.h"

@interface RCClipboardService (Testing)
- (void)processClipDataOnMonitoringQueue:(RCClipData *)clipData
                    sourceBundleIdentifier:(NSString *)sourceBundleIdentifier;
@end

@interface RCMenuManager (Testing)
- (NSMenuItem *)clipMenuItemForClipItem:(RCClipItem *)clipItem globalIndex:(NSUInteger)globalIndex;
- (void)prefetchClipDataFallbackForClipItems:(NSArray<RCClipItem *> *)clipItems
                                  completion:(nullable dispatch_block_t)completion;
- (nullable RCClipData *)clipDataForPath:(NSString *)dataPath;
- (NSMenu *)buildStandaloneMenu;
- (void)menuWillOpen:(NSMenu *)menu;
- (void)menu:(NSMenu *)menu willHighlightItem:(NSMenuItem *)item;
- (nullable NSImage *)resizedThumbnailImageAtPath:(NSString *)path targetSize:(NSSize)size;
@end

@interface RCTestMenuManager : RCMenuManager
@property (atomic, assign) NSInteger clipDataLoadCallCount;
@property (atomic, assign) NSInteger thumbnailLoadCallCount;
@property (nonatomic, copy) dispatch_block_t willLoadClip;
@property (nonatomic, strong) dispatch_semaphore_t loadRelease;
@end

@implementation RCTestMenuManager

- (nullable NSImage *)resizedThumbnailImageAtPath:(NSString *)path targetSize:(NSSize)size {
    self.thumbnailLoadCallCount += 1;
    return [[NSImage alloc] initWithSize:size];
}

- (nullable RCClipData *)clipDataForPath:(NSString *)dataPath {
    self.clipDataLoadCallCount += 1;
    if (self.willLoadClip) self.willLoadClip();
    if (self.loadRelease) dispatch_semaphore_wait(self.loadRelease, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    return [super clipDataForPath:dataPath];
}

@end

@interface RCClipboardColorDetectionTests : XCTestCase

@property (nonatomic, copy) NSDictionary<NSString *, id> *savedMenuDefaults;

@end

@implementation RCClipboardColorDetectionTests

- (void)setUp {
    [super setUp];

    NSArray<NSString *> *keys = @[
        kRCShowToolTipOnMenuItemKey,
        kRCPrefShowColorPreviewInTheMenu,
        kRCShowImageInTheMenuKey,
        kRCPrefShowIconInTheMenuKey,
        kRCMenuItemsAreMarkedWithNumbersKey,
        kRCMaxLengthOfToolTipKey,
    ];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary<NSString *, id> *snapshot = [NSMutableDictionary dictionaryWithCapacity:keys.count];
    for (NSString *key in keys) {
        id value = [defaults objectForKey:key];
        snapshot[key] = value ?: [NSNull null];
    }
    self.savedMenuDefaults = [snapshot copy];

    [self applyDeterministicMenuDefaults];
}

- (void)tearDown {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [self.savedMenuDefaults enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        (void)stop;
        if (value == [NSNull null]) {
            [defaults removeObjectForKey:key];
            return;
        }
        [defaults setObject:value forKey:key];
    }];

    [super tearDown];
}

- (void)applyDeterministicMenuDefaults {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:YES forKey:kRCShowToolTipOnMenuItemKey];
    [defaults setBool:YES forKey:kRCPrefShowColorPreviewInTheMenu];
    [defaults setBool:NO forKey:kRCShowImageInTheMenuKey];
    [defaults setBool:NO forKey:kRCPrefShowIconInTheMenuKey];
    [defaults setBool:NO forKey:kRCMenuItemsAreMarkedWithNumbersKey];
    [defaults setInteger:10000 forKey:kRCMaxLengthOfToolTipKey];
}

- (NSString *)newClipDataPathWithIdentifier:(NSString *)identifier {
    NSString *directoryPath = [RCUtilities clipDataDirectoryPath];
    XCTAssertTrue([RCUtilities ensureDirectoryExists:directoryPath]);
    NSString *safeIdentifier = identifier.length > 0 ? identifier : NSUUID.UUID.UUIDString;
    NSString *fileName = [NSString stringWithFormat:@"%@.rcclip", safeIdentifier];
    return [directoryPath stringByAppendingPathComponent:fileName];
}

- (void)removeFileIfExistsAtPath:(NSString *)path {
    if (path.length == 0) {
        return;
    }
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

- (void)testClipboardServiceMarksRGBAAndHSLAAsColorCode {
    RCClipboardService *service = [RCClipboardService shared];
    RCDatabaseManager *databaseManager = [RCDatabaseManager shared];
    XCTAssertTrue([databaseManager setupDatabase]);

    NSArray<NSString *> *colorStrings = @[
        @"rgba(12, 34, 56, 0.7)",
        @"hsla(180, 50%, 25%, 1)"
    ];

    for (NSString *colorString in colorStrings) {
        RCClipData *clipData = [[RCClipData alloc] init];
        clipData.stringValue = colorString;
        clipData.primaryType = NSPasteboardTypeString;

        NSString *dataHash = [clipData dataHash];
        [databaseManager deleteClipItemWithDataHash:dataHash];

        [service processClipDataOnMonitoringQueue:clipData sourceBundleIdentifier:@"com.revclip.tests"];

        NSDictionary *row = [databaseManager clipItemWithDataHash:dataHash];
        XCTAssertNotNil(row);
        XCTAssertTrue([row[@"is_color_code"] boolValue]);

        NSString *dataPath = [row[@"data_path"] isKindOfClass:NSString.class] ? row[@"data_path"] : @"";
        NSString *thumbnailPath = [row[@"thumbnail_path"] isKindOfClass:NSString.class] ? row[@"thumbnail_path"] : @"";
        [databaseManager deleteClipItemWithDataHash:dataHash];
        [self removeFileIfExistsAtPath:dataPath];
        [self removeFileIfExistsAtPath:thumbnailPath];
    }
}

- (void)testClipMenuItemSyncPathDoesNotCallClipDataFromPath {
    RCTestMenuManager *menuManager = [[RCTestMenuManager alloc] init];
    RCClipItem *clipItem = [[RCClipItem alloc] initWithDictionary:@{
        @"id": @1,
        @"data_path": [self newClipDataPathWithIdentifier:NSUUID.UUID.UUIDString],
        @"title": @"",
        @"data_hash": NSUUID.UUID.UUIDString,
        @"primary_type": NSPasteboardTypeString,
        @"is_color_code": @YES,
    }];

    NSMenuItem *menuItem = [menuManager clipMenuItemForClipItem:clipItem globalIndex:0];
    XCTAssertNotNil(menuItem);
    XCTAssertEqual(menuManager.clipDataLoadCallCount, 0);
}

- (void)testPayloadOnlyColorIsShownOnNextMenuRebuildViaAsyncFallback {
    RCTestMenuManager *menuManager = [[RCTestMenuManager alloc] init];

    RCClipData *clipData = [[RCClipData alloc] init];
    clipData.stringValue = @"rgba(12, 34, 56, 0.7)";
    clipData.primaryType = NSPasteboardTypeString;

    NSString *dataPath = [self newClipDataPathWithIdentifier:NSUUID.UUID.UUIDString];
    XCTAssertTrue([clipData saveToPath:dataPath]);

    RCClipItem *clipItem = [[RCClipItem alloc] initWithDictionary:@{
        @"id": @2,
        @"data_path": dataPath,
        @"title": @"",
        @"data_hash": NSUUID.UUID.UUIDString,
        @"primary_type": NSPasteboardTypeString,
        @"is_color_code": @NO,
    }];

    NSMenuItem *beforePrefetch = [menuManager clipMenuItemForClipItem:clipItem globalIndex:0];
    XCTAssertNotNil(beforePrefetch);
    XCTAssertNil(beforePrefetch.image);
    XCTAssertNil(beforePrefetch.accessibilityHelp);

    XCTestExpectation *prefetchExpectation = [self expectationWithDescription:@"prefetch clip data fallback"];
    [menuManager prefetchClipDataFallbackForClipItems:@[clipItem] completion:^{
        [prefetchExpectation fulfill];
    }];
    [self waitForExpectations:@[prefetchExpectation] timeout:2.0];

    NSMenuItem *afterPrefetch = [menuManager clipMenuItemForClipItem:clipItem globalIndex:0];
    XCTAssertNotNil(afterPrefetch.image);
    XCTAssertEqualObjects(afterPrefetch.accessibilityHelp, clipData.stringValue);

    [self removeFileIfExistsAtPath:dataPath];
}

- (void)testPrefetchMarksInFlightToAvoidDuplicateClipDataLoad {
    RCTestMenuManager *menuManager = [[RCTestMenuManager alloc] init];

    RCClipData *clipData = [[RCClipData alloc] init];
    clipData.stringValue = @"rgba(12, 34, 56, 0.7)";
    clipData.primaryType = NSPasteboardTypeString;

    NSString *dataPath = [self newClipDataPathWithIdentifier:NSUUID.UUID.UUIDString];
    XCTAssertTrue([clipData saveToPath:dataPath]);

    RCClipItem *clipItem = [[RCClipItem alloc] initWithDictionary:@{
        @"id": @4,
        @"data_path": dataPath,
        @"title": @"",
        @"data_hash": NSUUID.UUID.UUIDString,
        @"primary_type": NSPasteboardTypeString,
        @"is_color_code": @NO,
    }];

    XCTestExpectation *first = [self expectationWithDescription:@"first prefetch"];
    XCTestExpectation *second = [self expectationWithDescription:@"second prefetch"];
    [menuManager prefetchClipDataFallbackForClipItems:@[clipItem] completion:^{
        [first fulfill];
    }];
    [menuManager prefetchClipDataFallbackForClipItems:@[clipItem] completion:^{
        [second fulfill];
    }];

    [self waitForExpectations:@[first, second] timeout:2.0];
    XCTAssertEqual(menuManager.clipDataLoadCallCount, 1);

    [self removeFileIfExistsAtPath:dataPath];
}

- (void)testTooltipPayloadFallbackIsAppliedOnNextMenuRebuild {
    RCTestMenuManager *menuManager = [[RCTestMenuManager alloc] init];

    RCClipData *clipData = [[RCClipData alloc] init];
    clipData.URLString = @"https://example.com/fallback";
    clipData.primaryType = NSPasteboardTypeURL;

    NSString *dataPath = [self newClipDataPathWithIdentifier:NSUUID.UUID.UUIDString];
    XCTAssertTrue([clipData saveToPath:dataPath]);

    RCClipItem *clipItem = [[RCClipItem alloc] initWithDictionary:@{
        @"id": @3,
        @"data_path": dataPath,
        @"title": @"",
        @"data_hash": NSUUID.UUID.UUIDString,
        @"primary_type": NSPasteboardTypeURL,
        @"is_color_code": @NO,
    }];

    NSMenuItem *beforePrefetch = [menuManager clipMenuItemForClipItem:clipItem globalIndex:0];
    XCTAssertNotNil(beforePrefetch);
    XCTAssertNil(beforePrefetch.accessibilityHelp);

    XCTestExpectation *prefetchExpectation = [self expectationWithDescription:@"prefetch tooltip fallback"];
    [menuManager prefetchClipDataFallbackForClipItems:@[clipItem] completion:^{
        [prefetchExpectation fulfill];
    }];
    [self waitForExpectations:@[prefetchExpectation] timeout:2.0];

    NSMenuItem *afterPrefetch = [menuManager clipMenuItemForClipItem:clipItem globalIndex:0];
    XCTAssertEqualObjects(afterPrefetch.accessibilityHelp, clipData.URLString);

    [self removeFileIfExistsAtPath:dataPath];
}

- (void)testTooltipPayloadFallbackCacheStoresTruncatedValue {
    RCTestMenuManager *menuManager = [[RCTestMenuManager alloc] init];
    [[NSUserDefaults standardUserDefaults] setInteger:12 forKey:kRCMaxLengthOfToolTipKey];

    NSMutableString *longText = [NSMutableString string];
    for (NSInteger index = 0; index < 64; index++) {
        [longText appendString:@"x"];
    }

    RCClipData *clipData = [[RCClipData alloc] init];
    clipData.stringValue = longText;
    clipData.primaryType = NSPasteboardTypeString;

    NSString *dataPath = [self newClipDataPathWithIdentifier:NSUUID.UUID.UUIDString];
    XCTAssertTrue([clipData saveToPath:dataPath]);

    RCClipItem *clipItem = [[RCClipItem alloc] initWithDictionary:@{
        @"id": @5,
        @"data_path": dataPath,
        @"title": @"",
        @"data_hash": NSUUID.UUID.UUIDString,
        @"primary_type": NSPasteboardTypeString,
        @"is_color_code": @NO,
    }];

    XCTestExpectation *prefetchExpectation = [self expectationWithDescription:@"prefetch long tooltip"];
    [menuManager prefetchClipDataFallbackForClipItems:@[clipItem] completion:^{
        [prefetchExpectation fulfill];
    }];
    [self waitForExpectations:@[prefetchExpectation] timeout:2.0];

    NSMenuItem *menuItem = [menuManager clipMenuItemForClipItem:clipItem globalIndex:0];
    XCTAssertNotNil(menuItem.accessibilityHelp);
    XCTAssertLessThanOrEqual(menuItem.accessibilityHelp.length, 12);

    [self removeFileIfExistsAtPath:dataPath];
}

// Drain real queues, then their main-queue completions. No sleep-based timing assertion.
- (void)drainMenuWork:(RCTestMenuManager *)manager {
    XCTestExpectation *done = [self expectationWithDescription:@"menu work drained"];
    dispatch_queue_t payloadQueue = [manager valueForKey:@"clipDataFallbackQueue"];
    dispatch_queue_t thumbnailQueue = [manager valueForKey:@"thumbnailGenerationQueue"];
    dispatch_async(payloadQueue, ^{
        dispatch_barrier_async(thumbnailQueue, ^{
            dispatch_async(dispatch_get_main_queue(), ^{ [done fulfill]; });
        });
    });
    [self waitForExpectations:@[done] timeout:5.0];
}

- (void)testBuildingHistoryDoesNotReadPayloadsAndHoverLoadsOnlySelectedText {
    RCDatabaseManager *database = [RCDatabaseManager shared];
    XCTAssertTrue([database setupDatabase]);
    RCClipData *data = [RCClipData new];
    data.stringValue = @"rgba(12, 34, 56, 0.7)";
    data.primaryType = NSPasteboardTypeString;
    NSString *path = [self newClipDataPathWithIdentifier:NSUUID.UUID.UUIDString];
    XCTAssertTrue([data saveToPath:path]);
    NSString *hash = NSUUID.UUID.UUIDString;
    XCTAssertTrue(([database insertClipItem:@{@"data_path":path, @"data_hash":hash,
        @"title":@"", @"primary_type":NSPasteboardTypeString, @"update_time":@2147483647}]));
    RCTestMenuManager *manager = [RCTestMenuManager new];
    NSMenu *built = [manager buildStandaloneMenu];
    XCTAssertNotNil(built);
    [self drainMenuWork:manager];
    XCTAssertEqual(manager.clipDataLoadCallCount, 0);
    XCTAssertEqual(manager.thumbnailLoadCallCount, 0);

    RCClipItem *clip = [[RCClipItem alloc] initWithDictionary:[database clipItemWithDataHash:hash]];
    NSMenuItem *item = [manager clipMenuItemForClipItem:clip globalIndex:0];
    NSMenu *menu = [NSMenu new];
    [menu addItem:item];
    [manager menuWillOpen:menu];
    [self drainMenuWork:manager];
    XCTAssertEqual(manager.clipDataLoadCallCount, 0);
    [manager menu:menu willHighlightItem:item];
    [self drainMenuWork:manager];
    XCTAssertEqual(manager.clipDataLoadCallCount, 1);
    XCTAssertEqualObjects(item.accessibilityHelp, data.stringValue);
    XCTAssertNotNil(item.image);
    [manager menu:menu willHighlightItem:item];
    [self drainMenuWork:manager];
    XCTAssertEqual(manager.clipDataLoadCallCount, 1);
    [database deleteClipItemWithDataHash:hash];
    [self removeFileIfExistsAtPath:path];
}

- (void)testOpeningImageMenuDoesNotRestorePayloadAndClosedFoldersDoNotLoadThumbnails {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kRCShowImageInTheMenuKey];
    RCTestMenuManager *manager = [RCTestMenuManager new];
    RCClipItem *clip = [[RCClipItem alloc] initWithDictionary:@{
        @"id":@101, @"data_path":@"image.rcclip", @"data_hash":@"image-fixture",
        @"thumbnail_path":@"image.thumb", @"primary_type":NSPasteboardTypeTIFF}];
    NSMenuItem *item = [manager clipMenuItemForClipItem:clip globalIndex:0];
    NSMenu *child = [NSMenu new];
    [child addItem:item];
    NSMenuItem *folder = [NSMenuItem new];
    folder.submenu = child;
    NSMenu *root = [NSMenu new];
    [root addItem:folder];
    [manager menuWillOpen:root];
    [self drainMenuWork:manager];
    XCTAssertEqual(manager.thumbnailLoadCallCount, 0);
    [manager menuWillOpen:child];
    [manager menuWillOpen:child];
    [self drainMenuWork:manager];
    XCTAssertEqual(manager.clipDataLoadCallCount, 0);
    XCTAssertEqual(manager.thumbnailLoadCallCount, 1);
    XCTAssertNotNil(item.image);
}

- (void)testReplacementMenuItemWaitsForInFlightPayload {
    RCTestMenuManager *manager = [RCTestMenuManager new];
    RCClipData *data = [RCClipData new];
    data.stringValue = @"full tooltip after rebuild";
    data.primaryType = NSPasteboardTypeString;
    NSString *path = [self newClipDataPathWithIdentifier:NSUUID.UUID.UUIDString];
    XCTAssertTrue([data saveToPath:path]);
    RCClipItem *clip = [[RCClipItem alloc] initWithDictionary:@{
        @"id":@201, @"data_path":path, @"data_hash":@"replacement-fixture",
        @"title":@"short", @"primary_type":NSPasteboardTypeString}];
    XCTestExpectation *entered = [self expectationWithDescription:@"payload read entered"];
    manager.willLoadClip = ^{ [entered fulfill]; };
    manager.loadRelease = dispatch_semaphore_create(0);
    NSMenuItem *oldItem = [manager clipMenuItemForClipItem:clip globalIndex:0];
    NSMenu *menu = [NSMenu new];
    [manager menu:menu willHighlightItem:oldItem];
    [self waitForExpectations:@[entered] timeout:2.0];
    NSMenuItem *replacement = [manager clipMenuItemForClipItem:clip globalIndex:0];
    [manager menu:menu willHighlightItem:replacement];
    // Let any incorrectly early main-queue completion run before releasing I/O.
    XCTestExpectation *mainTurn = [self expectationWithDescription:@"main turn"];
    dispatch_async(dispatch_get_main_queue(), ^{ [mainTurn fulfill]; });
    [self waitForExpectations:@[mainTurn] timeout:2.0];
    dispatch_semaphore_signal(manager.loadRelease);
    [self drainMenuWork:manager];
    XCTAssertEqual(manager.clipDataLoadCallCount, 1);
    XCTAssertEqualObjects(replacement.accessibilityHelp, data.stringValue);
    [self removeFileIfExistsAtPath:path];
}

@end
