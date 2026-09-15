#import <XCTest/XCTest.h>
#import "RCClipboardService.h"
#import "RCClipData.h"

@interface RCClipboardService (BackpressureTesting)
- (void)enqueueCapturedClip:(RCClipData *)clip source:(NSString *)source;
- (NSUInteger)pendingCostForClip:(RCClipData *)clip;
@end

@interface RCBackpressureClip : RCClipData
@property NSUInteger syntheticCost;
@end
@implementation RCBackpressureClip
@end

// Observe entry into the real condition wait, not a timing-based guess that
// a worker has been scheduled. The production lock/wait/signal still execute.
@interface RCBackpressureCondition : NSCondition
@property (nonatomic, strong) XCTestExpectation *waitEntered;
@end
@implementation RCBackpressureCondition
- (void)wait {
    XCTestExpectation *entered = self.waitEntered;
    self.waitEntered = nil;
    [entered fulfill];
    [super wait];
}
@end

@interface RCBackpressureProbe : RCClipboardService
@property (nonatomic, strong) dispatch_semaphore_t releaseSave;
@property (nonatomic, strong) XCTestExpectation *saveEntered;
@property (nonatomic, strong) NSMutableArray<RCClipData *> *persisted;
@end
@implementation RCBackpressureProbe
// No board access, including during superclass initialization.
- (NSInteger)readGeneralPasteboardChangeCount { return 0; }
- (instancetype)init {
    if ((self = [super init])) {
        _releaseSave = dispatch_semaphore_create(0);
        _persisted = [NSMutableArray array];
    }
    return self;
}
- (NSUInteger)pendingCostForClip:(RCClipData *)clip {
    return ((RCBackpressureClip *)clip).syntheticCost;
}
- (BOOL)saveClipData:(RCClipData *)clip toPath:(NSString *)path {
    // Synthetic save seam: exercise production admission/accounting, with no
    // serialization, filesystem, database, key or pasteboard access.
    if (self.saveEntered && self.persisted.count == 0) {
        [self.saveEntered fulfill];
        long result = dispatch_semaphore_wait(self.releaseSave, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
        XCTAssertEqual(result, 0L);
    }
    return YES;
}
- (void)processClipDataOnMonitoringQueue:(RCClipData *)clip sourceBundleIdentifier:(NSString *)source {
    XCTAssertFalse(NSThread.isMainThread);
    if ([self saveClipData:clip toPath:@""]) [self.persisted addObject:clip];
}
@end

@interface RCClipboardBackpressureTests : XCTestCase
@property (nonatomic, strong) RCBackpressureProbe *probe;
@property (nonatomic, strong) RCBackpressureCondition *condition;
@end
@implementation RCClipboardBackpressureTests
- (void)setUp {
    [super setUp];
    self.probe = [RCBackpressureProbe new];
    self.condition = [RCBackpressureCondition new];
    [self.probe setValue:self.condition forKey:@"pendingCondition"];
}
- (void)drain {
    XCTestExpectation *done = [self expectationWithDescription:@"acquisition and persistence drained"];
    [self.probe flushQueueWithCompletion:^{ [done fulfill]; }];
    [self waitForExpectations:@[done] timeout:15];
}
- (void)tearDown {
    // Suspend notification-triggered acquisition before draining queued work.
    // XCTest may retain this case after teardown while other tests change privacy.
    [self.probe stopMonitoring];
    dispatch_semaphore_signal(self.probe.releaseSave);
    [self drain];
    self.probe.saveEntered = nil;
    self.condition.waitEntered = nil;
    [self.probe.persisted removeAllObjects];
    self.probe = nil;
    self.condition = nil;
    [super tearDown];
}
- (RCBackpressureClip *)clip:(NSUInteger)index cost:(NSUInteger)cost {
    RCBackpressureClip *clip = [RCBackpressureClip new];
    clip.stringValue = [NSString stringWithFormat:@"original-%lu", (unsigned long)index];
    clip.syntheticCost = cost;
    return clip;
}
- (void)assertPendingCount:(NSUInteger)count bytes:(NSUInteger)bytes {
    [self.condition lock];
    NSUInteger actualCount = [[self.probe valueForKey:@"pendingCaptureCount"] unsignedIntegerValue];
    NSUInteger actualBytes = [[self.probe valueForKey:@"pendingCaptureBytes"] unsignedIntegerValue];
    [self.condition unlock];
    XCTAssertEqual(actualCount, count);
    XCTAssertEqual(actualBytes, bytes);
}
- (void)verifyBlockedAfterCosts:(NSArray<NSNumber *> *)costs nextCost:(NSUInteger)nextCost {
    NSMutableArray<RCBackpressureClip *> *originals = [NSMutableArray array];
    NSUInteger bytes = 0;
    for (NSNumber *cost in costs) {
        [originals addObject:[self clip:originals.count cost:cost.unsignedIntegerValue]];
        bytes += cost.unsignedIntegerValue;
    }
    [originals addObject:[self clip:originals.count cost:nextCost]];
    self.probe.saveEntered = [self expectationWithDescription:@"first save gated"];
    self.condition.waitEntered = [self expectationWithDescription:@"next original waits for capacity"];
    XCTestExpectation *waitEntered = self.condition.waitEntered;
    XCTestExpectation *allAdmitted = [self expectationWithDescription:@"all originals admitted after release"];
    dispatch_queue_t monitoring = [self.probe valueForKey:@"monitoringQueue"];
    dispatch_async(monitoring, ^{
        for (RCClipData *clip in originals) [self.probe enqueueCapturedClip:clip source:@"synthetic"];
        [allAdmitted fulfill];
    });
    [self waitForExpectations:@[self.probe.saveEntered, waitEntered] timeout:3];
    // Taking the condition lock ensures the waiter has released it in wait.
    // At this boundary the final original is acquired but cannot be admitted.
    [self assertPendingCount:costs.count bytes:bytes];
    dispatch_semaphore_signal(self.probe.releaseSave);
    [self waitForExpectations:@[allAdmitted] timeout:5];
    [self drain];
    XCTAssertEqual(self.probe.persisted.count, originals.count);
    for (NSUInteger i = 0; i < MIN(originals.count, self.probe.persisted.count); i++) {
        XCTAssertTrue(self.probe.persisted[i] == originals[i]);
        XCTAssertEqualObjects(self.probe.persisted[i].stringValue, originals[i].stringValue);
    }
    [self assertPendingCount:0 bytes:0];
}
- (void)testSeventeenthOriginalWaitsAtSixteenItemLimitWithoutLoss {
    NSMutableArray *costs = [NSMutableArray array];
    for (NSUInteger i = 0; i < 16; i++) [costs addObject:@1024];
    [self verifyBlockedAfterCosts:costs nextCost:1024];
}
- (void)testByteBudgetWaitsEvenBelowItemLimit {
    [self verifyBlockedAfterCosts:@[@(60 * 1024 * 1024)] nextCost:50 * 1024 * 1024];
}
- (void)testOversizedOriginalWaitsUntilAlone {
    [self verifyBlockedAfterCosts:@[@1024] nextCost:101 * 1024 * 1024];
}
- (void)testOversizedOriginalAdmittedAloneBlocksFollowingOriginal {
    [self verifyBlockedAfterCosts:@[@(101 * 1024 * 1024)] nextCost:1024];
}
- (void)testTenThousandOriginalsPersistInOrderAcrossBatches {
    NSMutableArray<RCBackpressureClip *> *originals = [NSMutableArray arrayWithCapacity:10000];
    for (NSUInteger i = 0; i < 10000; i++) [originals addObject:[self clip:i cost:1024]];
    dispatch_queue_t monitoring = [self.probe valueForKey:@"monitoringQueue"];
    for (NSUInteger start = 0; start < originals.count; start += 250) {
        NSUInteger batchStart = start;
        dispatch_async(monitoring, ^{
            for (NSUInteger i = batchStart; i < batchStart + 250; i++) {
                [self.probe enqueueCapturedClip:originals[i] source:@"synthetic"];
            }
        });
        [self drain];
        XCTAssertEqual(self.probe.persisted.count, start + 250);
        [self assertPendingCount:0 bytes:0];
    }
    XCTAssertEqual(self.probe.persisted.count, 10000u);
    for (NSUInteger i = 0; i < MIN(originals.count, self.probe.persisted.count); i++) {
        XCTAssertTrue(self.probe.persisted[i] == originals[i]);
        XCTAssertEqualObjects(self.probe.persisted[i].stringValue,
                              ([NSString stringWithFormat:@"original-%lu", (unsigned long)i]));
    }
}
@end
