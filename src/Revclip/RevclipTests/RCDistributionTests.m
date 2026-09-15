#import <XCTest/XCTest.h>
#import "RCUpdateService.h"

@interface RCUpdateService (DistributionTesting)
- (NSString *)updateFeedURL;
- (BOOL)loadSparkleFrameworkIfAvailableWithError:(NSError **)error;
@end

@interface RCUnconfiguredDistributionUpdater : RCUpdateService
@property BOOL attemptedFrameworkLoad;
@end
@implementation RCUnconfiguredDistributionUpdater
- (NSString *)updateFeedURL { return @""; }
- (BOOL)loadSparkleFrameworkIfAvailableWithError:(NSError **)error {
    self.attemptedFrameworkLoad = YES;
    return NO;
}
@end

@interface RCDistributionTests : XCTestCase
@end
@implementation RCDistributionTests
- (void)testDistributionWithoutFeedNeverStartsUpdater {
    RCUnconfiguredDistributionUpdater *updater = [RCUnconfiguredDistributionUpdater new];
    [updater setupUpdater];
    XCTAssertFalse(updater.attemptedFrameworkLoad);
    XCTAssertFalse(updater.canCheckForUpdates);
    XCTAssertEqual(updater.lastError.code, 7);
}
@end
