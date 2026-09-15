#import <XCTest/XCTest.h>
#import "RCLinkPreviewService.h"
@import LinkPresentation;

@interface RCLinkPreviewService (Testing)
- (instancetype)initWithProviderFactory:(LPMetadataProvider *(^)(void))factory;
- (NSTimeInterval)now;
@end
@interface RCTestLinkService : RCLinkPreviewService
@property NSTimeInterval time;
@end
@implementation RCTestLinkService
- (NSTimeInterval)now { return self.time; }
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
@end
@implementation RCLinkPreviewServiceTests
- (void)setUp {
    self.providers = [NSMutableArray array];
    NSMutableArray *providers = self.providers;
    self.service = [[RCTestLinkService alloc] initWithProviderFactory:^{
        RCFakeLinkProvider *provider = [RCFakeLinkProvider new]; [providers addObject:provider]; return provider;
    }];
    self.service.time = 100;
}
- (void)tearDown { [self.service clearCache]; }
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
@end
