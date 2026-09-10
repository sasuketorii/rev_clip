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
@end

@interface RCTestMenuManager : RCMenuManager
@property (atomic, assign) NSInteger clipDataLoadCallCount;
@end

@implementation RCTestMenuManager

- (nullable RCClipData *)clipDataForPath:(NSString *)dataPath {
    self.clipDataLoadCallCount += 1;
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

@end
