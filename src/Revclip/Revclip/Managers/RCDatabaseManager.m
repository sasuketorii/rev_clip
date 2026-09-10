//
//  RCDatabaseManager.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import "RCDatabaseManager.h"

#import "FMDB.h"
#import "RCClipItem.h"
#import "RCPanicEraseService.h"
#import "RCUtilities.h"
#import <os/log.h>
#import <sqlite3.h>

static NSInteger const kRCCurrentSchemaVersion = 2;
static NSNumber * const kRCDatabaseFilePermissions = @(0600);
static NSNumber * const kRCDatabaseDirectoryPermissions = @(0700);
static NSString * const kRCAutoVacuumMigrationCompletedKey = @"kRCAutoVacuumMigrationCompletedKey";

static os_log_t RCDatabaseManagerLog(void) {
    static os_log_t logger = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        logger = os_log_create("com.revclip", "RCDatabaseManager");
    });
    return logger;
}

@interface RCDatabaseManager ()

@property (nonatomic, strong, nullable) FMDatabaseQueue *databaseQueue;
@property (nonatomic, readwrite, copy) NSString *databasePath;
@property (nonatomic, assign) BOOL setupCompleted;
@property (nonatomic, assign) BOOL databaseCreatedDuringCurrentSetup;

- (BOOL)enableSecureDeleteForDatabase:(FMDatabase *)db;
- (BOOL)configureIncrementalAutoVacuumForNewDatabase:(FMDatabase *)db;
- (NSInteger)integerValueForPragma:(NSString *)pragmaName
                        inDatabase:(FMDatabase *)db
                      defaultValue:(NSInteger)defaultValue;
- (void)migrateAutoVacuumToIncrementalIfNeeded;
- (void)applyDatabaseFilePermissionsIfNeeded;
- (NSString *)storagePathForClipPath:(NSString *)path;
- (NSString *)resolvedPathForStoredClipPath:(NSString *)storedPath;
- (NSString *)standardizedPath:(NSString *)path;
- (NSString *)canonicalPath:(NSString *)path;
- (BOOL)isPath:(NSString *)path withinDirectory:(NSString *)directoryPath;
- (BOOL)tableExists:(NSString *)tableName inDatabase:(FMDatabase *)db;

@end

@implementation RCDatabaseManager

+ (instancetype)shared {
    static RCDatabaseManager *sharedManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedManager = [[self alloc] initPrivate];
    });
    return sharedManager;
}

- (instancetype)init {
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:@"Use +[RCDatabaseManager shared]."
                                 userInfo:nil];
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _databasePath = [[self class] defaultDatabasePath];
        _setupCompleted = NO;
    }
    return self;
}

#pragma mark - Public: Setup / Migration

- (BOOL)setupDatabase {
    @synchronized (self) {
        if (self.setupCompleted) {
            return YES;
        }

        if (![self ensureDatabaseQueue]) {
            return NO;
        }

        __block BOOL setupSucceeded = YES;
        [self.databaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
            if (![self enableForeignKeysForDatabase:db]) {
                setupSucceeded = NO;
                return;
            }

            if (![self enableSecureDeleteForDatabase:db]) {
                setupSucceeded = NO;
                return;
            }

            if (self.databaseCreatedDuringCurrentSetup
                && ![self configureIncrementalAutoVacuumForNewDatabase:db]) {
                setupSucceeded = NO;
                return;
            }

            setupSucceeded = [self createBaseSchemaInDatabase:db];
        }];

        if (!setupSucceeded) {
            return NO;
        }

        BOOL migrated = [self migrateIfNeeded];
        if (!migrated) {
            return NO;
        }

        [self migrateAutoVacuumToIncrementalIfNeeded];
        [self applyDatabaseFilePermissionsIfNeeded];

        self.setupCompleted = YES;
        return YES;
    }
}

- (NSInteger)currentSchemaVersion {
    if (![self ensureDatabaseQueue]) {
        return 0;
    }

    __block NSInteger version = 0;
    [self.databaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        if (![db executeUpdate:@"CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)"]) {
            [self logDatabaseError:db context:@"Failed to create schema_version table before reading version"];
            return;
        }

        FMResultSet *resultSet = [db executeQuery:@"SELECT MAX(version) AS version FROM schema_version"];
        if (!resultSet) {
            [self logDatabaseError:db context:@"Failed to fetch schema version"];
            return;
        }

        if ([resultSet next]) {
            version = [resultSet longLongIntForColumn:@"version"];
        }
        [resultSet close];
    }];

    return version;
}

- (BOOL)migrateIfNeeded {
    if (![self ensureDatabaseQueue]) {
        return NO;
    }

    NSInteger version = [self currentSchemaVersion];
    if (version > kRCCurrentSchemaVersion) {
        NSLog(@"[RCDatabaseManager] Schema version %ld is newer than supported version %ld. Migration aborted.",
              (long)version, (long)kRCCurrentSchemaVersion);
        return NO;
    }
    if (version == kRCCurrentSchemaVersion) {
        return YES;
    }

    __block BOOL migrated = YES;
    [self.databaseQueue inTransaction:^(FMDatabase * _Nonnull db, BOOL * _Nonnull rollback) {
        if (version == 0 && ![self createBaseSchemaInDatabase:db]) {
            migrated = NO;
            *rollback = YES;
            return;
        }

        // v1 is the baseline schema.
        NSInteger workingVersion = version;
        while (workingVersion < kRCCurrentSchemaVersion) {
            NSInteger nextVersion = workingVersion + 1;
            switch (nextVersion) {
                case 1:
                    break;
                case 2:
                    if (![db executeUpdate:@"CREATE INDEX IF NOT EXISTS idx_snippets_folder_order ON snippets(folder_id, snippet_index, id)"]) {
                        [self logDatabaseError:db context:@"Failed to create idx_snippets_folder_order"];
                        migrated = NO;
                        *rollback = YES;
                        return;
                    }
                    break;
                default:
                    migrated = NO;
                    *rollback = YES;
                    NSLog(@"[RCDatabaseManager] Unknown migration target version: %ld", (long)nextVersion);
                    return;
            }
            workingVersion = nextVersion;
        }

        if (![db executeUpdate:@"DELETE FROM schema_version"]) {
            [self logDatabaseError:db context:@"Failed to clear schema_version during migration"];
            migrated = NO;
            *rollback = YES;
            return;
        }

        if (![db executeUpdate:@"INSERT INTO schema_version (version) VALUES (?)", @(kRCCurrentSchemaVersion)]) {
            [self logDatabaseError:db context:@"Failed to write schema_version during migration"];
            migrated = NO;
            *rollback = YES;
            return;
        }
    }];

    return migrated;
}

- (BOOL)performDatabaseOperation:(BOOL (^)(FMDatabase *db))block {
    if (block == nil || ![self ensureDatabaseReadyForOperation]) {
        return NO;
    }

    __block BOOL succeeded = YES;
    [self.databaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        succeeded = block(db);
    }];
    return succeeded;
}

- (BOOL)performTransaction:(BOOL (^)(FMDatabase *db, BOOL *rollback))block {
    if (block == nil || ![self ensureDatabaseReadyForOperation]) {
        return NO;
    }

    __block BOOL succeeded = YES;
    [self.databaseQueue inTransaction:^(FMDatabase * _Nonnull db, BOOL * _Nonnull rollback) {
        BOOL operationSucceeded = block(db, rollback);
        if (!operationSucceeded || *rollback) {
            succeeded = NO;
            *rollback = YES;
        }
    }];

    return succeeded;
}

- (void)closeDatabase {
    @synchronized (self) {
        [self.databaseQueue close];
        self.databaseQueue = nil;
        self.setupCompleted = NO;
        self.databaseCreatedDuringCurrentSetup = NO;
    }
}

- (void)deleteDatabaseFiles {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *basePath = self.databasePath ?: @"";
    if (basePath.length == 0) {
        return;
    }

    NSArray<NSString *> *suffixes = @[@"", @"-journal", @"-wal", @"-shm"];
    for (NSString *suffix in suffixes) {
        NSString *path = [basePath stringByAppendingString:suffix];
        [fileManager removeItemAtPath:path error:nil];
    }
}

- (void)reinitializeDatabase {
    [self setupDatabase];
}

#pragma mark - Public: clip_items

- (BOOL)insertClipItem:(NSDictionary *)clipDict {
    if (![self ensureDatabaseReadyForOperation]) {
        return NO;
    }

    NSString *rawDataPath = [self stringValueInDictionary:clipDict keys:@[@"data_path", @"dataPath"] defaultValue:nil];
    NSString *dataPath = [self storagePathForClipPath:rawDataPath];
    NSString *dataHash = [self stringValueInDictionary:clipDict keys:@[@"data_hash", @"dataHash"] defaultValue:nil];
    NSNumber *updateTime = [self numberValueInDictionary:clipDict keys:@[@"update_time", @"updateTime"] defaultValue:nil];

    if (dataPath.length == 0 || dataHash.length == 0 || updateTime == nil) {
        return NO;
    }

    NSString *title = [self stringValueInDictionary:clipDict keys:@[@"title"] defaultValue:@""];
    NSString *primaryType = [self stringValueInDictionary:clipDict keys:@[@"primary_type", @"primaryType"] defaultValue:@""];
    NSString *rawThumbnailPath = [self stringValueInDictionary:clipDict keys:@[@"thumbnail_path", @"thumbnailPath"] defaultValue:@""];
    NSString *thumbnailPath = [self storagePathForClipPath:rawThumbnailPath];
    NSNumber *isColorCode = [self numberValueInDictionary:clipDict keys:@[@"is_color_code", @"isColorCode"] defaultValue:@0];

    __block BOOL inserted = NO;
    [self.databaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        inserted = [db executeUpdate:@"INSERT INTO clip_items (data_path, title, data_hash, primary_type, update_time, thumbnail_path, is_color_code) VALUES (?, ?, ?, ?, ?, ?, ?)"
                     withArgumentsInArray:@[dataPath, title, dataHash, primaryType, updateTime, thumbnailPath, isColorCode]];
        if (!inserted) {
            int errorCode = db.lastErrorCode;
            int extendedErrorCode = db.lastExtendedErrorCode;
            if (errorCode == SQLITE_CONSTRAINT && extendedErrorCode == SQLITE_CONSTRAINT_UNIQUE) {
                NSLog(@"[RCDatabaseManager] insertClipItem: duplicate data_hash detected (code=%d, extended=%d)",
                      errorCode,
                      extendedErrorCode);
            } else if (errorCode == SQLITE_CONSTRAINT) {
                os_log_with_type(RCDatabaseManagerLog(), OS_LOG_TYPE_DEBUG,
                                 "insertClipItem constraint violation (code=%d, extended=%d, message=%{private}@)",
                                 errorCode, extendedErrorCode, db.lastErrorMessage);
            } else {
                [self logDatabaseError:db context:@"Failed to insert clip_items row"];
            }
        }
    }];

    return inserted;
}

- (BOOL)updateClipItemUpdateTime:(NSString *)dataHash time:(NSInteger)updateTime {
    if (dataHash.length == 0 || ![self ensureDatabaseReadyForOperation]) {
        return NO;
    }

    __block BOOL updated = NO;
    [self.databaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        updated = [db executeUpdate:@"UPDATE clip_items SET update_time = ? WHERE data_hash = ?"
               withArgumentsInArray:@[@(updateTime), dataHash]];
        if (!updated) {
            [self logDatabaseError:db context:@"Failed to update clip_items.update_time"];
        } else if (db.changes == 0) {
            updated = NO;
            NSLog(@"[RCDatabaseManager] updateClipItemUpdateTime: no rows matched data_hash");
        }
    }];

    return updated;
}

- (BOOL)deleteClipItemWithDataHash:(NSString *)dataHash {
    if (dataHash.length == 0 || ![self ensureDatabaseReadyForOperation]) {
        return NO;
    }

    __block BOOL deleted = NO;
    [self.databaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        deleted = [db executeUpdate:@"DELETE FROM clip_items WHERE data_hash = ?" withArgumentsInArray:@[dataHash]];
        if (!deleted) {
            [self logDatabaseError:db context:@"Failed to delete clip_items row by data_hash"];
        }
    }];

    return deleted;
}

- (BOOL)deleteClipItemWithDataHash:(NSString *)dataHash olderThan:(NSInteger)updateTimeMs {
    if (dataHash.length == 0 || ![self ensureDatabaseReadyForOperation]) {
        return NO;
    }

    __block BOOL deleted = NO;
    [self.databaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        BOOL executed = [db executeUpdate:@"DELETE FROM clip_items WHERE data_hash = ? AND update_time < ?"
                     withArgumentsInArray:@[dataHash, @(updateTimeMs)]];
        if (!executed) {
            [self logDatabaseError:db context:@"Failed to delete expired clip_items row"];
            return;
        }
        deleted = (db.changes > 0);
    }];

    return deleted;
}

- (BOOL)deleteClipItemsOlderThan:(NSInteger)updateTime {
    if (![self ensureDatabaseReadyForOperation]) {
        return NO;
    }

    __block BOOL deleted = NO;
    [self.databaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        deleted = [db executeUpdate:@"DELETE FROM clip_items WHERE update_time < ?" withArgumentsInArray:@[@(updateTime)]];
        if (!deleted) {
            [self logDatabaseError:db context:@"Failed to delete old clip_items rows"];
        }
    }];

    return deleted;
}

- (NSArray<RCClipItem *> *)clipItemsOlderThan:(NSInteger)updateTimeMs {
    if (![self ensureDatabaseReadyForOperation]) {
        return @[];
    }

    __block NSMutableArray<RCClipItem *> *clipItems = [NSMutableArray array];
    [self.databaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        FMResultSet *resultSet = [db executeQuery:@"SELECT id, data_path, title, data_hash, primary_type, update_time, thumbnail_path, is_color_code FROM clip_items WHERE update_time < ? ORDER BY update_time ASC"
                             withArgumentsInArray:@[@(updateTimeMs)]];
        if (!resultSet) {
            [self logDatabaseError:db context:@"Failed to fetch old clip_items rows"];
            return;
        }

        while ([resultSet next]) {
            NSDictionary *clipDictionary = [self clipItemDictionaryFromResultSet:resultSet];
            RCClipItem *clipItem = [[RCClipItem alloc] initWithDictionary:clipDictionary];
            [clipItems addObject:clipItem];
        }
        [resultSet close];
    }];

    return [clipItems copy];
}

- (NSArray *)fetchClipItemsWithLimit:(NSInteger)limit {
    if (limit <= 0 || ![self ensureDatabaseReadyForOperation]) {
        return @[];
    }

    __block NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    [self.databaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        FMResultSet *resultSet = [db executeQuery:@"SELECT id, data_path, title, data_hash, primary_type, update_time, thumbnail_path, is_color_code FROM clip_items ORDER BY update_time DESC LIMIT ?"
                             withArgumentsInArray:@[@(limit)]];
        if (!resultSet) {
            [self logDatabaseError:db context:@"Failed to fetch clip_items list"];
            return;
        }

        while ([resultSet next]) {
            [rows addObject:[self clipItemDictionaryFromResultSet:resultSet]];
        }
        [resultSet close];
    }];

    return [rows copy];
}

- (nullable NSDictionary *)clipItemWithDataHash:(NSString *)dataHash {
    if (dataHash.length == 0 || ![self ensureDatabaseReadyForOperation]) {
        return nil;
    }

    __block NSDictionary *clipItem = nil;
    [self.databaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        FMResultSet *resultSet = [db executeQuery:@"SELECT id, data_path, title, data_hash, primary_type, update_time, thumbnail_path, is_color_code FROM clip_items WHERE data_hash = ? LIMIT 1"
                             withArgumentsInArray:@[dataHash]];
        if (!resultSet) {
            [self logDatabaseError:db context:@"Failed to fetch clip_items row by data_hash"];
            return;
        }

        if ([resultSet next]) {
            clipItem = [self clipItemDictionaryFromResultSet:resultSet];
        }
        [resultSet close];
    }];

    return clipItem;
}

- (NSInteger)clipItemCount {
    if (![self ensureDatabaseReadyForOperation]) {
        return 0;
    }

    __block NSInteger count = 0;
    [self.databaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        FMResultSet *resultSet = [db executeQuery:@"SELECT COUNT(*) AS total FROM clip_items"];
        if (!resultSet) {
            [self logDatabaseError:db context:@"Failed to count clip_items rows"];
            return;
        }

        if ([resultSet next]) {
            count = [resultSet longLongIntForColumn:@"total"];
        }
        [resultSet close];
    }];

    return count;
}

- (BOOL)deleteAllClipItems {
    if (![self ensureDatabaseReadyForOperation]) {
        return NO;
    }

    __block BOOL deleted = NO;
    [self.databaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        deleted = [db executeUpdate:@"DELETE FROM clip_items"];
        if (!deleted) {
            [self logDatabaseError:db context:@"Failed to delete all clip_items rows"];
        }
    }];

    return deleted;
}

- (BOOL)deleteAllSnippets {
    if (![self ensureDatabaseReadyForOperation]) {
        return NO;
    }

    __block BOOL deleted = YES;
    [self.databaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        if ([self tableExists:@"snippets" inDatabase:db]) {
            if (![db executeUpdate:@"DELETE FROM snippets"]) {
                [self logDatabaseError:db context:@"Failed to delete all snippets rows"];
                deleted = NO;
                return;
            }
        }

        if ([self tableExists:@"snippet_folders" inDatabase:db]) {
            if (![db executeUpdate:@"DELETE FROM snippet_folders"]) {
                [self logDatabaseError:db context:@"Failed to delete all snippet_folders rows"];
                deleted = NO;
                return;
            }
        }
    }];

    return deleted;
}

- (BOOL)panicDeleteAllClipItems {
    if (![self ensureDatabaseQueue]) {
        return NO;
    }

    __block BOOL deleted = NO;
    [self.databaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        deleted = [db executeUpdate:@"DELETE FROM clip_items"];
        if (!deleted) {
            [self logDatabaseError:db context:@"Panic: Failed to delete all clip_items rows"];
        }
    }];
    return deleted;
}

- (BOOL)panicDeleteAllSnippets {
    if (![self ensureDatabaseQueue]) {
        return NO;
    }

    __block BOOL deleted = YES;
    [self.databaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        if ([self tableExists:@"snippets" inDatabase:db]) {
            if (![db executeUpdate:@"DELETE FROM snippets"]) {
                [self logDatabaseError:db context:@"Panic: Failed to delete all snippets rows"];
                deleted = NO;
                return;
            }
        }

        if ([self tableExists:@"snippet_folders" inDatabase:db]) {
            if (![db executeUpdate:@"DELETE FROM snippet_folders"]) {
                [self logDatabaseError:db context:@"Panic: Failed to delete all snippet_folders rows"];
                deleted = NO;
                return;
            }
        }
    }];
    return deleted;
}

#pragma mark - Public: snippet_folders

- (BOOL)insertSnippetFolder:(NSDictionary *)folderDict {
    if (![self ensureDatabaseReadyForOperation]) {
        return NO;
    }

    NSString *identifier = [self stringValueInDictionary:folderDict keys:@[@"identifier"] defaultValue:nil];
    if (identifier.length == 0) {
        return NO;
    }

    NSNumber *folderIndex = [self numberValueInDictionary:folderDict keys:@[@"folder_index", @"folderIndex"] defaultValue:@0];
    NSNumber *enabled = [self numberValueInDictionary:folderDict keys:@[@"enabled"] defaultValue:@1];
    NSString *title = [self stringValueInDictionary:folderDict keys:@[@"title"] defaultValue:@"untitled folder"];

    __block BOOL inserted = NO;
    [self.databaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        inserted = [db executeUpdate:@"INSERT INTO snippet_folders (identifier, folder_index, enabled, title) VALUES (?, ?, ?, ?)"
                withArgumentsInArray:@[identifier, folderIndex, enabled, title]];
        if (!inserted) {
            [self logDatabaseError:db context:@"Failed to insert snippet_folders row"];
        }
    }];

    return inserted;
}

- (BOOL)updateSnippetFolder:(NSDictionary *)folderDict {
    NSString *identifier = [self stringValueInDictionary:folderDict keys:@[@"identifier"] defaultValue:nil];
    if (identifier.length == 0) {
        return NO;
    }

    NSMutableDictionary *mutableDict = [folderDict mutableCopy];
    [mutableDict removeObjectForKey:@"identifier"];
    return [self updateSnippetFolder:identifier withDict:[mutableDict copy]];
}

- (BOOL)updateSnippetFolder:(NSString *)identifier withDict:(NSDictionary *)dict {
    if (identifier.length == 0 || ![self ensureDatabaseReadyForOperation]) {
        return NO;
    }

    NSMutableArray<NSString *> *setClauses = [NSMutableArray array];
    NSMutableArray *arguments = [NSMutableArray array];

    NSNumber *folderIndex = [self numberValueInDictionary:dict keys:@[@"folder_index", @"folderIndex"] defaultValue:nil];
    if (folderIndex != nil) {
        [setClauses addObject:@"folder_index = ?"];
        [arguments addObject:folderIndex];
    }

    NSNumber *enabled = [self numberValueInDictionary:dict keys:@[@"enabled"] defaultValue:nil];
    if (enabled != nil) {
        [setClauses addObject:@"enabled = ?"];
        [arguments addObject:enabled];
    }

    NSString *title = [self stringValueInDictionary:dict keys:@[@"title"] defaultValue:nil];
    if (title != nil) {
        [setClauses addObject:@"title = ?"];
        [arguments addObject:title];
    }

    if (setClauses.count == 0) {
        return YES;
    }

    NSString *sql = [NSString stringWithFormat:@"UPDATE snippet_folders SET %@ WHERE identifier = ?", [setClauses componentsJoinedByString:@", "]];
    [arguments addObject:identifier];

    __block BOOL updated = NO;
    [self.databaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        updated = [db executeUpdate:sql withArgumentsInArray:arguments];
        if (!updated) {
            [self logDatabaseError:db context:@"Failed to update snippet_folders row"];
        } else if (db.changes == 0) {
            updated = NO;
            NSLog(@"[RCDatabaseManager] updateSnippetFolder: no rows matched identifier");
        }
    }];

    return updated;
}

- (BOOL)deleteSnippetFolder:(NSString *)identifier {
    if (identifier.length == 0 || ![self ensureDatabaseReadyForOperation]) {
        return NO;
    }

    __block BOOL deleted = NO;
    [self.databaseQueue inTransaction:^(FMDatabase * _Nonnull db, BOOL * _Nonnull rollback) {
        // Explicitly delete child snippets before deleting the folder as a
        // defensive measure, rather than relying solely on ON DELETE CASCADE.
        BOOL deletedChildren = [db executeUpdate:@"DELETE FROM snippets WHERE folder_id = ?" withArgumentsInArray:@[identifier]];
        if (!deletedChildren) {
            [self logDatabaseError:db context:@"Failed to delete child snippets for folder"];
        }

        BOOL deletedFolder = [db executeUpdate:@"DELETE FROM snippet_folders WHERE identifier = ?" withArgumentsInArray:@[identifier]];
        if (!deletedFolder) {
            [self logDatabaseError:db context:@"Failed to delete snippet_folders row"];
        }

        if (db.hadError || !deletedChildren || !deletedFolder) {
            *rollback = YES;
            deleted = NO;
            return;
        }

        deleted = YES;
    }];

    return deleted;
}

- (BOOL)deleteAllSnippetFolders {
    if (![self ensureDatabaseReadyForOperation]) {
        return NO;
    }

    __block BOOL deleted = NO;
    [self.databaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        deleted = [db executeUpdate:@"DELETE FROM snippet_folders"];
        if (!deleted) {
            [self logDatabaseError:db context:@"Failed to delete all snippet_folders rows"];
        }
    }];

    return deleted;
}

- (NSArray *)fetchAllSnippetFolders {
    if (![self ensureDatabaseReadyForOperation]) {
        return @[];
    }

    __block NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    [self.databaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        FMResultSet *resultSet = [db executeQuery:@"SELECT id, identifier, folder_index, enabled, title FROM snippet_folders ORDER BY folder_index ASC, id ASC"];
        if (!resultSet) {
            [self logDatabaseError:db context:@"Failed to fetch snippet_folders rows"];
            return;
        }

        while ([resultSet next]) {
            [rows addObject:[self snippetFolderDictionaryFromResultSet:resultSet]];
        }
        [resultSet close];
    }];

    return [rows copy];
}

- (NSArray<NSDictionary *> *)fetchSnippetCatalog {
    if (![self ensureDatabaseReadyForOperation]) {
        return nil;
    }

    __block NSArray<NSDictionary *> *catalog = nil;
    BOOL succeeded = [self performTransaction:^BOOL(FMDatabase *db, BOOL *rollback) {

        NSMutableArray<NSMutableDictionary *> *folders = [NSMutableArray array];
        NSMutableDictionary<NSString *, NSMutableDictionary *> *folderByIdentifier = [NSMutableDictionary dictionary];

        FMResultSet *folderResultSet = [db executeQuery:@"SELECT id, identifier, folder_index, enabled, title FROM snippet_folders ORDER BY folder_index ASC, id ASC"];
        if (folderResultSet == nil) {
            [self logDatabaseError:db context:@"Failed to fetch snippet catalog folders"];
            *rollback = YES;
            return NO;
        }
        while ([folderResultSet next]) {
            NSMutableDictionary *folder = [[self snippetFolderDictionaryFromResultSet:folderResultSet] mutableCopy];
            folder[@"snippets"] = [NSMutableArray array];
            NSString *identifier = [folder[@"identifier"] isKindOfClass:[NSString class]] ? folder[@"identifier"] : @"";
            [folders addObject:folder];
            if (identifier.length > 0) {
                folderByIdentifier[identifier] = folder;
            }
        }
        BOOL foldersRead = !db.hadError;
        [folderResultSet close];
        if (!foldersRead) { *rollback = YES; return NO; }

        FMResultSet *snippetResultSet = [db executeQuery:@"SELECT id, identifier, folder_id, snippet_index, enabled, title, content FROM snippets ORDER BY folder_id ASC, snippet_index ASC, id ASC"];
        if (snippetResultSet == nil) {
            [self logDatabaseError:db context:@"Failed to fetch snippet catalog snippets"];
            *rollback = YES;
            return NO;
        }
        while ([snippetResultSet next]) {
            NSDictionary *snippet = [self snippetDictionaryFromResultSet:snippetResultSet];
            NSString *folderIdentifier = [snippet[@"folder_id"] isKindOfClass:[NSString class]] ? snippet[@"folder_id"] : @"";
            NSMutableArray *snippets = folderByIdentifier[folderIdentifier][@"snippets"];
            if ([snippets isKindOfClass:[NSMutableArray class]]) {
                [snippets addObject:snippet];
            }
        }
        BOOL snippetsRead = !db.hadError;
        [snippetResultSet close];
        if (!snippetsRead) { *rollback = YES; return NO; }

        NSMutableArray<NSDictionary *> *frozen = [NSMutableArray arrayWithCapacity:folders.count];
        for (NSMutableDictionary *folder in folders) {
            NSMutableDictionary *copy = [folder mutableCopy];
            copy[@"snippets"] = [folder[@"snippets"] copy] ?: @[];
            [frozen addObject:[copy copy]];
        }
        catalog = [frozen copy];
        return YES;
    }];

    return succeeded ? catalog : nil;
}

- (BOOL)updateSnippetFolderIndexes:(NSArray<NSString *> *)identifiers {
    if (![self ensureDatabaseReadyForOperation]) {
        return NO;
    }
    if (identifiers.count == 0) {
        return YES;
    }

    return [self performTransaction:^BOOL(FMDatabase *db, BOOL *rollback) {
        NSInteger index = 0;
        for (NSString *identifier in identifiers) {
            if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0) {
                *rollback = YES;
                return NO;
            }
            BOOL updated = [db executeUpdate:@"UPDATE snippet_folders SET folder_index = ? WHERE identifier = ?"
                        withArgumentsInArray:@[@(index), identifier]];
            if (!updated || db.changes != 1) {
                [self logDatabaseError:db context:@"Failed to update snippet folder index"];
                *rollback = YES;
                return NO;
            }
            index += 1;
        }
        return YES;
    }];
}

- (BOOL)updateSnippetPlacement:(NSArray<NSDictionary *> *)placements {
    if (![self ensureDatabaseReadyForOperation]) {
        return NO;
    }
    if (placements.count == 0) {
        return YES;
    }

    return [self performTransaction:^BOOL(FMDatabase *db, BOOL *rollback) {
        for (NSDictionary *placement in placements) {
            if (![placement isKindOfClass:[NSDictionary class]]) {
                *rollback = YES;
                return NO;
            }
            NSString *identifier = [self stringValueInDictionary:placement keys:@[@"identifier"] defaultValue:@""];
            NSString *folderID = [self stringValueInDictionary:placement keys:@[@"folder_id", @"folderId"] defaultValue:@""];
            NSNumber *snippetIndex = [self numberValueInDictionary:placement keys:@[@"snippet_index", @"snippetIndex"] defaultValue:@0];
            if (identifier.length == 0 || folderID.length == 0) {
                *rollback = YES;
                return NO;
            }
            BOOL updated = [db executeUpdate:@"UPDATE snippets SET folder_id = ?, snippet_index = ? WHERE identifier = ?"
                        withArgumentsInArray:@[folderID, snippetIndex, identifier]];
            if (!updated || db.changes != 1) {
                [self logDatabaseError:db context:@"Failed to update snippet placement"];
                *rollback = YES;
                return NO;
            }
        }
        return YES;
    }];
}

- (BOOL)snippetFolderExistsWithIdentifier:(NSString *)identifier {
    if (identifier.length == 0 || ![self ensureDatabaseReadyForOperation]) {
        return NO;
    }

    __block BOOL exists = NO;
    [self.databaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        FMResultSet *resultSet = [db executeQuery:@"SELECT 1 FROM snippet_folders WHERE identifier = ? LIMIT 1"
                             withArgumentsInArray:@[identifier]];
        if (!resultSet) {
            [self logDatabaseError:db context:@"Failed to check snippet_folders identifier"];
            return;
        }

        exists = [resultSet next];
        [resultSet close];
    }];

    return exists;
}

#pragma mark - Public: snippets

- (BOOL)insertSnippet:(NSDictionary *)snippetDict {
    if (![self ensureDatabaseReadyForOperation]) {
        return NO;
    }

    NSString *identifier = [self stringValueInDictionary:snippetDict keys:@[@"identifier"] defaultValue:nil];
    NSString *folderID = [self stringValueInDictionary:snippetDict keys:@[@"folder_id", @"folderId"] defaultValue:nil];

    if (identifier.length == 0 || folderID.length == 0) {
        return NO;
    }

    NSNumber *snippetIndex = [self numberValueInDictionary:snippetDict keys:@[@"snippet_index", @"snippetIndex"] defaultValue:@0];
    NSNumber *enabled = [self numberValueInDictionary:snippetDict keys:@[@"enabled"] defaultValue:@1];
    NSString *title = [self stringValueInDictionary:snippetDict keys:@[@"title"] defaultValue:@"untitled snippet"];
    NSString *content = [self stringValueInDictionary:snippetDict keys:@[@"content"] defaultValue:@""];

    __block BOOL inserted = NO;
    [self.databaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        inserted = [db executeUpdate:@"INSERT INTO snippets (identifier, folder_id, snippet_index, enabled, title, content) VALUES (?, ?, ?, ?, ?, ?)"
                withArgumentsInArray:@[identifier, folderID, snippetIndex, enabled, title, content]];
        if (!inserted) {
            [self logDatabaseError:db context:@"Failed to insert snippets row"];
        }
    }];

    return inserted;
}

- (BOOL)insertSnippet:(NSDictionary *)snippetDict inFolder:(NSString *)folderIdentifier {
    if (folderIdentifier.length == 0) {
        return NO;
    }

    NSMutableDictionary *mutableDict = [snippetDict mutableCopy];
    if (mutableDict == nil) {
        mutableDict = [NSMutableDictionary dictionary];
    }
    mutableDict[@"folder_id"] = folderIdentifier;
    return [self insertSnippet:[mutableDict copy]];
}

- (BOOL)updateSnippet:(NSDictionary *)snippetDict {
    NSString *identifier = [self stringValueInDictionary:snippetDict keys:@[@"identifier"] defaultValue:nil];
    if (identifier.length == 0) {
        return NO;
    }

    NSMutableDictionary *mutableDict = [snippetDict mutableCopy];
    [mutableDict removeObjectForKey:@"identifier"];
    return [self updateSnippet:identifier withDict:[mutableDict copy]];
}

- (BOOL)updateSnippet:(NSString *)identifier withDict:(NSDictionary *)dict {
    if (identifier.length == 0 || ![self ensureDatabaseReadyForOperation]) {
        return NO;
    }

    NSMutableArray<NSString *> *setClauses = [NSMutableArray array];
    NSMutableArray *arguments = [NSMutableArray array];

    NSString *folderID = [self stringValueInDictionary:dict keys:@[@"folder_id", @"folderId"] defaultValue:nil];
    if (folderID != nil) {
        [setClauses addObject:@"folder_id = ?"];
        [arguments addObject:folderID];
    }

    NSNumber *snippetIndex = [self numberValueInDictionary:dict keys:@[@"snippet_index", @"snippetIndex"] defaultValue:nil];
    if (snippetIndex != nil) {
        [setClauses addObject:@"snippet_index = ?"];
        [arguments addObject:snippetIndex];
    }

    NSNumber *enabled = [self numberValueInDictionary:dict keys:@[@"enabled"] defaultValue:nil];
    if (enabled != nil) {
        [setClauses addObject:@"enabled = ?"];
        [arguments addObject:enabled];
    }

    NSString *title = [self stringValueInDictionary:dict keys:@[@"title"] defaultValue:nil];
    if (title != nil) {
        [setClauses addObject:@"title = ?"];
        [arguments addObject:title];
    }

    NSString *content = [self stringValueInDictionary:dict keys:@[@"content"] defaultValue:nil];
    if (content != nil) {
        [setClauses addObject:@"content = ?"];
        [arguments addObject:content];
    }

    if (setClauses.count == 0) {
        return YES;
    }

    NSString *sql = [NSString stringWithFormat:@"UPDATE snippets SET %@ WHERE identifier = ?", [setClauses componentsJoinedByString:@", "]];
    [arguments addObject:identifier];

    __block BOOL updated = NO;
    [self.databaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        updated = [db executeUpdate:sql withArgumentsInArray:arguments];
        if (!updated) {
            [self logDatabaseError:db context:@"Failed to update snippets row"];
        } else if (db.changes == 0) {
            updated = NO;
            NSLog(@"[RCDatabaseManager] updateSnippet: no rows matched identifier");
        }
    }];

    return updated;
}

- (BOOL)deleteSnippet:(NSString *)identifier {
    if (identifier.length == 0 || ![self ensureDatabaseReadyForOperation]) {
        return NO;
    }

    __block BOOL deleted = NO;
    [self.databaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        deleted = [db executeUpdate:@"DELETE FROM snippets WHERE identifier = ?" withArgumentsInArray:@[identifier]];
        if (!deleted) {
            [self logDatabaseError:db context:@"Failed to delete snippets row"];
        }
    }];

    return deleted;
}

- (NSArray *)fetchSnippetsForFolder:(NSString *)folderIdentifier {
    if (folderIdentifier.length == 0 || ![self ensureDatabaseReadyForOperation]) {
        return @[];
    }

    __block NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    [self.databaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        FMResultSet *resultSet = [db executeQuery:@"SELECT id, identifier, folder_id, snippet_index, enabled, title, content FROM snippets WHERE folder_id = ? ORDER BY snippet_index ASC, id ASC"
                             withArgumentsInArray:@[folderIdentifier]];
        if (!resultSet) {
            [self logDatabaseError:db context:@"Failed to fetch snippets rows"];
            return;
        }

        while ([resultSet next]) {
            [rows addObject:[self snippetDictionaryFromResultSet:resultSet]];
        }
        [resultSet close];
    }];

    return [rows copy];
}

- (BOOL)snippetExistsWithIdentifier:(NSString *)identifier {
    if (identifier.length == 0 || ![self ensureDatabaseReadyForOperation]) {
        return NO;
    }

    __block BOOL exists = NO;
    [self.databaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        FMResultSet *resultSet = [db executeQuery:@"SELECT 1 FROM snippets WHERE identifier = ? LIMIT 1"
                             withArgumentsInArray:@[identifier]];
        if (!resultSet) {
            [self logDatabaseError:db context:@"Failed to check snippets identifier"];
            return;
        }

        exists = [resultSet next];
        [resultSet close];
    }];

    return exists;
}

#pragma mark - Private: Database setup

+ (NSString *)defaultDatabasePath {
    NSString *revclipDirectoryPath = [RCUtilities applicationSupportPath];
    return [revclipDirectoryPath stringByAppendingPathComponent:@"revclip.db"];
}

// WARNING: This method must never be called from within an FMDatabaseQueue
// inDatabase: or inTransaction: block. FMDatabaseQueue uses a serial dispatch
// queue internally, so re-entrant calls will deadlock.
- (BOOL)ensureDatabaseReadyForOperation {
    if ([RCPanicEraseService shared].isPanicInProgress) {
        return NO;
    }

    @synchronized (self) {
        if (self.setupCompleted) {
            return YES;
        }

        return [self setupDatabase];
    }
}

- (BOOL)ensureDatabaseQueue {
    if (self.databaseQueue != nil) {
        return YES;
    }

    NSString *directoryPath = [self.databasePath stringByDeletingLastPathComponent];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    BOOL exists = [fileManager fileExistsAtPath:directoryPath isDirectory:&isDirectory];

    if (exists && !isDirectory) {
        os_log_error(RCDatabaseManagerLog(),
                     "Expected directory but found file at path %{private}@",
                     directoryPath);
        return NO;
    }

    NSDictionary *directoryAttributes = @{ NSFilePosixPermissions: kRCDatabaseDirectoryPermissions };
    if (exists) {
        NSError *permissionsError = nil;
        BOOL applied = [fileManager setAttributes:directoryAttributes
                                     ofItemAtPath:directoryPath
                                            error:&permissionsError];
        if (!applied && permissionsError != nil) {
            os_log_with_type(RCDatabaseManagerLog(), OS_LOG_TYPE_DEBUG,
                             "Failed to apply database directory permissions for %{private}@ (%{private}@)",
                             directoryPath, permissionsError.localizedDescription);
        }
    } else {
        NSError *directoryError = nil;
        BOOL created = [fileManager createDirectoryAtPath:directoryPath
                              withIntermediateDirectories:YES
                                               attributes:directoryAttributes
                                                    error:&directoryError];
        if (!created || directoryError != nil) {
            os_log_error(RCDatabaseManagerLog(),
                         "Failed to create database directory %{private}@ (%{private}@)",
                         directoryPath, directoryError.localizedDescription);
            return NO;
        }
    }

    BOOL databasePathIsDirectory = NO;
    if ([fileManager fileExistsAtPath:self.databasePath isDirectory:&databasePathIsDirectory]
        && databasePathIsDirectory) {
        os_log_error(RCDatabaseManagerLog(),
                     "Expected database file but found directory at path %{private}@",
                     self.databasePath);
        return NO;
    }

    self.databaseCreatedDuringCurrentSetup = ![fileManager fileExistsAtPath:self.databasePath];
    self.databaseQueue = [FMDatabaseQueue databaseQueueWithPath:self.databasePath];
    if (self.databaseQueue == nil) {
        os_log_error(RCDatabaseManagerLog(),
                     "Failed to create FMDatabaseQueue for path %{private}@",
                     self.databasePath);
        return NO;
    }

    // Enable foreign keys once on the connection. FMDatabaseQueue reuses a single
    // connection, so this setting persists for all subsequent operations.
    __block BOOL foreignKeysEnabled = NO;
    [self.databaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        foreignKeysEnabled = [self enableForeignKeysForDatabase:db];
    }];
    if (!foreignKeysEnabled) {
        self.databaseQueue = nil;
        return NO;
    }

    return YES;
}

- (BOOL)tableExists:(NSString *)tableName inDatabase:(FMDatabase *)db {
    if (tableName.length == 0 || db == nil) {
        return NO;
    }

    FMResultSet *resultSet = [db executeQuery:@"SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1"
                         withArgumentsInArray:@[tableName]];
    if (!resultSet) {
        [self logDatabaseError:db context:@"Failed to inspect sqlite_master"];
        return NO;
    }

    BOOL exists = [resultSet next];
    [resultSet close];
    return exists;
}

- (BOOL)createBaseSchemaInDatabase:(FMDatabase *)db {
    NSArray<NSString *> *schemaStatements = @[
        @"CREATE TABLE IF NOT EXISTS clip_items (id INTEGER PRIMARY KEY AUTOINCREMENT, data_path TEXT NOT NULL, title TEXT DEFAULT '', data_hash TEXT UNIQUE NOT NULL, primary_type TEXT DEFAULT '', update_time INTEGER NOT NULL, thumbnail_path TEXT DEFAULT '', is_color_code INTEGER DEFAULT 0)",
        @"CREATE INDEX IF NOT EXISTS idx_clip_update_time ON clip_items(update_time DESC)",
        @"CREATE TABLE IF NOT EXISTS snippet_folders (id INTEGER PRIMARY KEY AUTOINCREMENT, identifier TEXT UNIQUE NOT NULL, folder_index INTEGER DEFAULT 0, enabled INTEGER DEFAULT 1, title TEXT DEFAULT 'untitled folder')",
        @"CREATE INDEX IF NOT EXISTS idx_folder_index ON snippet_folders(folder_index)",
        @"CREATE TABLE IF NOT EXISTS snippets (id INTEGER PRIMARY KEY AUTOINCREMENT, identifier TEXT UNIQUE NOT NULL, folder_id TEXT NOT NULL REFERENCES snippet_folders(identifier) ON DELETE CASCADE, snippet_index INTEGER DEFAULT 0, enabled INTEGER DEFAULT 1, title TEXT DEFAULT 'untitled snippet', content TEXT DEFAULT '')",
        @"CREATE INDEX IF NOT EXISTS idx_snippet_folder ON snippets(folder_id)",
        @"CREATE INDEX IF NOT EXISTS idx_snippet_index ON snippets(snippet_index)",
        @"CREATE INDEX IF NOT EXISTS idx_snippets_folder_order ON snippets(folder_id, snippet_index, id)",
        @"CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)",
    ];

    for (NSString *statement in schemaStatements) {
        if (![db executeUpdate:statement]) {
            [self logDatabaseError:db context:[NSString stringWithFormat:@"Failed to execute schema statement: %@", statement]];
            return NO;
        }
    }

    // --- Schema version seed ---
    // Seed the initial version row if the table is empty. This is logically
    // separate from table/index creation above and only runs once on first launch.
    BOOL insertedVersion = [db executeUpdate:@"INSERT INTO schema_version (version) SELECT ? WHERE NOT EXISTS (SELECT 1 FROM schema_version)"
                        withArgumentsInArray:@[@(kRCCurrentSchemaVersion)]];
    if (!insertedVersion) {
        [self logDatabaseError:db context:@"Failed to initialize schema_version row"];
        return NO;
    }

    return YES;
}

- (BOOL)enableForeignKeysForDatabase:(FMDatabase *)db {
    BOOL enabled = [db executeStatements:@"PRAGMA foreign_keys = ON"];
    if (!enabled) {
        [self logDatabaseError:db context:@"Failed to enable foreign_keys pragma"];
    }
    return enabled;
}

- (BOOL)enableSecureDeleteForDatabase:(FMDatabase *)db {
    BOOL enabled = [db executeStatements:@"PRAGMA secure_delete = ON"];
    if (!enabled) {
        [self logDatabaseError:db context:@"Failed to enable secure_delete pragma"];
    }
    return enabled;
}

- (BOOL)configureIncrementalAutoVacuumForNewDatabase:(FMDatabase *)db {
    BOOL configured = [db executeStatements:@"PRAGMA auto_vacuum = INCREMENTAL"];
    if (!configured) {
        [self logDatabaseError:db context:@"Failed to configure auto_vacuum=INCREMENTAL for new database"];
    }
    return configured;
}

- (NSInteger)integerValueForPragma:(NSString *)pragmaName
                        inDatabase:(FMDatabase *)db
                      defaultValue:(NSInteger)defaultValue {
    if (pragmaName.length == 0) {
        return defaultValue;
    }

    NSString *query = [NSString stringWithFormat:@"PRAGMA %@;", pragmaName];
    FMResultSet *resultSet = [db executeQuery:query];
    if (resultSet == nil) {
        [self logDatabaseError:db context:[NSString stringWithFormat:@"Failed to query pragma %@", pragmaName]];
        return defaultValue;
    }

    NSInteger value = defaultValue;
    if ([resultSet next]) {
        value = [resultSet longLongIntForColumnIndex:0];
    }
    [resultSet close];
    return value;
}

- (void)migrateAutoVacuumToIncrementalIfNeeded {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:kRCAutoVacuumMigrationCompletedKey]) {
        return;
    }

    __block BOOL shouldMarkCompleted = NO;
    __block BOOL didFailMigration = NO;

    [self.databaseQueue inDatabase:^(FMDatabase * _Nonnull db) {
        NSInteger autoVacuumMode = [self integerValueForPragma:@"auto_vacuum"
                                                    inDatabase:db
                                                  defaultValue:-1];
        if (autoVacuumMode < 0) {
            didFailMigration = YES;
            return;
        }

        if (autoVacuumMode == 0) {
            BOOL configured = [db executeStatements:@"PRAGMA auto_vacuum = INCREMENTAL"];
            if (!configured) {
                didFailMigration = YES;
                [self logDatabaseError:db context:@"Failed to configure auto_vacuum before VACUUM migration"];
                return;
            }

            BOOL vacuumed = [db executeStatements:@"VACUUM"];
            if (!vacuumed) {
                didFailMigration = YES;
                [self logDatabaseError:db context:@"Failed to run VACUUM for auto_vacuum migration"];
                return;
            }
        }

        shouldMarkCompleted = YES;
    }];

    if (shouldMarkCompleted) {
        [defaults setBool:YES forKey:kRCAutoVacuumMigrationCompletedKey];
    } else if (didFailMigration) {
        os_log_error(RCDatabaseManagerLog(),
                     "auto_vacuum migration failed; continuing without migration completion flag");
    }
}

- (void)applyDatabaseFilePermissionsIfNeeded {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *databaseBasePath = self.databasePath ?: @"";
    if (databaseBasePath.length == 0) {
        return;
    }

    NSArray<NSString *> *suffixes = @[@"", @"-journal", @"-wal", @"-shm"];
    for (NSString *suffix in suffixes) {
        NSString *path = [databaseBasePath stringByAppendingString:suffix];
        BOOL isDirectory = NO;
        if (![fileManager fileExistsAtPath:path isDirectory:&isDirectory] || isDirectory) {
            continue;
        }

        NSError *permissionError = nil;
        BOOL applied = [fileManager setAttributes:@{ NSFilePosixPermissions: kRCDatabaseFilePermissions }
                                     ofItemAtPath:path
                                            error:&permissionError];
        if (!applied && permissionError != nil) {
            os_log_error(RCDatabaseManagerLog(),
                         "Failed to apply database file permissions for %{private}@ (%{private}@)",
                         path, permissionError.localizedDescription);
        }
    }
}

- (void)logDatabaseError:(FMDatabase *)db context:(NSString *)context {
    os_log_error(RCDatabaseManagerLog(),
                 "%{public}@ (code=%d, message=%{private}@)",
                 context, db.lastErrorCode, db.lastErrorMessage);
}

- (NSString *)storagePathForClipPath:(NSString *)path {
    NSString *standardizedPath = [self standardizedPath:path];
    if (standardizedPath.length == 0) {
        return @"";
    }

    NSString *clipDirectoryPath = [self standardizedPath:[RCUtilities clipDataDirectoryPath]];
    if (clipDirectoryPath.length == 0) {
        return @"";
    }

    NSString *canonicalPath = [self canonicalPath:standardizedPath];
    NSString *canonicalClipDirectoryPath = [self canonicalPath:clipDirectoryPath];
    if (![self isPath:canonicalPath withinDirectory:canonicalClipDirectoryPath]) {
        return @"";
    }

    return standardizedPath.lastPathComponent ?: @"";
}

- (NSString *)resolvedPathForStoredClipPath:(NSString *)storedPath {
    NSString *standardizedPath = [self standardizedPath:storedPath];
    if (standardizedPath.length == 0) {
        return @"";
    }

    NSString *clipDirectoryPath = [self standardizedPath:[RCUtilities clipDataDirectoryPath]];
    if (clipDirectoryPath.length == 0) {
        return @"";
    }

    NSString *resolvedPath = standardizedPath;
    if (![standardizedPath isAbsolutePath]) {
        resolvedPath = [[clipDirectoryPath stringByAppendingPathComponent:standardizedPath] stringByStandardizingPath];
    }

    NSString *canonicalPath = [self canonicalPath:resolvedPath];
    NSString *canonicalClipDirectoryPath = [self canonicalPath:clipDirectoryPath];
    if ([self isPath:canonicalPath withinDirectory:canonicalClipDirectoryPath]) {
        return resolvedPath;
    }

    return @"";
}

- (NSString *)standardizedPath:(NSString *)path {
    if (path.length == 0) {
        return @"";
    }

    return [[path stringByExpandingTildeInPath] stringByStandardizingPath];
}

- (NSString *)canonicalPath:(NSString *)path {
    NSString *standardizedPath = [self standardizedPath:path];
    if (standardizedPath.length == 0) {
        return @"";
    }

    return [standardizedPath stringByResolvingSymlinksInPath];
}

- (BOOL)isPath:(NSString *)path withinDirectory:(NSString *)directoryPath {
    if (path.length == 0 || directoryPath.length == 0) {
        return NO;
    }

    if ([path isEqualToString:directoryPath]) {
        return YES;
    }

    NSString *directoryPrefix = [directoryPath hasSuffix:@"/"]
        ? directoryPath
        : [directoryPath stringByAppendingString:@"/"];
    return [path hasPrefix:directoryPrefix];
}

#pragma mark - Private: Dictionary helpers

- (nullable id)nonNullValueInDictionary:(NSDictionary *)dictionary keys:(NSArray<NSString *> *)keys {
    for (NSString *key in keys) {
        id value = dictionary[key];
        if (value != nil && value != [NSNull null]) {
            return value;
        }
    }
    return nil;
}

- (nullable NSString *)stringValueInDictionary:(NSDictionary *)dictionary
                                          keys:(NSArray<NSString *> *)keys
                                   defaultValue:(nullable NSString *)defaultValue {
    id rawValue = [self nonNullValueInDictionary:dictionary keys:keys];
    if (rawValue == nil) {
        return defaultValue;
    }

    if ([rawValue isKindOfClass:[NSString class]]) {
        return rawValue;
    }

    if ([rawValue respondsToSelector:@selector(stringValue)]) {
        return [rawValue stringValue];
    }

    return defaultValue;
}

- (nullable NSNumber *)numberValueInDictionary:(NSDictionary *)dictionary
                                          keys:(NSArray<NSString *> *)keys
                                   defaultValue:(nullable NSNumber *)defaultValue {
    id rawValue = [self nonNullValueInDictionary:dictionary keys:keys];
    if (rawValue == nil) {
        return defaultValue;
    }

    if ([rawValue isKindOfClass:[NSNumber class]]) {
        return rawValue;
    }

    if ([rawValue isKindOfClass:[NSString class]]) {
        return @([(NSString *)rawValue integerValue]);
    }

    return defaultValue;
}

#pragma mark - Private: ResultSet mapping

- (NSDictionary *)clipItemDictionaryFromResultSet:(FMResultSet *)resultSet {
    NSString *storedDataPath = [resultSet stringForColumn:@"data_path"] ?: @"";
    NSString *storedThumbnailPath = [resultSet stringForColumn:@"thumbnail_path"] ?: @"";

    return @{
        @"id": @([resultSet longLongIntForColumn:@"id"]),
        @"data_path": [self resolvedPathForStoredClipPath:storedDataPath],
        @"title": [resultSet stringForColumn:@"title"] ?: @"",
        @"data_hash": [resultSet stringForColumn:@"data_hash"] ?: @"",
        @"primary_type": [resultSet stringForColumn:@"primary_type"] ?: @"",
        @"update_time": @([resultSet longLongIntForColumn:@"update_time"]),
        @"thumbnail_path": [self resolvedPathForStoredClipPath:storedThumbnailPath],
        @"is_color_code": @([resultSet intForColumn:@"is_color_code"]),
    };
}

- (NSDictionary *)snippetFolderDictionaryFromResultSet:(FMResultSet *)resultSet {
    return @{
        @"id": @([resultSet longLongIntForColumn:@"id"]),
        @"identifier": [resultSet stringForColumn:@"identifier"] ?: @"",
        @"folder_index": @([resultSet longLongIntForColumn:@"folder_index"]),
        @"enabled": @([resultSet intForColumn:@"enabled"]),
        @"title": [resultSet stringForColumn:@"title"] ?: @"",
    };
}

- (NSDictionary *)snippetDictionaryFromResultSet:(FMResultSet *)resultSet {
    return @{
        @"id": @([resultSet longLongIntForColumn:@"id"]),
        @"identifier": [resultSet stringForColumn:@"identifier"] ?: @"",
        @"folder_id": [resultSet stringForColumn:@"folder_id"] ?: @"",
        @"snippet_index": @([resultSet longLongIntForColumn:@"snippet_index"]),
        @"enabled": @([resultSet intForColumn:@"enabled"]),
        @"title": [resultSet stringForColumn:@"title"] ?: @"",
        @"content": [resultSet stringForColumn:@"content"] ?: @"",
    };
}

@end
