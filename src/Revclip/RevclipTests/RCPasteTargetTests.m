#import <XCTest/XCTest.h>
#import "RCPasteService.h"
@interface RCPasteService (TargetTesting)
- (void)sendPasteKeyStrokeWhenApplicationIsReady:(NSRunningApplication *)app timeoutAt:(CFAbsoluteTime)time pasteGeneration:(NSUInteger)generation;
@end
@interface RCPasteProbe : RCPasteService
@property NSUInteger sent;
@end
@implementation RCPasteProbe
- (void)sendPasteKeyStroke { self.sent++; }
@end
@interface RCTargetProbe : NSObject
@property(getter=isActive) BOOL active;
@property(getter=isTerminated) BOOL terminated;
@end
@implementation RCTargetProbe
@end
@interface RCPasteTargetTests : XCTestCase
@end
@implementation RCPasteTargetTests
- (void)testMissingTerminatedInactiveAndSupersededTargetsNeverSendKeys {
    RCPasteProbe *service = [RCPasteProbe new]; RCTargetProbe *target = [RCTargetProbe new];
    [service sendPasteKeyStrokeWhenApplicationIsReady:nil timeoutAt:0 pasteGeneration:0];
    [service sendPasteKeyStrokeWhenApplicationIsReady:(id)target timeoutAt:0 pasteGeneration:0];
    target.terminated=YES; target.active=YES;
    [service sendPasteKeyStrokeWhenApplicationIsReady:(id)target timeoutAt:0 pasteGeneration:0];
    target.terminated=NO;
    [service sendPasteKeyStrokeWhenApplicationIsReady:(id)target timeoutAt:0 pasteGeneration:1];
    XCTAssertEqual(service.sent,0);
    [service sendPasteKeyStrokeWhenApplicationIsReady:(id)target timeoutAt:0 pasteGeneration:0];
    XCTAssertEqual(service.sent,1);
}
@end
