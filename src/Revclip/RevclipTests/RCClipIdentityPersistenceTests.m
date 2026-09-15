#import <XCTest/XCTest.h>
#import <AppKit/AppKit.h>
#import <stdlib.h>
#import "RCClipData.h"
#import "RCClipboardService.h"
#import "RCDatabaseManager.h"
#import "RCDataCleanService.h"
#import "RCUtilities.h"

@interface RCClipboardService (IdentityPersistenceTesting)
- (void)processClipDataOnMonitoringQueue:(RCClipData *)clip sourceBundleIdentifier:(NSString *)source;
@end

@interface RCIdentityPersistenceProbe : RCClipboardService
@end
@implementation RCIdentityPersistenceProbe
// Exercise the real persistence path without reading any pasteboard, even at init.
- (NSInteger)readGeneralPasteboardChangeCount { return 0; }
- (BOOL)shouldStoreClipData:(RCClipData *)clip { return YES; }
- (BOOL)boolPreferenceForKey:(NSString *)key defaultValue:(BOOL)value { return YES; }
@end

@interface RCClipIdentityPersistenceTests : XCTestCase
@property (nonatomic, strong) RCDatabaseManager *db;
@property (nonatomic, strong) RCIdentityPersistenceProbe *probe;
@property (nonatomic, strong) NSMutableSet<NSString *> *fixtureHashes;
@property (nonatomic, strong) NSMutableSet<NSString *> *fixturePaths;
@end

@implementation RCClipIdentityPersistenceTests
- (void)setUp {
    [super setUp];
    // RCStorageTestEnvironment supplies a temporary database and ephemeral key.
    // Abort before touching a manager if the isolation constructor is absent.
    if (![[RCUtilities applicationSupportPath].lastPathComponent hasPrefix:@"RevclipTests-storage-"]) abort();
    self.fixtureHashes = [NSMutableSet set];
    self.fixturePaths = [NSMutableSet set];
    self.db = RCDatabaseManager.shared;
    XCTAssertTrue([self.db setupDatabase]);
    self.probe = [RCIdentityPersistenceProbe new];
}

- (void)tearDown {
    [self.probe stopMonitoring];
    RCDataCleanService *cleaner = RCDataCleanService.shared;
    dispatch_sync([cleaner valueForKey:@"cleanupQueue"], ^{ [cleaner stopCleanupTimer]; });
    for (NSString *hash in self.fixtureHashes) {
        NSDictionary *row = [self.db clipItemWithDataHash:hash];
        for (NSString *key in @[@"data_path", @"thumbnail_path"]) {
            NSString *path = row[key];
            if (path.length) [self.fixturePaths addObject:path];
        }
        [self.db deleteClipItemWithDataHash:hash];
    }
    for (NSString *path in self.fixturePaths) {
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    }
    XCTestExpectation *drained = [self expectationWithDescription:@"fixture notifications drained"];
    dispatch_async(dispatch_get_main_queue(), ^{ [drained fulfill]; });
    [self waitForExpectations:@[drained] timeout:2];
    [super tearDown];
}

- (RCClipData *)fixture {
    RCClipData *clip = [RCClipData new];
    clip.stringValue = [@"identity fixture " stringByAppendingString:NSUUID.UUID.UUIDString];
    clip.primaryType = NSPasteboardTypeString;
    clip.RTFData = [@"{\\rtf1 synthetic}" dataUsingEncoding:NSUTF8StringEncoding];
    return clip;
}

- (NSDictionary *)seedLegacy:(RCClipData *)clip {
    NSString *directory = [RCUtilities clipDataDirectoryPath];
    XCTAssertTrue([RCUtilities ensureDirectoryExists:directory]);
    NSString *path = [directory stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".rcclip"]];
    [self.fixturePaths addObject:path];
    [self.fixtureHashes addObject:clip.legacyDataHash];
    XCTAssertTrue([clip saveToPath:path]);
    NSDictionary *row = @{@"data_path": path, @"data_hash": clip.legacyDataHash,
        @"primary_type": clip.primaryType, @"title": clip.title, @"update_time": @1};
    XCTAssertTrue([self.db insertClipItem:row]);
    return [self.db clipItemWithDataHash:clip.legacyDataHash];
}

- (void)persist:(RCClipData *)clip {
    [self.fixtureHashes addObject:clip.dataHash];
    dispatch_sync([self.probe valueForKey:@"persistenceQueue"], ^{
        [self.probe processClipDataOnMonitoringQueue:clip sourceBundleIdentifier:@"org.revclip.tests.identity"];
    });
    RCDataCleanService *cleaner = RCDataCleanService.shared;
    dispatch_sync([cleaner valueForKey:@"cleanupQueue"], ^{ [cleaner stopCleanupTimer]; });
}

- (void)testExactLegacyPayloadReusesOriginalRowWithoutMigration {
    RCClipData *original = [self fixture];
    NSDictionary *before = [self seedLegacy:original];
    NSInteger count = self.db.clipItemCount;
    NSData *archiveBefore = [NSData dataWithContentsOfFile:before[@"data_path"]];
    RCClipData *incoming = [RCClipData clipDataFromPath:before[@"data_path"]];
    XCTAssertNotNil(incoming);
    if (!incoming) return;
    [self persist:incoming];
    NSDictionary *after = [self.db clipItemWithDataHash:original.legacyDataHash];
    XCTAssertEqual(self.db.clipItemCount, count);
    XCTAssertEqualObjects(after[@"id"], before[@"id"]);
    XCTAssertEqualObjects(after[@"data_path"], before[@"data_path"]);
    XCTAssertEqualObjects(after[@"data_hash"], original.legacyDataHash);
    XCTAssertGreaterThan([after[@"update_time"] longLongValue], 1LL);
    XCTAssertNil([self.db clipItemWithDataHash:incoming.dataHash]);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:after[@"data_path"]], archiveBefore);
}

- (void)testLegacyFormatCollisionInsertsNewPayloadAndPreservesOriginal {
    RCClipData *original = [self fixture];
    NSDictionary *before = [self seedLegacy:original];
    NSInteger count = self.db.clipItemCount;
    NSData *archiveBefore = [NSData dataWithContentsOfFile:before[@"data_path"]];
    RCClipData *incoming = [RCClipData new];
    incoming.stringValue = original.stringValue;
    incoming.primaryType = original.primaryType;
    // Synthetic cross-flavor bytes reproduce the old identity ambiguity.
    incoming.RTFDData = original.RTFData;
    XCTAssertEqualObjects(incoming.legacyDataHash, original.legacyDataHash);
    XCTAssertNotEqualObjects(incoming.dataHash, original.dataHash);
    [self persist:incoming];
    NSDictionary *retained = [self.db clipItemWithDataHash:original.legacyDataHash];
    NSDictionary *inserted = [self.db clipItemWithDataHash:incoming.dataHash];
    XCTAssertEqual(self.db.clipItemCount, count + 1);
    XCTAssertNotNil(inserted);
    XCTAssertEqualObjects(retained, before);
    XCTAssertNotEqualObjects(inserted[@"data_path"], before[@"data_path"]);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:before[@"data_path"]], archiveBefore);
    RCClipData *oldPayload = [RCClipData clipDataFromPath:retained[@"data_path"]];
    RCClipData *newPayload = inserted ? [RCClipData clipDataFromPath:inserted[@"data_path"]] : nil;
    XCTAssertTrue([original hasSamePayloadAsClipData:oldPayload]);
    XCTAssertTrue([incoming hasSamePayloadAsClipData:newPayload]);
    // A subsequent new-version lookup reuses the second row.
    [self persist:incoming];
    XCTAssertEqual(self.db.clipItemCount, count + 1);
    XCTAssertEqualObjects([self.db clipItemWithDataHash:incoming.dataHash][@"id"], inserted[@"id"]);
}
@end
