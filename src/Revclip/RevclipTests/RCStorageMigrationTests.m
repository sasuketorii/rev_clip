#import <XCTest/XCTest.h>
#import "RCStorageMigration.h"
#import "RCStorageCipherTestAccess.h"
#import "RCDatabaseManager.h"
#import "FMDB.h"
#import "RCDataCleanService.h"
#import "RCUtilities.h"
#import "RCClipData.h"
#import "RCPanicEraseService.h"
#import <sqlite3.h>
#import <unistd.h>
@interface RCDatabaseManager (StorageTesting)
- (instancetype)initPrivate;
@end
@interface RCDataCleanService (StorageTesting)
- (void)removeOrphanClipFilesWithDatabaseManager:(RCDatabaseManager *)manager;
@end
@interface RCUnreadableHistoryDatabase : RCDatabaseManager
@end
@implementation RCUnreadableHistoryDatabase
- (BOOL)performDatabaseOperation:(BOOL (^)(FMDatabase *))operation { return NO; }
@end
@interface RCStorageMigrationTests : XCTestCase
@property NSString *directory;
@property NSString *path;
@end
@implementation RCStorageMigrationTests
- (void)setUp {
    self.directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([RCStorageMigration validatePrivateDirectory:self.directory create:YES]);
    self.path = [self.directory stringByAppendingPathComponent:@"revclip.db"];
}
- (void)tearDown { [[NSFileManager defaultManager] removeItemAtPath:self.directory error:nil]; }
- (void)testLegacyDatabaseAndClipMigrateWithoutLosingContentAndRejectUnkeyedRead {
    sqlite3 *plain = NULL;
    XCTAssertEqual(sqlite3_open(self.path.fileSystemRepresentation, &plain), SQLITE_OK);
    XCTAssertEqual(sqlite3_exec(plain, "CREATE TABLE snippets (id INTEGER PRIMARY KEY, content TEXT); INSERT INTO snippets VALUES(1, 'private-fixture-content'); PRAGMA user_version=7;", NULL, NULL, NULL), SQLITE_OK);
    sqlite3_close(plain);
    NSString *clips = [self.directory stringByAppendingPathComponent:@"ClipsData"];
    XCTAssertTrue([RCStorageMigration validatePrivateDirectory:clips create:YES]);
    NSString *file = [clips stringByAppendingPathComponent:@"fixture.rcclip"];
    RCClipData *clip = [RCClipData new];
    clip.stringValue = @"private-clip-fixture";
    NSData *payload = [NSKeyedArchiver archivedDataWithRootObject:clip requiringSecureCoding:YES error:nil];
    XCTAssertTrue([payload writeToFile:file atomically:YES]);
    NSError *error = nil;
    XCTAssertTrue([RCStorageMigration prepareDatabaseAtPath:self.path error:&error], @"%@", error);
    XCTAssertTrue([RCStorageMigration migrateClipFilesBesideDatabase:self.path error:&error], @"%@", error);
    XCTAssertEqualObjects([[RCStorageCipher shared] readDataAtPath:file allowPlaintext:NO error:&error], payload);
    NSData *disk = [NSData dataWithContentsOfFile:self.path];
    XCTAssertEqual([disk rangeOfData:[@"private-fixture-content" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0,disk.length)].location, NSNotFound);
    sqlite3 *encrypted = NULL;
    XCTAssertEqual(sqlite3_open(self.path.fileSystemRepresentation, &encrypted), SQLITE_OK);
    XCTAssertNotEqual(sqlite3_exec(encrypted, "SELECT * FROM snippets", NULL, NULL, NULL), SQLITE_OK);
    sqlite3_close(encrypted);
    XCTAssertEqual(sqlite3_open(self.path.fileSystemRepresentation, &encrypted), SQLITE_OK);
    NSData *key = [[RCStorageCipher shared] databaseKeyWithError:&error];
    XCTAssertEqual(sqlite3_key(encrypted, key.bytes, (int)key.length), SQLITE_OK);
    sqlite3_stmt *query = NULL;
    XCTAssertEqual(sqlite3_prepare_v2(encrypted, "SELECT content FROM snippets WHERE id=1", -1, &query, NULL), SQLITE_OK);
    XCTAssertEqual(sqlite3_step(query), SQLITE_ROW);
    XCTAssertEqualObjects([NSString stringWithUTF8String:(const char *)sqlite3_column_text(query,0)], @"private-fixture-content");
    sqlite3_finalize(query);
    XCTAssertEqual(sqlite3_prepare_v2(encrypted, "PRAGMA user_version", -1, &query, NULL), SQLITE_OK);
    XCTAssertEqual(sqlite3_step(query), SQLITE_ROW);
    XCTAssertEqual(sqlite3_column_int(query,0), 7);
    sqlite3_finalize(query); sqlite3_close(encrypted);
    // Restart after migration must neither re-encrypt nor discard content.
    XCTAssertTrue([RCStorageMigration prepareDatabaseAtPath:self.path error:&error]);
    XCTAssertTrue([RCStorageMigration migrateClipFilesBesideDatabase:self.path error:&error]);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:self.path], disk);
}
- (void)testCorruptLegacyDatabaseRemainsUntouched {
    NSMutableData *invalid = [NSMutableData dataWithBytes:"SQLite format 3\0" length:16];
    [invalid increaseLengthBy:4096];
    XCTAssertTrue([invalid writeToFile:self.path atomically:YES]);
    XCTAssertFalse([RCStorageMigration prepareDatabaseAtPath:self.path error:nil]);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:self.path], invalid);
}
- (void)testSymlinkDatabaseAndSidecarsAreRejected {
    NSString *target = [self.directory stringByAppendingPathComponent:@"target"];
    NSData *original = [@"unchanged" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([original writeToFile:target atomically:YES]);
    XCTAssertEqual(symlink(target.fileSystemRepresentation,self.path.fileSystemRepresentation),0);
    XCTAssertFalse([RCStorageMigration prepareDatabaseAtPath:self.path error:nil]);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:target],original);
    unlink(self.path.fileSystemRepresentation);
    XCTAssertEqual(symlink(target.fileSystemRepresentation,[self.path stringByAppendingString:@"-wal"].fileSystemRepresentation),0);
    XCTAssertFalse([RCStorageMigration prepareDatabaseAtPath:self.path error:nil]);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:target],original);
}
- (void)testNewManagerWritesEncryptedDatabaseAndReopens {
    RCDatabaseManager *manager = [[RCDatabaseManager alloc] initPrivate];
    [manager setValue:self.path forKey:@"databasePath"];
    XCTAssertTrue([manager setupDatabase]);
    XCTAssertTrue(([manager insertSnippetFolder:@{@"identifier":@"folder", @"title":@"sensitive-folder-title"}]));
    [manager closeDatabase];
    XCTAssertTrue([manager setupDatabase]);
    XCTAssertEqualObjects([manager fetchSnippetCatalog].firstObject[@"title"], @"sensitive-folder-title");
    [manager closeDatabase];
    sqlite3 *db = NULL;
    XCTAssertEqual(sqlite3_open(self.path.fileSystemRepresentation,&db), SQLITE_OK);
    XCTAssertNotEqual(sqlite3_exec(db,"SELECT * FROM snippet_folders",NULL,NULL,NULL),SQLITE_OK);
    sqlite3_close(db);
}
- (void)testFailedHistoryReadDoesNotDeleteOrphanCandidates {
    NSString *file = [[RCUtilities clipDataDirectoryPath] stringByAppendingPathComponent:
        [NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"rcclip"]];
    XCTAssertTrue([[@"fixture" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:file atomically:YES]);
    [[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate:[NSDate dateWithTimeIntervalSinceNow:-3600]} ofItemAtPath:file error:nil];
    RCUnreadableHistoryDatabase *database = [[RCUnreadableHistoryDatabase alloc] initPrivate];
    [[RCDataCleanService shared] removeOrphanClipFilesWithDatabaseManager:database];
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:file]);
    [[NSFileManager defaultManager] removeItemAtPath:file error:nil];
}
- (void)testOrphanSidecarNeverCreatesAnEmptyDatabase {
    NSString *wal = [self.path stringByAppendingString:@"-wal"];
    NSData *original = [@"orphaned encrypted WAL fixture" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([original writeToFile:wal atomically:YES]);
    XCTAssertFalse([RCStorageMigration prepareDatabaseAtPath:self.path error:nil]);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:self.path]);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:wal],original);
}
- (void)testInterruptedMigrationArtifactsAreRemovedOnlyAfterDatabaseOpens {
    NSString *stage = [self.directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@".encrypted-%@.db", NSUUID.UUID.UUIDString]];
    RCDatabaseManager *manager = [[RCDatabaseManager alloc] initPrivate];
    [manager setValue:self.path forKey:@"databasePath"];
    XCTAssertTrue([manager setupDatabase]);
    [manager closeDatabase];
    XCTAssertTrue([[RCStorageCipher shared] writeData:[@"stage fixture" dataUsingEncoding:NSUTF8StringEncoding] toPath:stage error:nil]);
    XCTAssertTrue([manager setupDatabase]);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:stage]);
    [manager closeDatabase];
    NSString *outside = [self.directory stringByAppendingPathComponent:@"preserve"];
    NSData *original = [@"keep" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([original writeToFile:outside atomically:YES]);
    XCTAssertEqual(symlink(outside.fileSystemRepresentation,stage.fileSystemRepresentation),0);
    XCTAssertFalse([RCStorageMigration prepareDatabaseAtPath:self.path error:nil]);
    XCTAssertFalse([RCStorageMigration removeMigrationArtifactsBesideDatabase:self.path error:nil]);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:outside],original);
}
- (void)testSetupCannotRecreateStorageDuringPanic {
    // Only toggle the isolated test process's barrier; never execute real erase.
    RCPanicEraseService *panic = [RCPanicEraseService shared];
    BOOL previous = panic.isPanicInProgress;
    @try {
        [panic setValue:@YES forKey:@"isPanicInProgress"];
        RCDatabaseManager *manager = [[RCDatabaseManager alloc] initPrivate];
        [manager setValue:self.path forKey:@"databasePath"];
        XCTAssertFalse([manager setupDatabase]);
        XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:self.path]);
    } @finally { [panic setValue:@(previous) forKey:@"isPanicInProgress"]; }
}
- (void)testCorruptClipHeaderIsNotReencryptedAsPlaintext {
    NSString *clips = [self.directory stringByAppendingPathComponent:@"ClipsData"];
    XCTAssertTrue([RCStorageMigration validatePrivateDirectory:clips create:YES]);
    NSString *file = [clips stringByAppendingPathComponent:@"fixture.rcclip"];
    XCTAssertTrue([[RCStorageCipher shared] writeData:[@"fixture" dataUsingEncoding:NSUTF8StringEncoding] toPath:file error:nil]);
    NSMutableData *damaged = [[NSData dataWithContentsOfFile:file] mutableCopy];
    ((unsigned char *)damaged.mutableBytes)[0] ^= 1;
    XCTAssertTrue([damaged writeToFile:file atomically:YES]);
    XCTAssertFalse([RCStorageMigration migrateClipFilesBesideDatabase:self.path error:nil]);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:file],damaged);
    XCTAssertFalse([RCStorageMigration prepareDatabaseAtPath:self.path error:nil]);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:self.path]);
}
@end
