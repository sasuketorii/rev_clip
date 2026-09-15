#import <XCTest/XCTest.h>
#import "RCClipboardService.h"
#import "RCClipData.h"

@interface RCClipboardService (PollingTesting)
- (BOOL)canReadPasteboardContentsUsingPrivacyGate;
- (BOOL)sourceIsExcluded:(NSString *)source;
- (RCClipData *)readEligibleClipFromPasteboard:(NSPasteboard *)board sourceBundleIdentifier:(NSString *)source;
- (void)processClipDataOnMonitoringQueue:(RCClipData *)clip sourceBundleIdentifier:(NSString *)source;
@end

// Keep the real startMonitoring timer, acquisition and queue dispatch. Only
// privacy/exclusion policy and persistence are replaced; no DB or real keys.
@interface RCPollingProbe : RCClipboardService
@property(nonatomic) NSTimeInterval origin;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *observations;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *persistences;
@end
@implementation RCPollingProbe
- (instancetype)init {
    self=[super init];
    if (self) { _observations=[NSMutableArray array]; _persistences=[NSMutableArray array]; }
    return self;
}
- (BOOL)canReadPasteboardContentsUsingPrivacyGate { return YES; }
- (BOOL)sourceIsExcluded:(NSString *)source { (void)source; return NO; }
- (NSDictionary *)eventForClip:(RCClipData *)clip {
    return @{@"id":clip.stringValue, @"t_ms":@((NSProcessInfo.processInfo.systemUptime-self.origin)*1000)};
}
- (RCClipData *)readEligibleClipFromPasteboard:(NSPasteboard *)board sourceBundleIdentifier:(NSString *)source {
    (void)source;
    RCClipData *clip=[super readEligibleClipFromPasteboard:board sourceBundleIdentifier:@"test.synthetic.polling"];
    if (clip.stringValue.length) {
        @synchronized(self) { [self.observations addObject:[self eventForClip:clip]]; }
    }
    return clip;
}
- (void)processClipDataOnMonitoringQueue:(RCClipData *)clip sourceBundleIdentifier:(NSString *)source {
    (void)source;
    if (clip.stringValue.length) {
        @synchronized(self) { [self.persistences addObject:[self eventForClip:clip]]; }
    }
}
@end

@interface RCClipboardPollingTests : XCTestCase
@property(nonatomic, strong) RCPollingProbe *activeProbe;
@end
@implementation RCClipboardPollingTests
- (void)onMain:(dispatch_block_t)block {
    if (NSThread.isMainThread) block(); else dispatch_sync(dispatch_get_main_queue(), block);
}
- (void)stopAndDrainActiveProbe {
    RCPollingProbe *probe=self.activeProbe;
    if (!probe) return;
    [self onMain:^{
        // Invalidate all scheduled synthetic writers before moving to a trial.
        self.activeProbe=nil;
        [probe stopMonitoring];
    }];
    XCTestExpectation *drained=[self expectationWithDescription:@"polling acquisition and persistence drained"];
    [probe flushQueueWithCompletion:^{ [drained fulfill]; }];
    [self waitForExpectations:@[drained] timeout:5];
}
- (void)tearDown {
    [self stopAndDrainActiveProbe];
    [super tearDown];
}
- (void)testRealPollingTimerAcrossSyntheticProducerIntervals {
    // Six samples at each cadence, then 600 ms (one 500 ms tick + scheduling
    // margin) before stopping/draining. Nominal total is 14.4 seconds.
    // Counts are measurements: writes overwritten before observation are not
    // recoverable, and are intentionally not asserted to have been captured.
    for (NSNumber *milliseconds in @[@1000, @500, @250, @100, @50]) {
        NSMutableArray<NSDictionary *> *produced=[NSMutableArray array];
        XCTestExpectation *finished=[self expectationWithDescription:
            [NSString stringWithFormat:@"%@ms producer plus final polling tick",milliseconds]];
        __block RCPollingProbe *probe;
        __block BOOL isolated=NO;
        [self onMain:^{
            // Constructor isolation must already redirect this accessor. Never
            // snapshot, clear or restore the real general clipboard.
            NSPasteboard *board=NSPasteboard.generalPasteboard;
            isolated=board && ![board.name isEqual:NSPasteboardNameGeneral];
            XCTAssertTrue(isolated, @"Refuse to run against the general clipboard");
            if (!isolated) return;
            [board clearContents];
            probe=[RCPollingProbe new];
            self.activeProbe=probe;
            probe.origin=NSProcessInfo.processInfo.systemUptime;
            [probe startMonitoring];
            for (NSUInteger index=0; index<6; index++) {
                int64_t delay=(int64_t)((index+1)*milliseconds.doubleValue*NSEC_PER_MSEC);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,delay),dispatch_get_main_queue(), ^{
                    if (self.activeProbe!=probe) return;
                    NSString *value=[NSString stringWithFormat:@"polling-%@-%lu",milliseconds,(unsigned long)index];
                    [board clearContents];
                    BOOL wrote=[board setString:value forType:NSPasteboardTypeString];
                    XCTAssertTrue(wrote);
                    if (wrote) [produced addObject:@{@"id":value,
                        @"t_ms":@((NSProcessInfo.processInfo.systemUptime-probe.origin)*1000)}];
                });
            }
            int64_t end=(int64_t)((6*milliseconds.doubleValue+600)*NSEC_PER_MSEC);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,end),dispatch_get_main_queue(), ^{
                if (self.activeProbe!=probe) return;
                [probe stopMonitoring];
                [finished fulfill];
            });
        }];
        if (!isolated) return;
        [self waitForExpectations:@[finished] timeout:6*milliseconds.doubleValue/1000+4];
        [self stopAndDrainActiveProbe];
        __block NSArray *production;
        [self onMain:^{ production=[produced copy]; }];
        NSArray *observed;
        NSArray *persisted;
        @synchronized(probe) {
            observed=[probe.observations copy];
            persisted=[probe.persistences copy];
        }
        NSDictionary *metric=@{@"producer_interval_ms":milliseconds, @"poll_interval_ms":@500,
            @"samples":@6, @"final_wait_ms":@600, @"persistence":@"in_memory_boundary_not_disk",
            @"produced_count":@(production.count), @"observed_count":@(observed.count),
            @"persisted_count":@(persisted.count), @"produced":production,
            @"observed":observed, @"persisted":persisted};
        NSData *json=[NSJSONSerialization dataWithJSONObject:metric options:NSJSONWritingSortedKeys error:nil];
        XCTAssertNotNil(json);
        fprintf(stderr, "RC_POLLING_METRIC %s\n", [[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] UTF8String]);
        XCTAssertEqual(production.count,6u);
        // Every snapshot that reached acquisition must reach fake persistence.
        // This assertion distinguishes queue loss from unobservable overwrites.
        XCTAssertEqualObjects([observed valueForKey:@"id"],[persisted valueForKey:@"id"]);
        NSSet *producedIDs=[NSSet setWithArray:[production valueForKey:@"id"]];
        for (NSDictionary *event in observed) XCTAssertTrue([producedIDs containsObject:event[@"id"]]);
        XCTAssertGreaterThan(observed.count,0u, @"The real timer must actually observe at least one sample");
    }
}
@end
