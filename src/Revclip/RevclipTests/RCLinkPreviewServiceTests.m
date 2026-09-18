#import <XCTest/XCTest.h>
#import "RCLinkPreviewService.h"
@import LinkPresentation;

@interface RCLinkPreviewService (Testing)
- (instancetype)initWithProviderFactory:(LPMetadataProvider *(^)(void))factory;
- (NSTimeInterval)now;
@end
@interface RCTestLinkService : RCLinkPreviewService
@property NSTimeInterval time;
@property NSUserDefaults *fixtureDefaults;
@end
@implementation RCTestLinkService
- (NSTimeInterval)now { return self.time; }
- (NSUserDefaults *)preferences { return self.fixtureDefaults; }
@end
@interface RCFakeLinkProvider : LPMetadataProvider
@property (copy) void (^reply)(LPLinkMetadata *, NSError *);
@property BOOL cancelled;
@end
@implementation RCFakeLinkProvider
- (void)startFetchingMetadataForURL:(NSURL *)url completionHandler:(void (^)(LPLinkMetadata *, NSError *))completionHandler { self.reply = completionHandler; }
- (void)cancel { self.cancelled = YES; }
@end
@interface RCLinkPreviewServiceTests : XCTestCase
@property RCTestLinkService *service;
@property NSMutableArray<RCFakeLinkProvider *> *providers;
@property (nonatomic, copy) NSString *suiteName;
@end
@implementation RCLinkPreviewServiceTests
- (void)setUp {
    self.providers = [NSMutableArray array];
    NSMutableArray *providers = self.providers;
    self.service = [[RCTestLinkService alloc] initWithProviderFactory:^{
        RCFakeLinkProvider *provider = [RCFakeLinkProvider new]; [providers addObject:provider]; return provider;
    }];
    self.suiteName = [@"revclip-link-tests-" stringByAppendingString:NSUUID.UUID.UUIDString];
    self.service.fixtureDefaults = [[NSUserDefaults alloc] initWithSuiteName:self.suiteName];
    self.service.previewMode = RCLinkPreviewModeAutomatic;
    self.service.time = 100;
}
- (void)tearDown {
    [self.service clearCache];
    [self.service.fixtureDefaults removePersistentDomainForName:self.suiteName];
}
- (void)tick {
    XCTestExpectation *tick = [self expectationWithDescription:@"main queue drained"];
    dispatch_async(dispatch_get_main_queue(), ^{ [tick fulfill]; });
    [self waitForExpectations:@[tick] timeout:2];
}
- (void)testDeduplicationQueueConcurrencyAndFailureExpiry {
    NSURL *a = [NSURL URLWithString:@"https://a.example/"];
    __block NSUInteger replies = 0;
    [self.service assetsForURL:a completion:^(RCLinkPreviewAssets *assets) { replies++; }];
    [self.service assetsForURL:a completion:^(RCLinkPreviewAssets *assets) { replies++; }];
    [self.service assetsForURL:[NSURL URLWithString:@"https://b.example/"] completion:^(RCLinkPreviewAssets *assets) {}];
    [self.service assetsForURL:[NSURL URLWithString:@"https://c.example/"] completion:^(RCLinkPreviewAssets *assets) {}];
    XCTAssertEqual(self.providers.count,2);
    self.providers[0].reply(nil,nil); [self tick];
    XCTAssertEqual(replies,2); XCTAssertEqual(self.providers.count,3);
    [self.service assetsForURL:a completion:^(RCLinkPreviewAssets *assets) { replies++; }];
    XCTAssertEqual(replies,3); XCTAssertEqual(self.providers.count,3);
    self.service.time += 61;
    [self.service assetsForURL:a completion:^(RCLinkPreviewAssets *assets) {}];
    XCTAssertEqual(self.providers.count,3); // waits behind the two active requests
    self.providers[1].reply(nil,nil); [self tick];
    XCTAssertEqual(self.providers.count,4);
}
- (void)testSelectiveRemovalCancelsOnlyRemovedURLsAndRejectsLateReplies {
    NSURL *a = [NSURL URLWithString:@"https://removed.example/"];
    NSURL *b = [NSURL URLWithString:@"https://retained.example/"];
    NSURL *c = [NSURL URLWithString:@"https://queued.example/"];
    __block NSUInteger removedReplies = 0, retainedReplies = 0;
    [self.service assetsForURL:a completion:^(RCLinkPreviewAssets *assets) { removedReplies++; }];
    [self.service assetsForURL:b completion:^(RCLinkPreviewAssets *assets) { retainedReplies++; }];
    [self.service assetsForURL:c completion:^(RCLinkPreviewAssets *assets) { removedReplies++; }];
    [self.service removeURLs:@[a, c]];
    XCTAssertEqual(removedReplies, 2u);
    XCTAssertEqual(retainedReplies, 0u);
    XCTAssertTrue(self.providers[0].cancelled);
    XCTAssertFalse(self.providers[1].cancelled);
    XCTAssertEqual(self.providers.count, 2u);
    self.providers[0].reply(nil, nil); [self tick];
    XCTAssertEqual(removedReplies, 2u);
    self.providers[1].reply(nil, nil); [self tick];
    [self.service assetsForURL:b completion:^(RCLinkPreviewAssets *assets) { retainedReplies++; }];
    XCTAssertEqual(retainedReplies, 2u);
    XCTAssertEqual(self.providers.count, 2u); // unrelated result remains cached
    [self.service assetsForURL:a completion:^(RCLinkPreviewAssets *assets) {}];
    XCTAssertEqual(self.providers.count, 3u);
}
- (void)testClearCancelsRequestsAndLateRepliesCannotRepopulateCache {
    NSURL *url = [NSURL URLWithString:@"https://a.example/"];
    __block NSUInteger replies = 0;
    [self.service assetsForURL:url completion:^(RCLinkPreviewAssets *assets) { replies++; }];
    RCFakeLinkProvider *old = self.providers[0];
    [self.service clearCache];
    XCTAssertTrue(old.cancelled); XCTAssertEqual(replies,1);
    old.reply(nil,nil); [self tick];
    [self.service assetsForURL:url completion:^(RCLinkPreviewAssets *assets) {}];
    XCTAssertEqual(self.providers.count,2);
}
- (void)testImageAndFaviconShareOneFetchAndBoundedCache {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:40 pixelsHigh:20 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    memset(bitmap.bitmapData,255,bitmap.bytesPerRow*bitmap.pixelsHigh);
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(40,20)]; [image addRepresentation:bitmap];
    LPLinkMetadata *metadata = [LPLinkMetadata new];
    metadata.imageProvider = [[NSItemProvider alloc] initWithObject:image];
    metadata.iconProvider = [[NSItemProvider alloc] initWithObject:image];
    NSURL *url = [NSURL URLWithString:@"https://a.example/"];
    XCTestExpectation *loaded = [self expectationWithDescription:@"both assets loaded"];
    [self.service assetsForURL:url completion:^(RCLinkPreviewAssets *assets) {
        XCTAssertNotNil(assets.image); XCTAssertNotNil(assets.favicon);
        XCTAssertEqual(assets.image.size.width,640); XCTAssertEqual(assets.favicon.size.width,16);
        XCTAssertEqual(assets.favicon.size.height,16); XCTAssertFalse(assets.favicon.template);
        [loaded fulfill];
    }];
    self.providers[0].reply(metadata,nil);
    [self waitForExpectations:@[loaded] timeout:4];
    XCTAssertNotNil([self.service cachedFaviconForURL:url]);
    __block BOOL cacheHit = NO;
    [self.service assetsForURL:url completion:^(RCLinkPreviewAssets *assets) { cacheHit = assets.image && assets.favicon; }];
    XCTAssertTrue(cacheHit); XCTAssertEqual(self.providers.count,1);
    self.service.time += 24*60*60+1;
    XCTAssertNil([self.service cachedFaviconForURL:url]);
}
- (void)testUnsetPolicyDefaultsToAutomatic {
    [self.service.fixtureDefaults removeObjectForKey:RCLinkPreviewModeKey];
    XCTAssertEqual(self.service.previewMode, RCLinkPreviewModeAutomatic);
    [self.service assetsForURL:[NSURL URLWithString:@"https://example.invalid/"] completion:^(RCLinkPreviewAssets *assets) {}];
    XCTAssertEqual(self.providers.count, 1u);
}
- (void)testExplicitManualModeNeverStartsImplicitRequests {
    self.service.previewMode = RCLinkPreviewModeManual;
    XCTAssertEqual(self.service.previewMode, RCLinkPreviewModeManual);
    NSURL *url = [NSURL URLWithString:@"https://example.invalid/private?token=synthetic"];
    __block NSUInteger completions = 0;
    [self.service assetsForURL:url completion:^(RCLinkPreviewAssets *assets) { completions++; }];
    [self.service imageForURL:url completion:^(NSImage *image) { completions++; }];
    XCTAssertNil([self.service cachedFaviconForURL:url]);
    XCTAssertEqual(completions, 2u);
    XCTAssertEqual(self.providers.count, 0u);
    [self.service assetsForURL:url userInitiated:YES completion:^(RCLinkPreviewAssets *assets) { completions++; }];
    XCTAssertEqual(self.providers.count, 1u);
    [self.service assetsForURL:[NSURL URLWithString:@"https://other.invalid/"] completion:^(RCLinkPreviewAssets *assets) {}];
    XCTAssertEqual(self.providers.count, 1u); // approval applies only to that invocation
}
- (void)testRevocationCancelsActiveAndQueuedWorkAndRejectsLateReplies {
    for (NSUInteger index = 0; index < 3; index++) {
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://site%lu.invalid/", (unsigned long)index]];
        [self.service assetsForURL:url completion:^(RCLinkPreviewAssets *assets) {}];
    }
    NSArray *old = [self.providers copy];
    XCTAssertEqual(old.count, 2u);
    self.service.previewMode = RCLinkPreviewModeDisabled;
    for (RCFakeLinkProvider *provider in old) { XCTAssertTrue(provider.cancelled); provider.reply(nil, nil); }
    [self tick];
    [self.service assetsForURL:[NSURL URLWithString:@"https://site0.invalid/"] userInitiated:YES completion:^(RCLinkPreviewAssets *assets) {}];
    XCTAssertEqual(self.providers.count, 2u);
    self.service.previewMode = RCLinkPreviewModeManual;
    [self.service assetsForURL:[NSURL URLWithString:@"https://site0.invalid/"] userInitiated:YES completion:^(RCLinkPreviewAssets *assets) {}];
    XCTAssertEqual(self.providers.count, 3u);
}
- (void)testMalformedPolicyFailsClosed {
    [self.service.fixtureDefaults setObject:@"automatic" forKey:RCLinkPreviewModeKey];
    XCTAssertEqual(self.service.previewMode, RCLinkPreviewModeDisabled);
    [self.service assetsForURL:[NSURL URLWithString:@"https://example.invalid/"] userInitiated:YES completion:^(RCLinkPreviewAssets *assets) {}];
    XCTAssertEqual(self.providers.count, 0u);
}
@end
