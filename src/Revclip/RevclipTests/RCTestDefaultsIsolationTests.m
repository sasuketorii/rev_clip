//
//  RCTestDefaultsIsolationTests.m
//  RevclipTests
//
//  The in-memory standard defaults installed by RCStorageTestEnvironment must
//  survive a system framework adding one of its own suites (HIToolbox's
//  IMKClient did this during a preferences test and the host aborted) while
//  still answering every read from memory only.
//

#import <XCTest/XCTest.h>

@interface RCTestDefaultsIsolationTests : XCTestCase
@end

@implementation RCTestDefaultsIsolationTests
- (void)testSystemSuiteFromInputMethodClientIsIgnoredWithoutBreakingIsolation {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    XCTAssertEqualObjects(NSStringFromClass(defaults.class), @"RCMemoryTestDefaults");
    NSString *key = [@"RevclipTests.IsolationSuiteProbe." stringByAppendingString:NSUUID.UUID.UUIDString];
    [defaults setObject:@"synthetic" forKey:key];
    NSDictionary *before = [defaults persistentDomainForName:NSBundle.mainBundle.bundleIdentifier];

    [defaults addSuiteNamed:@"com.apple.inputmethod.SyntheticIME"]; // must not abort
    [defaults removeSuiteNamed:@"com.apple.inputmethod.SyntheticIME"];

    XCTAssertEqual(NSUserDefaults.standardUserDefaults, defaults, @"Still the isolated instance");
    XCTAssertEqualObjects([defaults objectForKey:key], @"synthetic");
    XCTAssertEqualObjects([defaults persistentDomainForName:NSBundle.mainBundle.bundleIdentifier], before);
    XCTAssertFalse([defaults.persistentDomainNames containsObject:@"com.apple.inputmethod.SyntheticIME"],
                   @"A system suite never becomes a domain of the isolated store");
    [defaults removeObjectForKey:key];
}
@end
