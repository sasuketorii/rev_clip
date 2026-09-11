#import "RCStorageMigration.h"
#import "Revclip-Swift.h"
#import <sqlite3.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>

static BOOL RCStorageFailure(NSError **error) {
    if (error) *error = [NSError errorWithDomain:@"com.revclip.storage" code:1
        userInfo:@{NSLocalizedDescriptionKey: @"Protected storage could not be opened safely."}];
    return NO;
}
static BOOL RCExec(sqlite3 *db, const char *sql) {
    return sqlite3_exec(db, sql, NULL, NULL, NULL) == SQLITE_OK;
}
static NSString *RCScalar(sqlite3 *db, const char *sql) {
    sqlite3_stmt *statement = NULL;
    NSString *result = nil;
    if (sqlite3_prepare_v2(db, sql, -1, &statement, NULL) == SQLITE_OK && sqlite3_step(statement) == SQLITE_ROW) {
        const unsigned char *value = sqlite3_column_text(statement, 0);
        if (value) result = [NSString stringWithUTF8String:(const char *)value];
    }
    sqlite3_finalize(statement);
    return result;
}


// Compare logical rows rather than ciphertext pages (which intentionally differ).
// Sorting by every column preserves duplicate multiplicity without assuming rowid.
static BOOL RCTableContentsMatch(sqlite3 *source, sqlite3 *copy) {
    sqlite3_stmt *tables = NULL;
    if (sqlite3_prepare_v2(source, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name", -1, &tables, NULL) != SQLITE_OK) return NO;
    BOOL ok = YES;
    int tableStep;
    while ((tableStep = sqlite3_step(tables)) == SQLITE_ROW && ok) {
        NSString *name = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(tables, 0)];
        NSString *quoted = [name stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""];
        NSString *base = [NSString stringWithFormat:@"SELECT * FROM \"%@\"", quoted];
        sqlite3_stmt *left = NULL, *right = NULL;
        if (sqlite3_prepare_v2(source, base.UTF8String, -1, &left, NULL) != SQLITE_OK) { ok = NO; break; }
        int columns = sqlite3_column_count(left);
        sqlite3_finalize(left); left = NULL;
        NSMutableArray *order = [NSMutableArray arrayWithCapacity:columns];
        for (int i = 1; i <= columns; i++) [order addObject:[NSString stringWithFormat:@"%d", i]];
        NSString *query = [base stringByAppendingFormat:@" ORDER BY %@", [order componentsJoinedByString:@","]];
        if (sqlite3_prepare_v2(source, query.UTF8String, -1, &left, NULL) != SQLITE_OK
            || sqlite3_prepare_v2(copy, query.UTF8String, -1, &right, NULL) != SQLITE_OK
            || sqlite3_column_count(right) != columns) ok = NO;
        while (ok) {
            int a = sqlite3_step(left), b = sqlite3_step(right);
            if (a == SQLITE_DONE && b == SQLITE_DONE) break;
            if (a != SQLITE_ROW || b != SQLITE_ROW) { ok = NO; break; }
            for (int i = 0; i < columns; i++) {
                int type = sqlite3_column_type(left, i);
                if (type != sqlite3_column_type(right, i)) { ok = NO; break; }
                if (type == SQLITE_NULL) continue;
                if (type == SQLITE_INTEGER) {
                    if (sqlite3_column_int64(left, i) != sqlite3_column_int64(right, i)) ok = NO;
                } else if (type == SQLITE_FLOAT) {
                    if (sqlite3_column_double(left, i) != sqlite3_column_double(right, i)) ok = NO;
                } else {
                    int size = sqlite3_column_bytes(left, i);
                    if (size != sqlite3_column_bytes(right, i)
                        || (size && memcmp(sqlite3_column_blob(left, i), sqlite3_column_blob(right, i), (size_t)size))) ok = NO;
                }
            }
        }
        sqlite3_finalize(left); sqlite3_finalize(right);
    }
    sqlite3_finalize(tables);
    return ok && tableStep == SQLITE_DONE;
}

@implementation RCStorageMigration
+ (BOOL)validatePrivateDirectory:(NSString *)path create:(BOOL)create {
    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) != 0) {
        if (errno != ENOENT || !create || ![[NSFileManager defaultManager] createDirectoryAtPath:path
            withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil]) return NO;
        if (lstat(path.fileSystemRepresentation, &info) != 0) return NO;
    }
    if (!S_ISDIR(info.st_mode) || info.st_uid != getuid()) return NO;
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return NO;
    BOOL ok = fchmod(fd, 0700) == 0;
    close(fd);
    return ok;
}

+ (NSArray<NSString *> *)migrationArtifactPathsBesideDatabase:(NSString *)path error:(NSError **)error {
    NSString *root = path.stringByDeletingLastPathComponent;
    struct stat rootInfo;
    if (lstat(root.fileSystemRepresentation, &rootInfo) != 0 && errno == ENOENT) return @[];
    if (![self validatePrivateDirectory:root create:NO]) { RCStorageFailure(error); return nil; }
    NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:root error:error];
    if (!names) return nil;
    NSMutableArray *paths = [NSMutableArray array];
    NSString *prefix = @".encrypted-";
    for (NSString *name in names) {
        if (![name hasPrefix:prefix] || name.length < prefix.length + 36) continue;
        NSString *uuid = [name substringWithRange:NSMakeRange(prefix.length,36)];
        if (![[NSUUID alloc] initWithUUIDString:uuid]) continue;
        NSString *suffix = [name substringFromIndex:prefix.length + 36];
        if (![@[@".db", @".db-wal", @".db-shm", @".db-journal"] containsObject:suffix]) continue;
        NSString *file = [root stringByAppendingPathComponent:name];
        struct stat info;
        if (lstat(file.fileSystemRepresentation, &info) != 0 || !S_ISREG(info.st_mode)
            || info.st_uid != getuid() || info.st_nlink != 1) { RCStorageFailure(error); return nil; }
        [paths addObject:file];
    }
    return paths;
}
+ (BOOL)validateMigrationArtifactsBesideDatabase:(NSString *)path error:(NSError **)error {
    return [self migrationArtifactPathsBesideDatabase:path error:error] != nil;
}
+ (BOOL)removeMigrationArtifactsBesideDatabase:(NSString *)path error:(NSError **)error {
    NSArray *paths = [self migrationArtifactPathsBesideDatabase:path error:error];
    if (!paths) return NO;
    for (NSString *file in paths) {
        // Unlink removes this directory entry, never a symlink target. Validation
        // above rejects unsupported entries rather than silently claiming erase.
        if (unlink(file.fileSystemRepresentation) != 0 && errno != ENOENT) return RCStorageFailure(error);
    }
    return YES;
}

+ (BOOL)prepareDatabaseAtPath:(NSString *)path error:(NSError **)error {
    NSString *directory = path.stringByDeletingLastPathComponent;
    if (![self validatePrivateDirectory:directory create:YES]) return RCStorageFailure(error);
    struct stat info;
    BOOL exists = lstat(path.fileSystemRepresentation, &info) == 0;
    if (!exists && errno != ENOENT) return RCStorageFailure(error);
    if (exists && (!S_ISREG(info.st_mode) || info.st_uid != getuid() || info.st_nlink != 1)) return RCStorageFailure(error);
    BOOL plaintext = NO;
    if (exists && info.st_size > 0) {
        int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        if (fd < 0) return RCStorageFailure(error);
        char header[16];
        ssize_t count = read(fd, header, sizeof header);
        close(fd);
        plaintext = count == sizeof header && memcmp(header, "SQLite format 3\0", sizeof header) == 0;
    }
    // An encrypted database is the persistent indication that key replacement is unsafe.
    // Inspect clip envelopes as well, covering an interrupted migration or missing database.
    BOOL hasCiphertext = exists && info.st_size > 0 && !plaintext;
    NSString *clips = [directory stringByAppendingPathComponent:@"ClipsData"];
    struct stat clipsInfo;
    if (lstat(clips.fileSystemRepresentation, &clipsInfo) == 0) {
        if (![self validatePrivateDirectory:clips create:NO]) return RCStorageFailure(error);
        NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:clips error:error];
        if (!names) return NO;
        for (NSString *name in names) {
            if ([name hasPrefix:@"."]) continue;
            if (!exists || info.st_size == 0) return RCStorageFailure(error);
            NSString *file = [clips stringByAppendingPathComponent:name];
            int fd = open(file.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
            if (fd < 0) return RCStorageFailure(error);
            struct stat entry;
            unsigned char prefix[32];
            BOOL regular = fstat(fd, &entry) == 0 && S_ISREG(entry.st_mode) && entry.st_nlink == 1;
            ssize_t length = regular ? read(fd, prefix, sizeof prefix) : -1;
            close(fd);
            if (length < 0) return RCStorageFailure(error);
            if ([RCStorageCipher isEncryptedData:[NSData dataWithBytes:prefix length:(NSUInteger)length]]) hasCiphertext = YES;
        }
    } else if (errno != ENOENT) return RCStorageFailure(error);
    NSArray *artifacts = [self migrationArtifactPathsBesideDatabase:path error:error];
    if (!artifacts) return NO;
    if ((!exists || info.st_size == 0) && artifacts.count > 0) return RCStorageFailure(error);
    hasCiphertext = hasCiphertext || artifacts.count > 0;
    // Refuse orphaned sidecars before key creation. They may be the only
    // remaining copy of encrypted data, never an invitation to create an empty DB.
    for (NSString *suffix in @[@"-wal", @"-shm", @"-journal"]) {
        NSString *sidecar = [path stringByAppendingString:suffix];
        struct stat side;
        if (lstat(sidecar.fileSystemRepresentation, &side) == 0) {
            if (!S_ISREG(side.st_mode) || side.st_uid != getuid() || side.st_nlink != 1) return RCStorageFailure(error);
            if ((!exists || info.st_size == 0) && side.st_size > 0) return RCStorageFailure(error);
        } else if (errno != ENOENT) return RCStorageFailure(error);
    }
    if (![[RCStorageCipher shared] prepareAllowingCreation:!hasCiphertext error:error]) return NO;
    NSData *key = [[RCStorageCipher shared] databaseKeyWithError:error];
    if (!key) return NO;
    if (!plaintext) return YES;
    return [self encryptPlaintextDatabase:path key:key error:error];
}

+ (BOOL)encryptPlaintextDatabase:(NSString *)path key:(NSData *)key error:(NSError **)error {
    NSString *stage = [path.stringByDeletingLastPathComponent stringByAppendingPathComponent:
        [NSString stringWithFormat:@".encrypted-%@.db", NSUUID.UUID.UUIDString]];
    int fd = open(stage.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return RCStorageFailure(error);
    close(fd);
    sqlite3 *source = NULL;
    sqlite3 *verified = NULL;
    sqlite3_stmt *attach = NULL;
    BOOL ok = NO;
    do {
        if (sqlite3_open_v2(path.fileSystemRepresentation, &source, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) break;
        // Flush any legacy WAL before exporting. No busy retry: another writer must close first.
        if (!RCExec(source, "PRAGMA temp_store=MEMORY; PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE; PRAGMA locking_mode=EXCLUSIVE; BEGIN EXCLUSIVE;")) break;
        NSString *version = RCScalar(source, "PRAGMA user_version");
        NSString *autoVacuum = RCScalar(source, "PRAGMA auto_vacuum");
        if (!version || ![RCScalar(source, "PRAGMA integrity_check") isEqualToString:@"ok"]) break;
        if (sqlite3_prepare_v2(source, "ATTACH DATABASE ? AS encrypted KEY ?", -1, &attach, NULL) != SQLITE_OK) break;
        sqlite3_bind_text(attach, 1, stage.fileSystemRepresentation, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(attach, 2, key.bytes, (int)key.length, SQLITE_TRANSIENT);
        if (sqlite3_step(attach) != SQLITE_DONE) break;
        sqlite3_finalize(attach); attach = NULL;
        NSString *vacuumPragma = [NSString stringWithFormat:@"PRAGMA encrypted.auto_vacuum=%lld", autoVacuum.longLongValue];
        if (!RCExec(source, vacuumPragma.UTF8String) || !RCExec(source, "SELECT sqlcipher_export('encrypted');")) break;
        NSString *pragma = [NSString stringWithFormat:@"PRAGMA encrypted.user_version=%lld", version.longLongValue];
        if (!RCExec(source, pragma.UTF8String) || !RCExec(source, "COMMIT; DETACH DATABASE encrypted;")) break;
        if (sqlite3_open_v2(stage.fileSystemRepresentation, &verified, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) break;
        if (sqlite3_key(verified, key.bytes, (int)key.length) != SQLITE_OK) break;
        if (![RCScalar(verified, "PRAGMA integrity_check") isEqualToString:@"ok"]) break;
        if (!RCTableContentsMatch(source, verified)) break;
        sqlite3_close(verified); verified = NULL;
        // locking_mode=EXCLUSIVE retains the source lock across COMMIT and until
        // close. Keep it through verification and replacement, so another writer
        // cannot commit data that was absent from the exported snapshot.
        fd = open(stage.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        if (fd < 0) break;
        BOOL synced = fsync(fd) == 0;
        close(fd);
        if (!synced || rename(stage.fileSystemRepresentation, path.fileSystemRepresentation) != 0) break;
        int parent = open(path.stringByDeletingLastPathComponent.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (parent < 0) break;
        BOOL directorySynced = fsync(parent) == 0;
        close(parent);
        if (!directorySynced) break;
        ok = YES;
    } while (NO);
    sqlite3_finalize(attach);
    if (verified) sqlite3_close(verified);
    if (source) { RCExec(source, "ROLLBACK;"); sqlite3_close(source); }
    if (!ok) [[NSFileManager defaultManager] removeItemAtPath:stage error:nil];
    return ok ? YES : RCStorageFailure(error);
}

+ (BOOL)migrateClipFilesBesideDatabase:(NSString *)path error:(NSError **)error {
    NSString *clips = [path.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"ClipsData"];
    if (![self validatePrivateDirectory:clips create:YES]) return RCStorageFailure(error);
    NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:clips error:error];
    if (!names) return NO;
    for (NSString *name in names) {
        if ([name hasPrefix:@"."]) continue;
        NSString *file = [clips stringByAppendingPathComponent:name];
        int fd = open(file.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0) return RCStorageFailure(error);
        unsigned char prefix[16];
        ssize_t length = read(fd, prefix, sizeof prefix);
        close(fd);
        if (length < 0) return RCStorageFailure(error);
        NSData *header = [NSData dataWithBytes:prefix length:(NSUInteger)length];
        BOOL encrypted = [RCStorageCipher isEncryptedData:header];
        BOOL knownLegacy = (length >= 8 && memcmp(prefix, "bplist00", 8) == 0)
            || (length >= 5 && memcmp(prefix, "<?xml", 5) == 0)
            || (length >= 3 && prefix[0] == 0xff && prefix[1] == 0xd8 && prefix[2] == 0xff)
            || (length >= 8 && memcmp(prefix, "\x89PNG\r\n\x1a\n", 8) == 0)
            || (length >= 4 && (memcmp(prefix, "II*\0", 4) == 0 || memcmp(prefix, "MM\0*", 4) == 0));
        // Corrupt ciphertext must not silently become a new plaintext payload.
        if (!encrypted && !knownLegacy) return RCStorageFailure(error);
        if (![[RCStorageCipher shared] migrateFileAtPath:file error:error]) return NO;
    }
    return YES;
}
@end
