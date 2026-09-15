#import <XCTest/XCTest.h>
#import <objc/message.h>
#import "RCClipboardService.h"
#import "RCClipData.h"

@interface RCClipboardService (FlowTesting)
- (void)pollPasteboardOnMonitoringQueue;
- (RCClipData *)readEligibleClipFromPasteboard:(NSPasteboard *)board sourceBundleIdentifier:(NSString *)source;
- (void)processClipDataOnMonitoringQueue:(RCClipData *)clip sourceBundleIdentifier:(NSString *)source;
@end
@interface RCFlowProbe : RCClipboardService
@property NSMutableArray<NSString *> *observed;
@property NSMutableArray<NSString *> *saved;
@property (copy) void (^processing)(void);
@end
@implementation RCFlowProbe
- (instancetype)init { if ((self=[super init])) { _observed=[NSMutableArray new]; _saved=[NSMutableArray new]; } return self; }
- (BOOL)canReadPasteboardContentsUsingPrivacyGate { return YES; }
- (BOOL)sourceIsExcluded:(NSString *)source { return NO; }
- (RCClipData *)readEligibleClipFromPasteboard:(NSPasteboard *)board sourceBundleIdentifier:(NSString *)source {
    RCClipData *clip=[super readEligibleClipFromPasteboard:board sourceBundleIdentifier:source];
    if (clip.stringValue) [self.observed addObject:clip.stringValue];
    return clip;
}
- (void)processClipDataOnMonitoringQueue:(RCClipData *)clip sourceBundleIdentifier:(NSString *)source {
    if (self.processing) self.processing();
    @synchronized (self.saved) { if (clip.stringValue) [self.saved addObject:clip.stringValue]; }
}
@end
@interface RCClipboardFlowTests : XCTestCase @end
@implementation RCClipboardFlowTests
- (RCFlowProbe *)probe {
    RCFlowProbe *p=[RCFlowProbe new]; [p setValue:@YES forKey:@"isMonitoring"]; return p;
}
- (void)write:(NSString *)value {
    // The test-bundle constructor redirects this accessor to a unique named board.
    NSPasteboard *p=NSPasteboard.generalPasteboard;
    XCTAssertNotEqualObjects(p.name, NSPasteboardNameGeneral);
    [p clearContents]; XCTAssertTrue([p setString:value forType:NSPasteboardTypeString]);
}
- (void)drain:(RCClipboardService *)service {
    XCTestExpectation *done=[self expectationWithDescription:@"capture and persistence drained"];
    [service flushQueueWithCompletion:^{ [done fulfill]; }];
    [self waitForExpectations:@[done] timeout:5];
}
- (void)testInternalWriteExcludesOnlyItsGenerationNotFollowingExternalCopies {
    RCFlowProbe *p=[self probe];
    [self write:@"internal-A"];
    SEL registration=NSSelectorFromString(@"recordInternalPasteboardChangeCount:");
    if ([p respondsToSelector:registration]) {
        ((void (*)(id,SEL,NSInteger))objc_msgSend)(p,registration,NSPasteboard.generalPasteboard.changeCount);
    } else {
        // Baseline implementation: reproduce its real one-second suppression state.
        [p setValue:@YES forKey:@"isPastingInternally"];
    }
    [p pollPasteboardOnMonitoringQueue];
    [self write:@"external-B"]; [p pollPasteboardOnMonitoringQueue];
    [self write:@"external-C"]; [p pollPasteboardOnMonitoringQueue];
    [self drain:p];
    XCTAssertEqualObjects(p.observed, (@[@"external-B", @"external-C"]));
    XCTAssertEqualObjects(p.saved, (@[@"external-B", @"external-C"]));
}
- (void)testSlowPersistenceDoesNotBlockNextObservedSnapshot {
    RCFlowProbe *p=[self probe];
    XCTestExpectation *started=[self expectationWithDescription:@"first persistence started"];
    __block BOOL first=YES;
    p.processing=^{ if (first) { first=NO; [started fulfill]; [NSThread sleepForTimeInterval:0.25]; } };
    dispatch_queue_t queue=[p valueForKey:@"monitoringQueue"];
    [self write:@"slow-A"];
    dispatch_async(queue, ^{ [p pollPasteboardOnMonitoringQueue]; });
    [self waitForExpectations:@[started] timeout:2];
    [self write:@"fast-B"];
    XCTestExpectation *observed=[self expectationWithDescription:@"second poll completed"];
    CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();
    dispatch_async(queue, ^{ [p pollPasteboardOnMonitoringQueue]; [observed fulfill]; });
    [self waitForExpectations:@[observed] timeout:2];
    NSTimeInterval elapsed=CFAbsoluteTimeGetCurrent()-start;
    NSLog(@"RC_FLOW_METRIC slow_persistence_next_poll_ms=%.3f", elapsed*1000);
    XCTAssertLessThan(elapsed, 0.15);
    [self drain:p];
    XCTAssertEqualObjects(p.saved, (@[@"slow-A", @"fast-B"]));
}
- (void)testSnapshotAcquisitionTiming {
    RCFlowProbe *p=[self probe];
    NSMutableArray<NSNumber *> *times=[NSMutableArray new];
    for (NSUInteger i=0;i<100;i++) {
        [self write:[NSString stringWithFormat:@"synthetic-%lu", (unsigned long)i]];
        CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();
        [p pollPasteboardOnMonitoringQueue];
        [times addObject:@((CFAbsoluteTimeGetCurrent()-start)*1000)];
        [self drain:p];
    }
    [times sortUsingSelector:@selector(compare:)];
    NSLog(@"RC_FLOW_METRIC n=100 acquisition_ms p50=%.3f p95=%.3f max=%.3f", times[49].doubleValue,times[94].doubleValue,times.lastObject.doubleValue);
    XCTAssertEqual(p.observed.count,100u); XCTAssertEqual(p.saved.count,100u);
}
@end
