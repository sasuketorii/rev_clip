#import <XCTest/XCTest.h>
#import "RCAppDelegate.h"
#import "RCClipboardService.h"

@interface RCAppDelegate (TerminationTesting)
- (NSApplicationTerminateReply)beginClipboardTerminationForApplication:(NSApplication *)application
                                                            clipboard:(RCClipboardService *)clipboard;
- (void)scheduleClipboardTerminationTimeout:(dispatch_block_t)timeout;
- (BOOL)clipboardMayResumeAfterCancelledTermination;
@end

// NSObject doubles deliberately avoid NSApplication/RCClipboardService init.
// No real app termination, clipboard, singleton, persistence or event posting.
@interface RCTerminationApplication : NSObject
@property(nonatomic, strong) NSMutableArray<NSNumber *> *replies;
@end
@implementation RCTerminationApplication
- (instancetype)init { self=[super init]; if (self) _replies=[NSMutableArray array]; return self; }
- (void)replyToApplicationShouldTerminate:(BOOL)reply {
    XCTAssertTrue(NSThread.isMainThread);
    [self.replies addObject:@(reply)];
}
@end

@interface RCTerminationClipboard : NSObject
@property(nonatomic) BOOL isMonitoring;
@property(nonatomic) NSUInteger stops;
@property(nonatomic) NSUInteger starts;
@property(nonatomic) BOOL completeSynchronously;
@property(nonatomic, strong) NSMutableArray *completions;
@end
@implementation RCTerminationClipboard
- (instancetype)init { self=[super init]; if (self) { _isMonitoring=YES; _completions=[NSMutableArray array]; } return self; }
- (void)stopMonitoring { XCTAssertTrue(NSThread.isMainThread); self.stops++; self.isMonitoring=NO; }
- (void)startMonitoring { XCTAssertTrue(NSThread.isMainThread); self.starts++; self.isMonitoring=YES; }
- (void)flushQueueWithCompletion:(dispatch_block_t)completion {
    XCTAssertFalse(self.isMonitoring, @"Acquisition must stop before the drain barrier");
    [self.completions addObject:[completion copy]];
    if (self.completeSynchronously) completion();
}
@end

@interface RCTerminationDelegate : RCAppDelegate
@property(nonatomic, strong) NSMutableArray *timeouts;
@property(nonatomic) BOOL mayResume;
@end
@implementation RCTerminationDelegate
- (instancetype)init { self=[super init]; if (self) { _timeouts=[NSMutableArray array]; _mayResume=YES; } return self; }
- (void)scheduleClipboardTerminationTimeout:(dispatch_block_t)timeout { [self.timeouts addObject:[timeout copy]]; }
- (BOOL)clipboardMayResumeAfterCancelledTermination { return self.mayResume; }
@end

// Keep the production timeout scheduler for the modal-loop regression. Only
// the resume policy is injected, so no panic/clipboard singleton is consulted.
@interface RCTerminationRealTimeoutDelegate : RCAppDelegate
@end
@implementation RCTerminationRealTimeoutDelegate
- (BOOL)clipboardMayResumeAfterCancelledTermination { return YES; }
@end

@interface RCAppTerminationTests : XCTestCase
@property(nonatomic, strong) RCTerminationDelegate *delegate;
@property(nonatomic, strong) RCTerminationApplication *application;
@property(nonatomic, strong) RCTerminationClipboard *clipboard;
@end
@implementation RCAppTerminationTests
- (void)setUp {
    [super setUp];
    self.delegate=[RCTerminationDelegate new];
    self.application=[RCTerminationApplication new];
    self.clipboard=[RCTerminationClipboard new];
}
- (void)tearDown {
    // Release stored callbacks so the fixture cannot retain itself through them.
    [self.clipboard.completions removeAllObjects];
    [self.delegate.timeouts removeAllObjects];
    [super tearDown];
}
- (void)onMain:(dispatch_block_t)block {
    if (NSThread.isMainThread) block(); else dispatch_sync(dispatch_get_main_queue(), block);
}
- (void)settle {
    XCTestExpectation *done=[self expectationWithDescription:@"queued termination reply"];
    dispatch_async(dispatch_get_main_queue(), ^{ [done fulfill]; });
    [self waitForExpectations:@[done] timeout:2];
}
- (void)begin {
    [self onMain:^{
        XCTAssertEqual([self.delegate beginClipboardTerminationForApplication:(id)self.application
                                                                   clipboard:(id)self.clipboard], NSTerminateLater);
    }];
}
- (void)testDrainDefersQuitAndRepliesOnMainAfterBackgroundCompletion {
    [self begin];
    XCTAssertEqual(self.clipboard.stops, 1u);
    XCTAssertEqual(self.application.replies.count, 0u);
    dispatch_block_t drained=self.clipboard.completions[0];
    XCTestExpectation *completed=[self expectationWithDescription:@"background drain"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ drained(); [completed fulfill]; });
    [self waitForExpectations:@[completed] timeout:2];
    [self settle];
    XCTAssertEqualObjects(self.application.replies, (@[@YES]));
    XCTAssertEqual(self.clipboard.starts, 0u);
    dispatch_block_t timeout=self.delegate.timeouts[0]; timeout(); [self settle];
    XCTAssertEqual(self.application.replies.count, 1u);
}
- (void)testTimeoutCancelsQuitResumesMonitoringAndIgnoresLateDrain {
    [self begin];
    dispatch_block_t timeout=self.delegate.timeouts[0]; timeout(); [self settle];
    XCTAssertEqualObjects(self.application.replies, (@[@NO]));
    XCTAssertEqual(self.clipboard.starts, 1u);
    XCTAssertTrue(self.clipboard.isMonitoring);
    dispatch_block_t drained=self.clipboard.completions[0]; drained(); [self settle];
    XCTAssertEqualObjects(self.application.replies, (@[@NO]));
    XCTAssertEqual(self.clipboard.completions.count, 1u, @"Accepted work was not cancelled");
}
- (void)testOldDrainCannotApproveNewQuitAfterTimeout {
    [self begin];
    dispatch_block_t timeout=self.delegate.timeouts[0]; timeout(); [self settle];
    [self begin];
    dispatch_block_t old=self.clipboard.completions[0]; old(); [self settle];
    XCTAssertEqualObjects(self.application.replies, (@[@NO]));
    dispatch_block_t current=self.clipboard.completions[1]; current(); [self settle];
    XCTAssertEqualObjects(self.application.replies, (@[@NO, @YES]));
}
- (void)testDuplicateQuitDoesNotStartAnotherDrain {
    [self begin]; [self begin];
    XCTAssertEqual(self.clipboard.stops, 1u);
    XCTAssertEqual(self.clipboard.completions.count, 1u);
    XCTAssertEqual(self.delegate.timeouts.count, 1u);
    dispatch_block_t drained=self.clipboard.completions[0]; drained(); drained(); [self settle];
    XCTAssertEqualObjects(self.application.replies, (@[@YES]));
}
- (void)testPreviouslyStoppedMonitoringIsNotEnabledOnTimeout {
    self.clipboard.isMonitoring=NO;
    [self begin];
    dispatch_block_t timeout=self.delegate.timeouts[0]; timeout(); [self settle];
    XCTAssertEqualObjects(self.application.replies, (@[@NO]));
    XCTAssertEqual(self.clipboard.starts, 0u);
}
- (void)testPanicStatePreventsMonitoringRestartOnTimeout {
    [self begin]; self.delegate.mayResume=NO;
    dispatch_block_t timeout=self.delegate.timeouts[0]; timeout(); [self settle];
    XCTAssertEqualObjects(self.application.replies, (@[@NO]));
    XCTAssertEqual(self.clipboard.starts, 0u);
}
- (void)testSynchronousDrainStillRepliesAfterReturn {
    self.clipboard.completeSynchronously=YES;
    [self onMain:^{
        XCTAssertEqual([self.delegate beginClipboardTerminationForApplication:(id)self.application
                                                                   clipboard:(id)self.clipboard], NSTerminateLater);
        XCTAssertEqual(self.application.replies.count, 0u);
    }];
    [self settle];
    XCTAssertEqualObjects(self.application.replies, (@[@YES]));
}
- (void)testXCTestHostLifecycleGuardNeverStartsDrainOrReplies {
    [self onMain:^{
        XCTAssertEqual([self.delegate applicationShouldTerminate:(id)self.application], NSTerminateNow);
        [self.delegate applicationWillTerminate:nil];
    }];
    XCTAssertEqual(self.delegate.timeouts.count, 0u);
    XCTAssertEqual(self.application.replies.count, 0u);
    XCTAssertEqual(self.clipboard.stops, 0u);
}
// Do not use XCTest waits inside this loop: they could service the main queue
// differently from AppKit's nested termination loop. A timer keeps the requested
// mode alive; the monotonic deadline bounds the test even on the broken product.
- (void)runNestedMode:(NSRunLoopMode)mode untilReplyOrTimeout:(NSTimeInterval)budget {
    XCTAssertTrue(NSThread.isMainThread);
    NSTimer *tick = [NSTimer timerWithTimeInterval:0.01 repeats:YES block:^(NSTimer *timer) {}];
    [NSRunLoop.mainRunLoop addTimer:tick forMode:mode];
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + budget;
    @try {
        while (!self.application.replies.count && NSProcessInfo.processInfo.systemUptime < deadline) {
            CFRunLoopRunInMode((__bridge CFStringRef)mode, 0.01, true);
        }
    } @finally { [tick invalidate]; }
}
- (void)testBackgroundDrainRepliesInsideNestedRunLoopHeldByMainDispatchBlock {
    XCTestExpectation *outerReturned = [self expectationWithDescription:@"outer main block returned"];
    dispatch_async(dispatch_get_main_queue(), ^{
        __block BOOL queuedMainBlockRan = NO;
        dispatch_async(dispatch_get_main_queue(), ^{ queuedMainBlockRan = YES; });
        XCTAssertEqual([self.delegate beginClipboardTerminationForApplication:(id)self.application
                                                                   clipboard:(id)self.clipboard], NSTerminateLater);
        XCTAssertEqual(self.application.replies.count, 0u);
        dispatch_block_t drained = self.clipboard.completions.firstObject;
        dispatch_semaphore_t submitted = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            drained();
            dispatch_semaphore_signal(submitted);
        });
        // The drain callback must enqueue a reply and return without waiting
        // for main; waiting here cannot invoke any UI or clipboard operation.
        long completed = dispatch_semaphore_wait(submitted, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
        XCTAssertEqual(completed, 0L, @"Background drain must not synchronously wait for main");
        [self runNestedMode:NSModalPanelRunLoopMode untilReplyOrTimeout:1.0];
        XCTAssertFalse(queuedMainBlockRan, @"Fixture must retain main-queue non-reentrancy");
        XCTAssertEqualObjects(self.application.replies, (@[@YES]),
                              @"Reply must arrive before the outer main dispatch block can return");
        XCTAssertEqual(self.clipboard.starts, 0u);
        [outerReturned fulfill];
    });
    [self waitForExpectations:@[outerReturned] timeout:4];
    [self settle]; // allow the baseline's stranded reply to drain before teardown
}
- (void)testProductionTimeoutRepliesInsideModalRunLoopHeldByMainDispatchBlock {
    RCTerminationRealTimeoutDelegate *delegate = [RCTerminationRealTimeoutDelegate new];
    XCTestExpectation *outerReturned = [self expectationWithDescription:@"outer modal block returned"];
    dispatch_async(dispatch_get_main_queue(), ^{
        __block BOOL queuedMainBlockRan = NO;
        dispatch_async(dispatch_get_main_queue(), ^{ queuedMainBlockRan = YES; });
        XCTAssertEqual([delegate beginClipboardTerminationForApplication:(id)self.application
                                                               clipboard:(id)self.clipboard], NSTerminateLater);
        XCTAssertEqual(self.application.replies.count, 0u);
        // Leave the synthetic drain pending. Exercise the real five-second
        // scheduler, including its run-loop mode, with a bounded test deadline.
        [self runNestedMode:NSModalPanelRunLoopMode untilReplyOrTimeout:6.5];
        XCTAssertFalse(queuedMainBlockRan, @"Modal reply must not rely on dispatch-main reentrancy");
        XCTAssertEqualObjects(self.application.replies, (@[@NO]),
                              @"Timeout must cancel while the modal termination loop is still running");
        XCTAssertEqual(self.clipboard.starts, 1u);
        [outerReturned fulfill];
    });
    [self waitForExpectations:@[outerReturned] timeout:9];
    [self settle];
}
@end
