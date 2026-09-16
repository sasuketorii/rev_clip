#import <XCTest/XCTest.h>
#import "RCClipboardService.h"
#import "RCClipData.h"
#import <sys/resource.h>
#import <mach/mach.h>

static double RCPollingCPUSeconds(void) {
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) != 0) return -1;
    return usage.ru_utime.tv_sec + usage.ru_stime.tv_sec +
        (usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000000.0;
}
static uint64_t RCPollingResidentBytes(void) {
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count=MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return info.resident_size;
}

@interface RCClipboardService (PollingTesting)
- (void)pollPasteboardOnMonitoringQueue;
- (BOOL)canReadPasteboardContentsUsingPrivacyGate;
- (BOOL)sourceIsExcluded:(NSString *)source;
- (RCClipData *)readEligibleClipFromPasteboard:(NSPasteboard *)board sourceBundleIdentifier:(NSString *)source;
- (void)processClipDataOnMonitoringQueue:(RCClipData *)clip sourceBundleIdentifier:(NSString *)source;
@end

// Keep the real startMonitoring timer, acquisition and queue dispatch. Only
// privacy/exclusion policy and persistence are replaced; no DB or real keys.
@interface RCPollingProbe : RCClipboardService
@property(nonatomic) NSTimeInterval origin;
@property(nonatomic) NSUInteger adaptiveIntervalMS;
@property(nonatomic) NSTimeInterval fastStarted;
@property(nonatomic) NSTimeInterval fastUntil;
@property(nonatomic) NSTimeInterval cooldownUntil;
@property(nonatomic) NSUInteger currentIntervalMS;
@property(nonatomic) uint64_t sampledPeakRSS;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *polls;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *observations;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *persistences;
@end
@implementation RCPollingProbe
- (instancetype)init {
    self=[super init];
    if (self) { _observations=[NSMutableArray array]; _persistences=[NSMutableArray array]; _polls=[NSMutableArray array]; _currentIntervalMS=500; }
    return self;
}
- (void)pollPasteboardOnMonitoringQueue {
    NSUInteger before;
    @synchronized(self) { before=self.observations.count; }
    [super pollPasteboardOnMonitoringQueue];
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    @synchronized(self) {
        BOOL changed=self.observations.count>before;
        self.sampledPeakRSS=MAX(self.sampledPeakRSS,RCPollingResidentBytes());
        [self.polls addObject:@{@"t_ms":@((now-self.origin)*1000), @"observed_change":@(changed),
                               @"scheduled_interval_ms":@(self.currentIntervalMS)}];
        if (!self.adaptiveIntervalMS || !self.isMonitoring) return;
        // No producer hint or extra clipboard read: adapt only after the real
        // acquisition path observed a new snapshot. Hard cap each fast period
        // at two seconds, then force at least one second of 500 ms polling.
        if (self.fastUntil && (now>=self.fastUntil || now-self.fastStarted>=2.0)) {
            self.fastUntil=0; self.cooldownUntil=now+1.0;
        }
        if (changed && now>=self.cooldownUntil) {
            if (!self.fastUntil) self.fastStarted=now;
            self.fastUntil=MIN(now+1.0,self.fastStarted+2.0);
        }
        NSUInteger next=self.fastUntil>now ? self.adaptiveIntervalMS : 500;
        if (next!=self.currentIntervalMS) {
            // Change only this test instance's existing timer; retain the real
            // handler, serial acquisition path and persistence handoff.
            dispatch_source_t timer=[self valueForKey:@"monitorTimer"];
            if (timer) {
                uint64_t interval=next*NSEC_PER_MSEC;
                dispatch_source_set_timer(timer,dispatch_time(DISPATCH_TIME_NOW,(int64_t)interval),interval,interval/10);
                self.currentIntervalMS=next;
            }
        }
    }
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
// Run this test alone in the parent's serialized Release/RC_TESTING harness.
// Experiment: -only-testing:RevclipTests/RCClipboardPollingTests/testBoundedAdaptivePoliciesAgainstFixed500ms
// Regular suite: -skip-testing:RevclipTests/RCClipboardPollingTests/testBoundedAdaptivePoliciesAgainstFixed500ms
// No environment skip: explicitly selected experiments must execute every row.
// Three shared phases x six workloads x three policies = 54 rows (~164 seconds).
- (void)testBoundedAdaptivePoliciesAgainstFixed500ms {
    NSUInteger trial=0;
    for (NSNumber *phase in @[@73,@137,@311]) {
        trial++;
        for (NSNumber *cadence in @[@1000,@500,@250,@100,@50,@0]) {
            // Reverse policy order on alternating workloads to expose order bias.
            NSArray *basePolicies=([cadence integerValue]==500 || [cadence integerValue]==100)
                ? @[@100,@250,@0] : @[@0,@250,@100];
            // Each policy occupies each execution position once across phases.
            NSUInteger rotation=(trial-1)%3;
            NSArray *policies=@[basePolicies[rotation],basePolicies[(rotation+1)%3],basePolicies[(rotation+2)%3]];
            for (NSNumber *fastMS in policies) {
                NSUInteger samples=cadence.unsignedIntegerValue ? 6 : 0;
                NSTimeInterval duration=samples ? (phase.doubleValue+samples*cadence.doubleValue+600)/1000.0 : 3.0;
                NSMutableArray *produced=[NSMutableArray array];
                NSMutableSet *observedBeforeOverwrite=[NSMutableSet set];
                NSMutableArray *overwritten=[NSMutableArray array];
                XCTestExpectation *finished=[self expectationWithDescription:
                    [NSString stringWithFormat:@"polling trial %lu phase %@ cadence %@ policy %@",(unsigned long)trial,phase,cadence,fastMS]];
                __block RCPollingProbe *probe;
                __block BOOL isolated=NO;
                __block double cpuStart=-1;
                __block uint64_t rssStart=0;
                [self onMain:^{
                    NSPasteboard *board=NSPasteboard.generalPasteboard;
                    isolated=board && ![board.name isEqual:NSPasteboardNameGeneral];
                    XCTAssertTrue(isolated);
                    if (!isolated) return;
                    [board clearContents];
                    probe=[RCPollingProbe new]; probe.adaptiveIntervalMS=fastMS.unsignedIntegerValue;
                    self.activeProbe=probe;
                    probe.origin=NSProcessInfo.processInfo.systemUptime;
                    rssStart=RCPollingResidentBytes(); cpuStart=RCPollingCPUSeconds();
                    [probe startMonitoring];
                    for (NSUInteger index=0; index<samples; index++) {
                        int64_t delay=(int64_t)((phase.doubleValue+(index+1)*cadence.doubleValue)*NSEC_PER_MSEC);
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,delay),dispatch_get_main_queue(), ^{
                            if (self.activeProbe!=probe) return;
                            // Acquisition materializes the named board on main, so
                            // this boundary distinguishes overwritten-before-read
                            // from observed-but-not-yet-processed snapshots.
                            @synchronized(probe) {
                                for (NSDictionary *event in probe.observations) [observedBeforeOverwrite addObject:event[@"id"]];
                            }
                            NSString *previous=[produced.lastObject objectForKey:@"id"];
                            if (previous && ![observedBeforeOverwrite containsObject:previous]) [overwritten addObject:previous];
                            NSString *value=[NSString stringWithFormat:@"comparison-%lu-%@-%lu",(unsigned long)trial,cadence,(unsigned long)index];
                            [board clearContents];
                            BOOL wrote=[board setString:value forType:NSPasteboardTypeString]; XCTAssertTrue(wrote);
                            if (wrote) [produced addObject:@{@"id":value,
                                @"t_ms":@((NSProcessInfo.processInfo.systemUptime-probe.origin)*1000)}];
                        });
                    }
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(duration*NSEC_PER_SEC)),dispatch_get_main_queue(), ^{
                        if (self.activeProbe!=probe) return;
                        [probe stopMonitoring]; [finished fulfill];
                    });
                }];
                if (!isolated) return;
                [self waitForExpectations:@[finished] timeout:duration+5];
                [self stopAndDrainActiveProbe];
                double cpuEnd=RCPollingCPUSeconds();
                uint64_t rssEnd=RCPollingResidentBytes();
                NSTimeInterval elapsed=NSProcessInfo.processInfo.systemUptime-probe.origin;
                __block NSArray *production, *lost;
                [self onMain:^{ production=[produced copy]; lost=[overwritten copy]; }];
                NSArray *observed, *processed, *polls;
                uint64_t peak;
                @synchronized(probe) {
                    observed=[probe.observations copy]; processed=[probe.persistences copy]; polls=[probe.polls copy];
                    peak=MAX(MAX(rssStart,rssEnd),probe.sampledPeakRSS);
                }
                NSSet *observedIDs=[NSSet setWithArray:[observed valueForKey:@"id"]];
                NSMutableArray *pending=[NSMutableArray array];
                NSMutableArray *latencies=[NSMutableArray array];
                for (NSDictionary *event in production) {
                    if (![observedIDs containsObject:event[@"id"]] && ![lost containsObject:event[@"id"]]) [pending addObject:event[@"id"]];
                    for (NSDictionary *read in observed) if ([read[@"id"] isEqual:event[@"id"]]) {
                        [latencies addObject:@([read[@"t_ms"] doubleValue]-[event[@"t_ms"] doubleValue])]; break;
                    }
                }
                NSDictionary *metric=@{@"policy":fastMS.unsignedIntegerValue ? [NSString stringWithFormat:@"bounded_%@ms",fastMS] : @"fixed_500ms",
                    @"producer_interval_ms":cadence, @"idle_trial":@(samples==0), @"phase_ms":phase, @"trial":@(trial),
                    @"fast_hold_ms":@1000, @"fast_cap_ms":@2000, @"cooldown_ms":@1000,
                    @"elapsed_ms":@(elapsed*1000), @"produced_count":@(production.count),
                    @"observed_count":@(observed.count), @"processed_count":@(processed.count),
                    @"overwritten_before_observation_count":@(lost.count), @"unobserved_at_stop_count":@(pending.count),
                    @"poll_count":@(polls.count), @"process_cpu_ms":@((cpuEnd-cpuStart)*1000),
                    @"process_cpu_percent":@((cpuEnd-cpuStart)/elapsed*100), @"rss_start_bytes":@(rssStart),
                    @"rss_end_bytes":@(rssEnd), @"rss_sampled_peak_bytes":@(peak),
                    @"acquisition_latency_ms":latencies, @"produced":production, @"observed":observed,
                    @"processed":processed, @"overwritten_ids":lost, @"unobserved_at_stop_ids":pending, @"polls":polls,
                    @"measurement_scope":@"single_XCTest_host_process_short_synthetic_trial",
                    @"persistence":@"in_memory_boundary_not_disk"};
                NSData *json=[NSJSONSerialization dataWithJSONObject:metric options:NSJSONWritingSortedKeys error:nil];
                XCTAssertNotNil(json); XCTAssertGreaterThanOrEqual(cpuStart,0); XCTAssertGreaterThanOrEqual(cpuEnd,cpuStart);
                XCTAssertGreaterThan(rssStart,0u); XCTAssertGreaterThan(rssEnd,0u);
                fprintf(stderr,"RC_POLLING_COMPARISON %s\n",[[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] UTF8String]);
                XCTAssertEqual(production.count,samples);
                XCTAssertEqualObjects([observed valueForKey:@"id"],[processed valueForKey:@"id"]);
                XCTAssertEqual(observedIDs.count+lost.count+pending.count,production.count);
                for (NSString *identifier in lost) XCTAssertFalse([observedIDs containsObject:identifier]);
                if (!samples) { XCTAssertEqual(observed.count,0u); XCTAssertGreaterThan(polls.count,0u); }
            }
        }
    }
}
@end
