#import <XCTest/XCTest.h>
#import "RCClipboardService.h"
#import "RCClipData.h"
#import "RCPrivacyService.h"
#import "RCDatabaseManager.h"
#import "RCUtilities.h"
#import "RCConstants.h"
#import "RCExcludeAppService.h"
#import "RCPanicEraseService.h"

@interface RCClipboardService (OCRTests)
- (void)pollPasteboardOnMonitoringQueue;
- (RCClipData *)readEligibleClipFromPasteboard:(NSPasteboard *)board sourceBundleIdentifier:(NSString *)source;
- (BOOL)saveClipData:(RCClipData *)clip toPath:(NSString *)path;
@end
@interface RCOCRPrivacy : RCPrivacyService
@property RCClipboardAccessState state;
@end
@implementation RCOCRPrivacy
- (RCClipboardAccessState)clipboardAccessState { return self.state; }
@end
@interface RCOCRFailingStorage : RCClipboardService
@end
@implementation RCOCRFailingStorage
- (BOOL)saveClipData:(RCClipData *)clip toPath:(NSString *)path { return NO; }
@end

@interface RCOCRCommitTests : XCTestCase
@property RCClipboardService *service;
@property RCOCRPrivacy *privacy;
@property NSMutableArray<NSString *> *hashes;
@end
@implementation RCOCRCommitTests
- (void)setUp {
    [super setUp];
    XCTAssertTrue([[RCUtilities applicationSupportPath].lastPathComponent hasPrefix:@"RevclipTests-storage-"]);
    self.hashes = NSMutableArray.new;
    self.service = RCClipboardService.new;
    self.privacy = RCOCRPrivacy.new; self.privacy.state = RCClipboardAccessStateGranted;
    [self.service setValue:self.privacy forKey:@"privacyService"];
    // Admit without a polling timer so only the explicitly requested operation runs.
    [self.service setValue:@YES forKey:@"isMonitoring"];
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"RCOCREnabled"];
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"RCOCRSaveHistory"];
    [NSUserDefaults.standardUserDefaults setObject:@{@"String":@YES} forKey:kRCPrefStoreTypesKey];
    [RCExcludeAppService.shared setExcludedBundleIdentifiers:@[]];
    XCTAssertTrue([RCDatabaseManager.shared setupDatabase]);
}
- (void)drain {
    XCTestExpectation *done = [self expectationWithDescription:@"drain"];
    [self.service flushQueueWithCompletion:^{ [done fulfill]; }];
    [self waitForExpectations:@[done] timeout:5];
}
- (void)tearDown {
    [self.service stopMonitoring]; [self drain];
    for (NSString *hash in self.hashes) {
        NSDictionary *row = [RCDatabaseManager.shared clipItemWithDataHash:hash];
        [RCDatabaseManager.shared deleteClipItemWithDataHash:hash];
        NSString *path = row[@"data_path"];
        if (path) [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    }
    [RCExcludeAppService.shared setExcludedBundleIdentifiers:@[]];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"RCOCREnabled"];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"RCOCRSaveHistory"];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kRCPrefStoreTypesKey];
    [super tearDown];
}
- (NSString *)fixture {
    NSString *value = [@"RevOCR synthetic 日本語 " stringByAppendingString:NSUUID.UUID.UUIDString];
    RCClipData *clip = RCClipData.new; clip.stringValue = value; clip.primaryType = NSPasteboardTypeString;
    [self.hashes addObject:clip.dataHash]; return value;
}
- (void)write:(NSString *)text {
    [NSPasteboard.generalPasteboard clearContents];
    XCTAssertTrue([NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString]);
}
- (RCOCRCommitContext *)begin:(BOOL)save { return [self.service beginOCRFromApplication:@"org.revclip.synthetic" saveToHistory:save]; }
- (RCOCRCommitResult)commit:(NSString *)text context:(RCOCRCommitContext *)context {
    XCTestExpectation *done = [self expectationWithDescription:@"commit"];
    __block RCOCRCommitResult result = RCOCRCommitResultCancelled;
    [self.service commitRecognizedText:text context:context completion:^(RCOCRCommitResult value) {
        XCTAssertTrue(NSThread.isMainThread); result = value; [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:5]; return result;
}
- (void)testCopyAndHistoryAcceptExactlyOnceAndNeverRereadLaterBoard {
    NSString *text = [self fixture]; RCOCRCommitContext *ticket = [self begin:YES];
    dispatch_queue_t persistence = [self.service valueForKey:@"persistenceQueue"];
    dispatch_suspend(persistence);
    XCTestExpectation *done = [self expectationWithDescription:@"saved snapshot"];
    [self.service commitRecognizedText:text context:ticket completion:^(RCOCRCommitResult result) {
        XCTAssertEqual(result,RCOCRCommitResultHistoryStored); [done fulfill];
    }];
    XCTAssertEqualObjects([NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString],text);
    NSInteger copied = NSPasteboard.generalPasteboard.changeCount;
    XCTAssertEqual([self commit:text context:ticket],RCOCRCommitResultCancelled);
    XCTAssertEqual(NSPasteboard.generalPasteboard.changeCount,copied);
    [self write:@"a later external copy"];
    dispatch_resume(persistence);
    [self waitForExpectations:@[done] timeout:5];
    NSDictionary *row = [RCDatabaseManager.shared clipItemWithDataHash:self.hashes.lastObject];
    XCTAssertEqualObjects([RCClipData clipDataFromPath:row[@"data_path"]].stringValue,text);
    XCTAssertEqualObjects([NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString],@"a later external copy");
}
- (void)testOCRReplacesRichClipboardWithUnformattedTextOnly {
    NSPasteboard *board = NSPasteboard.generalPasteboard;
    [board clearContents];
    XCTAssertTrue([board setString:@"<p style='text-align:center'>old</p>" forType:NSPasteboardTypeHTML]);
    NSString *text = @"日本語の本文\nSecond line";
    XCTAssertEqual([self commit:text context:[self begin:NO]], RCOCRCommitResultHistorySkipped);
    XCTAssertEqualObjects([board stringForType:NSPasteboardTypeString], text);
    // AppKit also advertises the legacy NSStringPboardType alias on this OS.
    NSSet *allowedTypes = [NSSet setWithArray:@[NSPasteboardTypeString, @"NSStringPboardType", @"org.nspasteboard.TransientType"]];
    XCTAssertTrue([[NSSet setWithArray:board.types] isSubsetOfSet:allowedTypes]);
    XCTAssertTrue([board.types containsObject:NSPasteboardTypeString]);
    XCTAssertNil([board dataForType:NSPasteboardTypeHTML]);
    XCTAssertNil([board dataForType:NSPasteboardTypeRTF]);
}
- (void)testSameContentRecopySupersedesOCRByGeneration {
    [self write:@"same"];
    RCOCRCommitContext *ticket = [self begin:YES];
    [self write:@"same"];
    NSInteger generation = NSPasteboard.generalPasteboard.changeCount;
    XCTAssertEqual([self commit:[self fixture] context:ticket],RCOCRCommitResultClipboardChanged);
    XCTAssertEqual(NSPasteboard.generalPasteboard.changeCount,generation);
    XCTAssertNil([RCDatabaseManager.shared clipItemWithDataHash:self.hashes.lastObject]);
}
- (void)testCopyOnlyAndDeniedHistoryUseTransientMarkerAcrossNewService {
    for (NSNumber *state in @[@(RCClipboardAccessStateGranted),@(RCClipboardAccessStateDenied),@(RCClipboardAccessStateUnknown),@(RCClipboardAccessStateNotDetermined)]) {
        self.privacy.state = state.integerValue;
        NSString *text = [self fixture];
        BOOL intent = self.privacy.state != RCClipboardAccessStateGranted;
        XCTAssertEqual([self commit:text context:[self begin:intent]],RCOCRCommitResultHistorySkipped);
        XCTAssertTrue([NSPasteboard.generalPasteboard.types containsObject:@"org.nspasteboard.TransientType"]);
        XCTAssertEqualObjects([NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString],text);
        RCClipboardService *fresh = RCClipboardService.new;
        XCTAssertNil([fresh readEligibleClipFromPasteboard:NSPasteboard.generalPasteboard sourceBundleIdentifier:@"org.revclip.synthetic"]);
        XCTAssertNil([RCDatabaseManager.shared clipItemWithDataHash:self.hashes.lastObject]);
    }
}
- (void)testCancellationLifecyclePanicAndDisableRejectLateCommit {
    for (NSString *kind in @[@"cancel",@"stop-restart",@"panic",@"disable",@"exclude"]) {
        [self.service setValue:@NO forKey:@"captureSuspended"]; [self.service setValue:@YES forKey:@"isMonitoring"];
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"RCOCREnabled"];
        RCOCRCommitContext *ticket = [self begin:YES]; XCTAssertNotNil(ticket);
        if ([kind isEqual:@"cancel"]) [self.service cancelOCRContext:ticket];
        if ([kind isEqual:@"stop-restart"]) { [self.service stopMonitoring]; [self.service setValue:@NO forKey:@"captureSuspended"]; [self.service setValue:@YES forKey:@"isMonitoring"]; }
        if ([kind isEqual:@"panic"]) [RCPanicEraseService.shared setValue:@YES forKey:@"isPanicInProgress"];
        if ([kind isEqual:@"disable"]) [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"RCOCREnabled"];
        if ([kind isEqual:@"exclude"]) [RCExcludeAppService.shared addExcludedBundleIdentifier:@"org.revclip.synthetic"];
        NSInteger before = NSPasteboard.generalPasteboard.changeCount;
        XCTAssertEqual([self commit:[self fixture] context:ticket],RCOCRCommitResultCancelled);
        XCTAssertEqual(NSPasteboard.generalPasteboard.changeCount,before);
        [RCPanicEraseService.shared setValue:@NO forKey:@"isPanicInProgress"];
        [RCExcludeAppService.shared setExcludedBundleIdentifiers:@[]];
    }
}
- (void)testSaveIntentCannotExpandAndPolicyCanTighten {
    RCOCRCommitContext *latched = [self begin:YES];
    [self.service disableHistoryForOCRContext:latched];
    XCTAssertEqual([self commit:[self fixture] context:latched],RCOCRCommitResultHistorySkipped);
    RCOCRCommitContext *ticket = [self begin:NO];
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"RCOCRSaveHistory"];
    XCTAssertEqual([self commit:[self fixture] context:ticket],RCOCRCommitResultHistorySkipped);
    ticket = [self begin:YES];
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"RCOCRSaveHistory"];
    XCTAssertEqual([self commit:[self fixture] context:ticket],RCOCRCommitResultHistorySkipped);
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"RCOCRSaveHistory"];
    ticket = [self begin:YES];
    [NSUserDefaults.standardUserDefaults setObject:@{@"String":@NO} forKey:kRCPrefStoreTypesKey];
    XCTAssertEqual([self commit:[self fixture] context:ticket],RCOCRCommitResultHistorySkipped);
}
- (void)testFailedPersistenceIsPartialSuccessAndClearDrainContainsAdmission {
    self.service = RCOCRFailingStorage.new;
    [self.service setValue:self.privacy forKey:@"privacyService"]; [self.service setValue:@YES forKey:@"isMonitoring"];
    NSString *text = [self fixture];
    XCTAssertEqual([self commit:text context:[self begin:YES]],RCOCRCommitResultHistoryFailed);
    XCTAssertEqualObjects([NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString],text);
    XCTAssertNil([RCDatabaseManager.shared clipItemWithDataHash:self.hashes.lastObject]);
}
- (void)testClearDrainOrdersAfterAcceptedSaveAndLateContextCannotResurrect {
    NSString *text = [self fixture];
    RCOCRCommitContext *late = [self begin:YES];
    XCTestExpectation *saved = [self expectationWithDescription:@"saved"];
    [self.service commitRecognizedText:text context:[self begin:YES] completion:^(RCOCRCommitResult result) { XCTAssertEqual(result,RCOCRCommitResultHistoryStored); [saved fulfill]; }];
    [self.service stopMonitoring];
    XCTestExpectation *drained = [self expectationWithDescription:@"cleared after drain"];
    [self.service flushQueueWithCompletion:^{
        XCTAssertNotNil([RCDatabaseManager.shared clipItemWithDataHash:self.hashes.lastObject]);
        [RCDatabaseManager.shared deleteClipItemWithDataHash:self.hashes.lastObject];
        [drained fulfill];
    }];
    [self waitForExpectations:@[saved,drained] timeout:5];
    NSInteger before = NSPasteboard.generalPasteboard.changeCount;
    XCTAssertEqual([self commit:text context:late],RCOCRCommitResultCancelled);
    XCTAssertEqual(NSPasteboard.generalPasteboard.changeCount,before);
    XCTAssertNil([RCDatabaseManager.shared clipItemWithDataHash:self.hashes.lastObject]);
}
- (void)testInvalidOutputsNeverClearClipboard {
    for (NSString *text in @[@"",@" \n\t",[@"x" stringByPaddingToLength:1024*1024+1 withString:@"x" startingAtIndex:0]]) {
        NSInteger before = NSPasteboard.generalPasteboard.changeCount;
        XCTAssertEqual([self commit:text context:[self begin:YES]],RCOCRCommitResultCancelled);
        XCTAssertEqual(NSPasteboard.generalPasteboard.changeCount,before);
    }
    XCTAssertNil([self.service beginOCRFromApplication:@"" saveToHistory:YES]);
}
@end
