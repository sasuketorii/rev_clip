#import "RCAgentSkillInstaller.h"
#import <CommonCrypto/CommonDigest.h>
#import <CoreFoundation/CoreFoundation.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/fat.h>
#import <sys/stat.h>
#import <sys/param.h>
#import <fcntl.h>
#import <dirent.h>
#import <unistd.h>
#import <errno.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

static NSString *const RCManaged = @".revclip-managed.json";
static const NSUInteger RCFileLimit = 8 * 1024 * 1024;
static const int RCDirectoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC;

static void RCConflict(NSString *reason) __attribute__((noreturn));
static void RCConflict(NSString *reason) {
    @throw [NSException exceptionWithName:@"RCAgentInstallerConflict" reason:reason userInfo:nil];
}
static void RCSystem(NSString *operation) __attribute__((noreturn));
static void RCSystem(NSString *operation) {
    int code = errno;
    @throw [NSException exceptionWithName:@"RCAgentInstallerConflict"
        reason:[NSString stringWithFormat:@"%@: %s",operation,strerror(code)] userInfo:@{@"errno":@(code)}];
}
static BOOL RCMissing(NSException *exception) { return [exception.userInfo[@"errno"] intValue] == ENOENT; }

// ARC closes all descriptors on normal returns and exception unwinding. This translation
// unit must use -fobjc-arc-exceptions as well as ARC (the CLI target owns these flags).
@interface RCAgentFD : NSObject
@property(nonatomic) int value;
+ (instancetype)take:(int)fd;
@end
@implementation RCAgentFD
+ (instancetype)take:(int)fd {
    if (fd < 0) RCSystem(@"open directory");
    RCAgentFD *result = [self new]; result.value = fd; return result;
}
- (void)dealloc { if (_value >= 0) close(_value); }
@end
static struct stat RCStat(int fd) {
    struct stat info;
    if (fstat(fd,&info) != 0) RCSystem(@"stat descriptor");
    return info;
}
static void RCPrivate(int fd) {
    struct stat info = RCStat(fd);
    if (info.st_uid != getuid() || (info.st_mode & 0022))
        RCConflict(@"configuration directory must be owned by this user and not writable by others");
}
static BOOL RCSameIdentity(struct stat a, struct stat b) { return a.st_dev == b.st_dev && a.st_ino == b.st_ino; }
static BOOL RCHas(int fd, NSString *name) {
    struct stat info;
    if (fstatat(fd,name.fileSystemRepresentation,&info,AT_SYMLINK_NOFOLLOW) == 0) return YES;
    if (errno == ENOENT) return NO;
    RCSystem(@"inspect directory entry");
}
static NSString *RCAbsolute(NSString *input, NSString *home) {
    if (![input isKindOfClass:NSString.class] || input.length == 0 || input.length > PATH_MAX ||
        [input rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
        RCConflict(@"invalid path");
    if ([input isEqual:@"~"]) input = home;
    else if ([input hasPrefix:@"~/"]) input = [home stringByAppendingPathComponent:[input substringFromIndex:2]];
    if (![input hasPrefix:@"/"]) RCConflict(@"root must be absolute, without parent traversal");
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *part in [input componentsSeparatedByString:@"/"]) {
        if ([part isEqual:@".."]) RCConflict(@"parent traversal is forbidden");
        if (part.length && ![part isEqual:@"."]) [parts addObject:part];
    }
    if (parts.count > 128) RCConflict(@"too many path components");
    return [@"/" stringByAppendingString:[parts componentsJoinedByString:@"/"]];
}
static BOOL RCDescendant(NSString *path, NSString *base) {
    return [path hasPrefix:[base stringByAppendingString:@"/"]];
}
static RCAgentFD *RCWalk(NSString *path, NSString *createBelow, BOOL source) {
    path = RCAbsolute(path,NSHomeDirectory());
    RCAgentFD *current = [RCAgentFD take:open("/",RCDirectoryFlags)];
    NSString *walked = @"";
    for (NSString *part in [path componentsSeparatedByString:@"/"]) {
        if (!part.length) continue;
        walked = [walked stringByAppendingFormat:@"/%@",part];
        if (createBelow && RCDescendant(walked,createBelow)) {
            if (mkdirat(current.value,part.fileSystemRepresentation,0700) != 0 && errno != EEXIST) RCSystem(@"create skills directory");
        }
        current = [RCAgentFD take:openat(current.value,part.fileSystemRepresentation,RCDirectoryFlags)];
        struct stat info = RCStat(current.value);
        // /Applications is conventionally root:admin 0775 on macOS. Allow that
        // one trusted source ancestor; destination traversal remains strict.
        BOOL applications = source && [walked isEqual:@"/Applications"] && info.st_uid == 0 && info.st_gid == 80 && !(info.st_mode & 0002);
        if ((info.st_mode & 0022) && !(info.st_mode & S_ISVTX) && !applications)
            RCConflict(@"unsafe writable parent directory");
    }
    return current;
}
static RCAgentFD *RCChild(int parent, NSString *name, BOOL private) {
    RCAgentFD *fd = [RCAgentFD take:openat(parent,name.fileSystemRepresentation,RCDirectoryFlags)];
    if (private) RCPrivate(fd.value);
    else if (RCStat(fd.value).st_mode & 0022) RCConflict(@"source directory is writable by others");
    return fd;
}
static NSSet<NSString *> *RCEntries(int parent, NSSet<NSString *> *allowed, BOOL complete) {
    int copy = openat(parent,".",RCDirectoryFlags);
    if (copy < 0) RCSystem(@"open directory listing");
    DIR *directory = fdopendir(copy);
    if (!directory) { close(copy); RCSystem(@"read directory"); }
    NSMutableSet *found = [NSMutableSet set];
    @try {
        struct dirent *entry;
        for (;;) {
            errno = 0; entry = readdir(directory);
            if (!entry) { if (errno) RCSystem(@"read directory entry"); break; }
            if (!strcmp(entry->d_name,".") || !strcmp(entry->d_name,"..")) continue;
            NSString *name = [[NSString alloc] initWithUTF8String:entry->d_name];
            if (!name || ![allowed containsObject:name] || found.count >= allowed.count)
                RCConflict(@"unmanaged entries in skill tree");
            [found addObject:name];
        }
        if (complete && ![found isEqualToSet:allowed]) RCConflict(@"incomplete skill tree");
        return found;
    } @finally { closedir(directory); }
}
@interface RCAgentFile : NSObject
@property(nonatomic,copy) NSData *data;
@property(nonatomic) NSUInteger mode;
@end
@implementation RCAgentFile
@end
static RCAgentFile *RCRead(int parent, NSString *name, NSUInteger limit) {
    int handle = openat(parent,name.fileSystemRepresentation,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (handle < 0) RCSystem(@"read file");
    @try {
        struct stat before = RCStat(handle);
        if (!S_ISREG(before.st_mode) || before.st_nlink != 1 || (before.st_mode & 06000))
            RCConflict(@"non-regular, hard-linked or set-id file");
        if (before.st_size < 0 || (uint64_t)before.st_size > limit) RCConflict(@"file exceeds size limit");
        NSMutableData *data = [NSMutableData dataWithCapacity:(NSUInteger)before.st_size];
        uint8_t buffer[16384];
        for (;;) {
            ssize_t count = read(handle,buffer,MIN(sizeof(buffer),limit + 1 - data.length));
            if (count < 0) { if (errno == EINTR) continue; RCSystem(@"read file contents"); }
            if (!count) break;
            [data appendBytes:buffer length:(NSUInteger)count];
            if (data.length > limit) RCConflict(@"file exceeds size limit");
        }
        struct stat after = RCStat(handle);
        if (!RCSameIdentity(before,after) || before.st_size != after.st_size || data.length != (NSUInteger)after.st_size ||
            before.st_mode != after.st_mode || after.st_nlink != 1 || before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec ||
            before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec || before.st_ctimespec.tv_sec != after.st_ctimespec.tv_sec ||
            before.st_ctimespec.tv_nsec != after.st_ctimespec.tv_nsec) RCConflict(@"file changed while reading");
        RCAgentFile *file = [RCAgentFile new]; file.data = data; file.mode = after.st_mode & 07777; return file;
    } @finally { close(handle); }
}
static NSString *RCHash(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    char result[CC_SHA256_DIGEST_LENGTH*2+1];
    static const char hex[] = "0123456789abcdef";
    for (NSUInteger i=0;i<sizeof(digest);i++) { result[2*i]=hex[digest[i]>>4]; result[2*i+1]=hex[digest[i]&15]; }
    result[sizeof(result)-1]=0; return [NSString stringWithUTF8String:result];
}

// Foundation JSON accepts duplicate keys. Validate the bounded grammar first,
// decoding escaped object keys before duplicate comparison. Manifest integers must
// be literal integers, never 1.0/1e0 or booleans masquerading as NSNumber integers.
@interface RCAgentJSONGuard : NSObject
@property(nonatomic,copy) NSString *text;
@property(nonatomic) NSUInteger offset;
@property(nonatomic) NSUInteger tokens;
- (void)value:(NSUInteger)depth;
- (void)space;
- (BOOL)take:(unichar)c;
- (NSString *)string;
@end
@implementation RCAgentJSONGuard
- (void)space { while (_offset < _text.length && [@" \t\r\n" rangeOfString:[_text substringWithRange:NSMakeRange(_offset,1)]].location != NSNotFound) _offset++; }
- (BOOL)take:(unichar)c { [self space]; if (_offset < _text.length && [_text characterAtIndex:_offset]==c) { _offset++; return YES; } return NO; }
- (NSString *)string {
    [self space]; NSUInteger begin=_offset;
    if (![self take:'"']) RCConflict(@"malformed JSON string");
    BOOL escaped=NO, ended=NO;
    while (_offset < _text.length) {
        unichar c=[_text characterAtIndex:_offset++];
        if (!escaped && c=='"') { ended=YES; break; }
        if (!escaped && c=='\\') escaped=YES; else escaped=NO;
    }
    if (!ended) RCConflict(@"unterminated JSON string");
    NSString *literal=[_text substringWithRange:NSMakeRange(begin,_offset-begin)];
    NSData *wrapped=[[NSString stringWithFormat:@"[%@]",literal] dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *result=[NSJSONSerialization JSONObjectWithData:wrapped options:0 error:NULL];
    if (![result isKindOfClass:NSArray.class] || result.count!=1 || ![result[0] isKindOfClass:NSString.class]) RCConflict(@"invalid JSON string");
    return result[0];
}
- (void)value:(NSUInteger)depth {
    if (depth>16 || ++_tokens>4096) RCConflict(@"JSON complexity limit exceeded");
    [self space]; if (_offset>=_text.length) RCConflict(@"missing JSON value");
    unichar c=[_text characterAtIndex:_offset];
    if (c=='{') {
        _offset++; NSMutableSet *keys=[NSMutableSet set];
        if ([self take:'}']) return;
        do {
            NSString *key=[self string];
            if ([keys containsObject:key]) RCConflict(@"duplicate JSON key");
            [keys addObject:key];
            if (![self take:':']) RCConflict(@"missing JSON colon");
            [self value:depth+1];
            if ([self take:'}']) return;
        } while ([self take:',']);
        RCConflict(@"malformed JSON object");
    }
    if (c=='[') {
        _offset++; if ([self take:']']) return;
        do { [self value:depth+1]; if ([self take:']']) return; } while ([self take:',']);
        RCConflict(@"malformed JSON array");
    }
    if (c=='"') { [self string]; return; }
    NSUInteger start=_offset;
    while (_offset<_text.length && [@" \r\n\t,]}" rangeOfString:[_text substringWithRange:NSMakeRange(_offset,1)]].location==NSNotFound) _offset++;
    NSString *token=[_text substringWithRange:NSMakeRange(start,_offset-start)];
    if ([@[@"true",@"false",@"null"] containsObject:token]) return;
    if ([token rangeOfString:@"\\A-?(?:0|[1-9][0-9]*)\\z" options:NSRegularExpressionSearch].location==NSNotFound)
        RCConflict(@"JSON numbers must be integers");
}
@end
static id RCJSON(NSData *data, NSUInteger limit) {
    if (data.length>limit) RCConflict(@"JSON size limit exceeded");
    NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) RCConflict(@"JSON is not UTF-8");
    RCAgentJSONGuard *guard=[RCAgentJSONGuard new]; guard.text=text; [guard value:0]; [guard space];
    if (guard.offset!=text.length) RCConflict(@"trailing JSON data");
    id result=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (!result) RCConflict(@"malformed JSON"); return result;
}
static BOOL RCInteger(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID() &&
        strcmp([value objCType],@encode(double)) && strcmp([value objCType],@encode(float));
}
static NSDictionary *RCManifest(NSDictionary<NSString *,RCAgentFile *> *payload) {
    NSMutableDictionary *files=[NSMutableDictionary dictionary];
    for (NSString *key in payload) files[key]=@{@"sha256":RCHash(payload[key].data),@"mode":@(payload[key].mode)};
    return @{@"schema_version":@1,@"managed_by":@"revclip-agent-support",@"files":files};
}
static NSDictionary<NSString *,RCAgentFile *> *RCBundle(int fd, BOOL managed) {
    BOOL agents=!managed || RCHas(fd,@"agents");
    NSMutableSet *expected=[NSMutableSet setWithArray:@[@"SKILL.md",@"scripts"]];
    if (agents) [expected addObject:@"agents"];
    if (managed) [expected addObject:RCManaged];
    RCEntries(fd,expected,YES);
    NSMutableDictionary *payload=[NSMutableDictionary dictionary];
    payload[@"SKILL.md"]=RCRead(fd,@"SKILL.md",RCFileLimit);
    RCAgentFD *scripts=RCChild(fd,@"scripts",managed);
    RCEntries(scripts.value,[NSSet setWithObject:@"revclip"],YES);
    payload[@"scripts/revclip"]=RCRead(scripts.value,@"revclip",RCFileLimit);
    if (agents) {
        RCAgentFD *agent=RCChild(fd,@"agents",managed);
        RCEntries(agent.value,[NSSet setWithObject:@"openai.yaml"],YES);
        payload[@"agents/openai.yaml"]=RCRead(agent.value,@"openai.yaml",RCFileLimit);
    }
    return payload;
}
@interface RCAgentSnapshot : NSObject
@property(nonatomic,copy) NSDictionary *manifest;
@property(nonatomic) struct stat identity;
@end
@implementation RCAgentSnapshot
@end
static RCAgentSnapshot *RCExisting(int parent, NSString *name) {
    if (!RCHas(parent,name)) return nil;
    @try {
        RCAgentFD *directory=RCChild(parent,name,YES);
        NSDictionary *payload=RCBundle(directory.value,YES);
        RCAgentFile *manifestFile=RCRead(directory.value,RCManaged,4096);
        id record=RCJSON(manifestFile.data,4096);
        if (![record isKindOfClass:NSDictionary.class] || !RCInteger(record[@"schema_version"]) ||
            ![record[@"files"] isKindOfClass:NSDictionary.class]) RCConflict(@"malformed management manifest");
        for (id info in [record[@"files"] allValues])
            if (![info isKindOfClass:NSDictionary.class] || !RCInteger(info[@"mode"])) RCConflict(@"malformed manifest mode");
        if (manifestFile.mode!=0644 || ![record isEqual:RCManifest(payload)]) RCConflict(@"unmanaged or edited skill tree");
        RCAgentSnapshot *snapshot=[RCAgentSnapshot new]; snapshot.manifest=record; snapshot.identity=RCStat(directory.value); return snapshot;
    } @catch (NSException *exception) {
        if (RCMissing(exception)) RCConflict(@"incomplete or unmanaged skill tree");
        @throw;
    }
}
static BOOL RCSameSnapshot(RCAgentSnapshot *a, RCAgentSnapshot *b) {
    return (!a && !b) || (a && b && RCSameIdentity(a.identity,b.identity) && [a.manifest isEqual:b.manifest]);
}
static void RCWrite(int parent, NSString *name, NSData *data, mode_t mode) {
    int fd=openat(parent,name.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,mode);
    if (fd<0) RCSystem(@"create staged file");
    @try {
        if (fchmod(fd,mode)!=0) RCSystem(@"set file mode");
        const uint8_t *bytes=data.bytes; NSUInteger offset=0;
        while (offset<data.length) {
            ssize_t count=write(fd,bytes+offset,data.length-offset);
            if (count<0 && errno==EINTR) continue;
            if (count<=0) RCSystem(@"write staged file");
            offset+=(NSUInteger)count;
        }
        if (fsync(fd)!=0) RCSystem(@"sync staged file");
    } @finally { close(fd); }
}
static void RCRename(int parent, NSString *from, NSString *to) {
    if (renameatx_np(parent,from.fileSystemRepresentation,parent,to.fileSystemRepresentation,RENAME_EXCL)!=0) RCSystem(@"rename skill directory without replacement");
}
static void RCUnlink(int parent, NSString *name, BOOL directory) {
    if (unlinkat(parent,name.fileSystemRepresentation,directory ? AT_REMOVEDIR : 0)!=0) RCSystem(@"remove owned staging entry");
}
// Cleanup only a known inode in a private parent, and only the finite installer shape.
// Unknown entries/symlinks are retained and reported, never recursively removed.
static void RCRemove(int parent, NSString *name, struct stat identity, BOOL partial) {
    RCAgentFD *fd=RCChild(parent,name,YES);
    if (!RCSameIdentity(RCStat(fd.value),identity)) RCConflict(@"recovery directory identity changed");
    NSSet *top=RCEntries(fd.value,[NSSet setWithArray:@[@"SKILL.md",@"scripts",@"agents",RCManaged]],NO);
    if (!partial) (void)RCExisting(parent,name);
    for (NSString *sub in @[@"scripts",@"agents"]) {
        if (![top containsObject:sub]) continue;
        RCAgentFD *child=RCChild(fd.value,sub,YES);
        NSString *leaf=[sub isEqual:@"scripts"] ? @"revclip" : @"openai.yaml";
        NSSet *entries=RCEntries(child.value,[NSSet setWithObject:leaf],!partial);
        if ([entries containsObject:leaf]) { (void)RCRead(child.value,leaf,RCFileLimit); RCUnlink(child.value,leaf,NO); }
        RCUnlink(fd.value,sub,YES);
    }
    for (NSString *leaf in @[@"SKILL.md",RCManaged]) if ([top containsObject:leaf]) {
        (void)RCRead(fd.value,leaf,RCFileLimit); RCUnlink(fd.value,leaf,NO);
    }
    struct stat current;
    if (fstatat(parent,name.fileSystemRepresentation,&current,AT_SYMLINK_NOFOLLOW)!=0) RCSystem(@"verify cleanup identity");
    if (!RCSameIdentity(identity,current)) RCConflict(@"recovery directory moved during cleanup");
    RCUnlink(parent,name,YES);
}

static NSString *RCInstall(NSString *root, NSString *boundary, NSDictionary<NSString *,RCAgentFile *> *payload, NSDictionary *desired) {
    RCAgentFD *parent=RCWalk(root,boundary,NO); RCPrivate(parent.value);
    NSString *lock=@".revclip-install.lock";
    if (mkdirat(parent.value,lock.fileSystemRepresentation,0700)!=0) {
        if (errno==EEXIST) RCConflict(@"installer lock exists; concurrent or interrupted install");
        RCSystem(@"create installer lock");
    }
    RCAgentFD *lockFD=nil;
    NSString *suffix=NSUUID.UUID.UUIDString.lowercaseString;
    NSString *stage=[@".revclip-stage-" stringByAppendingString:suffix];
    NSString *backup=[@".revclip-backup-" stringByAppendingString:suffix];
    BOOL staged=NO, backed=NO, published=NO, committed=NO;
    struct stat stageIdentity={0};
    RCAgentSnapshot *before=nil;
    NSException *failure=nil;
    NSString *action=nil;
    @try {
        lockFD=RCChild(parent.value,lock,YES);
        before=RCExisting(parent.value,@"revclip");
        if ([before.manifest isEqual:desired]) action=@"unchanged";
        else {
            if (mkdirat(parent.value,stage.fileSystemRepresentation,0700)!=0) RCSystem(@"create private staging directory");
            staged=YES;
            RCAgentFD *fd=RCChild(parent.value,stage,YES); stageIdentity=RCStat(fd.value);
            for (NSString *sub in @[@"scripts",@"agents"]) {
                if (mkdirat(fd.value,sub.fileSystemRepresentation,0700)!=0) RCSystem(@"create staged subdirectory");
                RCAgentFD *child=RCChild(fd.value,sub,YES);
                NSString *leaf=[sub isEqual:@"scripts"] ? @"revclip" : @"openai.yaml";
                RCAgentFile *file=payload[[sub stringByAppendingPathComponent:leaf]];
                RCWrite(child.value,leaf,file.data,(mode_t)file.mode);
                if (fsync(child.value)!=0) RCSystem(@"sync staged subdirectory");
            }
            RCWrite(fd.value,@"SKILL.md",payload[@"SKILL.md"].data,0644);
            NSData *record=[NSJSONSerialization dataWithJSONObject:desired options:NSJSONWritingSortedKeys error:NULL];
            if (!record || record.length>4096) RCConflict(@"cannot serialize management manifest");
            RCWrite(fd.value,RCManaged,record,0644);
            if (fsync(fd.value)!=0) RCSystem(@"sync staged directory");
            RCAgentSnapshot *ready=RCExisting(parent.value,stage);
            if (!ready || !RCSameIdentity(ready.identity,stageIdentity) || ![ready.manifest isEqual:desired]) RCConflict(@"staging readback mismatch");
            if (!RCSameSnapshot(before,RCExisting(parent.value,@"revclip"))) RCConflict(@"destination changed during staging");
            if (before) {
                RCRename(parent.value,@"revclip",backup); backed=YES;
                if (!RCSameSnapshot(before,RCExisting(parent.value,backup))) RCConflict(@"destination changed before backup");
            }
            RCRename(parent.value,stage,@"revclip"); staged=NO; published=YES;
            RCAgentSnapshot *after=RCExisting(parent.value,@"revclip");
            if (!after || !RCSameIdentity(after.identity,stageIdentity) || ![after.manifest isEqual:desired]) RCConflict(@"installed readback mismatch");
            if (fsync(parent.value)!=0) RCSystem(@"sync published skill");
            committed=YES;
            if (backed) {
                if (!RCSameSnapshot(before,RCExisting(parent.value,backup))) RCConflict(@"backup changed; recovery copy retained");
                RCRemove(parent.value,backup,before.identity,NO); backed=NO;
            }
            action=before ? @"updated" : @"installed";
        }
    } @catch (NSException *exception) {
        failure=exception;
        if (!committed) {
            @try {
                if (published) {
                    struct stat current;
                    if (fstatat(parent.value,"revclip",&current,AT_SYMLINK_NOFOLLOW)!=0 || !RCSameIdentity(current,stageIdentity))
                        RCConflict(@"published directory changed; refusing destructive rollback");
                    RCRename(parent.value,@"revclip",stage); staged=YES; published=NO;
                }
                if (backed) {
                    RCRename(parent.value,backup,@"revclip"); backed=NO;
                }
            } @catch (NSException *rollback) {
                failure=[NSException exceptionWithName:@"RCAgentInstallerConflict"
                    reason:[NSString stringWithFormat:@"%@; rollback failed: %@; recovery directory: %@",exception.reason,rollback.reason,backup] userInfo:nil];
            }
        }
    }
    // Errors in cleanup are surfaced, including after a successful publication.
    @try {
        if (staged) RCRemove(parent.value,stage,stageIdentity,YES);
    } @catch (NSException *cleanup) {
        failure=[NSException exceptionWithName:@"RCAgentInstallerConflict"
            reason:[NSString stringWithFormat:@"%@; staging retained at %@: %@",failure.reason ?: @"cleanup failed",stage,cleanup.reason] userInfo:nil];
    }
    @try {
        if (!lockFD) RCConflict(@"cannot prove ownership of installer lock");
        struct stat named;
        if (fstatat(parent.value,lock.fileSystemRepresentation,&named,AT_SYMLINK_NOFOLLOW)!=0 || !RCSameIdentity(named,RCStat(lockFD.value)))
            RCConflict(@"installer lock identity changed; lock retained");
        RCEntries(lockFD.value,[NSSet set],YES); RCUnlink(parent.value,lock,YES);
    } @catch (NSException *cleanup) {
        failure=[NSException exceptionWithName:@"RCAgentInstallerConflict"
            reason:[NSString stringWithFormat:@"%@; %@",failure.reason ?: @"cleanup failed",cleanup.reason] userInfo:nil];
    }
    if (failure && backed) {
        failure=[NSException exceptionWithName:@"RCAgentInstallerConflict"
            reason:[NSString stringWithFormat:@"%@; retained recovery directory: %@",failure.reason,backup] userInfo:nil];
    }
    if (failure) @throw failure;
    return action;
}

static NSString *RCExecutable(void) {
    uint32_t size=PATH_MAX;
    char path[PATH_MAX];
    if (_NSGetExecutablePath(path,&size)!=0) RCConflict(@"executable path exceeds size limit");
    // Resolve only our already executing image, not a user-supplied source/destination.
    char actual[PATH_MAX];
    if (!realpath(path,actual)) RCSystem(@"resolve executing native CLI");
    NSString *result=[[NSString alloc] initWithUTF8String:actual];
    if (!result) RCConflict(@"invalid executable path encoding"); return result;
}
static RCAgentFile *RCNativeFile(NSString *path) {
    RCAgentFD *parent=RCWalk([path stringByDeletingLastPathComponent],nil,YES);
    RCAgentFile *file=RCRead(parent.value,path.lastPathComponent,RCFileLimit);
    if (!(file.mode & 0111) || (file.mode & 0022) || file.data.length<sizeof(uint32_t)) RCConflict(@"source CLI must be a non-writable native executable");
    uint32_t magic; memcpy(&magic,file.data.bytes,sizeof(magic));
    if (magic!=MH_MAGIC && magic!=MH_CIGAM && magic!=MH_MAGIC_64 && magic!=MH_CIGAM_64 &&
        magic!=FAT_MAGIC && magic!=FAT_CIGAM && magic!=FAT_MAGIC_64 && magic!=FAT_CIGAM_64)
        RCConflict(@"source CLI is not Mach-O; interpreter scripts are forbidden");
    file.mode=0755; return file;
}
static NSDictionary *RCSourceLocation(NSString *source, NSString *app, NSString *home) {
    NSString *executable=RCExecutable();
    if (source) {
        NSString *support=RCAbsolute(source,home);
        if ([support.lastPathComponent isEqual:@"revclip"]) support=[support stringByDeletingLastPathComponent];
        // A fixtures directory has no app sibling: use the executing native test CLI.
        NSString *resources=[support stringByDeletingLastPathComponent];
        NSString *contents=[resources stringByDeletingLastPathComponent];
        NSString *binary=executable;
        if ([resources.lastPathComponent isEqual:@"Resources"] && [contents.lastPathComponent isEqual:@"Contents"])
            binary=[contents stringByAppendingPathComponent:@"Helpers/revclip"];
        return @{@"support":support,@"binary":binary};
    }
    NSMutableArray<NSString *> *apps=[NSMutableArray array];
    NSString *helpers=[executable stringByDeletingLastPathComponent];
    NSString *contents=[helpers stringByDeletingLastPathComponent];
    NSString *enclosing=[contents stringByDeletingLastPathComponent];
    NSString *bundleName=[app stringByAppendingString:@".app"];
    if ([helpers.lastPathComponent isEqual:@"Helpers"] && [contents.lastPathComponent isEqual:@"Contents"] && [enclosing.lastPathComponent isEqual:bundleName])
        [apps addObject:enclosing];
    [apps addObject:[@"/Applications" stringByAppendingPathComponent:bundleName]];
    [apps addObject:[[home stringByAppendingPathComponent:@"Applications"] stringByAppendingPathComponent:bundleName]];
    for (NSString *candidate in apps) {
        @try {
            RCAgentFD *fd=RCWalk(candidate,nil,YES); (void)fd;
            return @{@"support":[candidate stringByAppendingPathComponent:@"Contents/Resources/AgentSupport"],
                     @"binary":[candidate stringByAppendingPathComponent:@"Contents/Helpers/revclip"]};
        } @catch (NSException *exception) { if (!RCMissing(exception)) @throw; }
    }
    RCConflict(@"selected app bundle is absent; use --source for an explicit test bundle");
}
static NSArray<NSDictionary *> *RCProviders(int fd) {
    RCAgentFile *file=RCRead(fd,@"providers.json",65536);
    if (file.mode & 0022) RCConflict(@"provider registry is writable by others");
    id record=RCJSON(file.data,65536);
    if (![record isKindOfClass:NSDictionary.class] || !RCInteger(record[@"schema_version"]) || [record[@"schema_version"] integerValue]!=1 ||
        ![record[@"providers"] isKindOfClass:NSArray.class] || [record[@"providers"] count]>64) RCConflict(@"invalid provider registry");
    NSArray *providers=record[@"providers"];
    NSMutableSet *identifiers=[NSMutableSet set];
    for (id p in providers) {
        if (![p isKindOfClass:NSDictionary.class]) RCConflict(@"invalid provider entry");
        for (NSString *key in @[@"id",@"name",@"base",@"reload"])
            if (![p[key] isKindOfClass:NSString.class] || ![p[key] length] || [p[key] length]>PATH_MAX) RCConflict(@"invalid provider field");
        NSString *identifier=p[@"id"];
        if ([identifier rangeOfString:@"\\A[a-z0-9-]{1,64}\\z" options:NSRegularExpressionSearch].location==NSNotFound || [identifiers containsObject:identifier]) RCConflict(@"invalid or duplicate provider id");
        [identifiers addObject:identifier];
        NSString *skills=p[@"skills"] ?: @"skills";
        if (![skills isKindOfClass:NSString.class] || [skills rangeOfString:@"\\A[a-zA-Z0-9_-]{1,64}\\z" options:NSRegularExpressionSearch].location==NSNotFound) RCConflict(@"invalid provider skills directory");
        if (p[@"env"] && (![p[@"env"] isKindOfClass:NSString.class] || [p[@"env"] rangeOfString:@"\\A[A-Z][A-Z0-9_]{0,63}\\z" options:NSRegularExpressionSearch].location==NSNotFound)) RCConflict(@"invalid provider environment key");
        for (NSString *key in @[@"supported",@"experimental",@"env_is_home_parent"]) {
            id value=p[key];
            if (value && (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID())) RCConflict(@"invalid provider boolean");
        }
        if (![p[@"sources"] isKindOfClass:NSArray.class] || [p[@"sources"] count]>16) RCConflict(@"invalid provider sources");
        for (id value in p[@"sources"]) if (![value isKindOfClass:NSString.class] || [value length]>4096) RCConflict(@"invalid provider source URL");
    }
    return providers;
}
static NSDictionary<NSString *,RCAgentFile *> *RCSourcePayload(int support, NSString *binary) {
    RCAgentFD *skill=RCChild(support,@"revclip",NO);
    NSMutableDictionary<NSString *,RCAgentFile *> *payload=[RCBundle(skill.value,NO) mutableCopy];
    for (NSString *name in payload) {
        if (payload[name].mode & 0022) RCConflict(@"source skill file is writable by others");
        payload[name].mode=[name isEqual:@"scripts/revclip"] ? 0755 : 0644;
    }
    payload[@"scripts/revclip"]=RCNativeFile(binary);
    return payload;
}
static void RCUpdateRow(NSMutableDictionary *row, RCAgentSnapshot *existing, NSDictionary *desired) {
    row[@"manifest_verified"]=@(existing!=nil);
    if (!existing) { row[@"state"]=@"missing"; row[@"update_available"]=@NO; return; }
    row[@"manifest"]=existing.manifest;
    BOOL current=desired && [existing.manifest isEqual:desired];
    row[@"state"]=current ? @"current" : @"managed";
    row[@"update_available"]=desired ? @(!current) : (id)NSNull.null;
}
static NSDictionary *RCRun(NSString *command, NSString *app, NSString *home, NSString *source, NSSet *selected) {
    NSDictionary *location=RCSourceLocation(source,app,home);
    RCAgentFD *support=RCWalk(location[@"support"],nil,YES);
    NSArray<NSDictionary *> *providers=RCProviders(support.value);
    NSMutableSet *known=[NSMutableSet set];
    for (NSDictionary *p in providers) [known addObject:p[@"id"]];
    if (![selected isSubsetOfSet:known]) {
        @throw [NSException exceptionWithName:@"RCAgentInstallerUsage" reason:@"unknown --provider id" userInfo:nil];
    }
    NSDictionary *payload=nil, *desired=nil;
    NSString *sourceError=nil;
    @try { payload=RCSourcePayload(support.value,location[@"binary"]); desired=RCManifest(payload); }
    @catch (NSException *exception) { sourceError=exception.reason ?: @"source bundle invalid"; }
    NSMutableArray *rows=[NSMutableArray array];
    NSDictionary *environment=NSProcessInfo.processInfo.environment;
    BOOL failed=NO;
    for (NSDictionary *provider in providers) {
        if (selected.count && ![selected containsObject:provider[@"id"]]) continue;
        NSMutableDictionary *row=[@{@"id":provider[@"id"],@"name":provider[@"name"],@"detected":@NO,
            @"path":NSNull.null,@"state":@"missing",@"action":@"skipped",@"update_available":@NO,@"manifest_verified":@NO,
            @"experimental":provider[@"experimental"] ?: @NO,@"sources":provider[@"sources"],@"reload":provider[@"reload"]} mutableCopy];
        [rows addObject:row];
        NSString *root=nil;
        @try {
            NSString *override=provider[@"env"] ? environment[provider[@"env"]] : nil;
            if (!override.length) override=nil;
            NSString *base=RCAbsolute(override ?: provider[@"base"],home);
            if (override && [provider[@"env_is_home_parent"] boolValue]) base=[base stringByAppendingPathComponent:@".gemini"];
            root=[provider[@"id"] isEqual:@"codex"] && !override ? [home stringByAppendingPathComponent:@".agents/skills"] : [base stringByAppendingPathComponent:provider[@"skills"] ?: @"skills"];
            row[@"path"]=[root stringByAppendingPathComponent:@"revclip"];
            RCAgentFD *baseFD=nil;
            @try { baseFD=RCWalk(base,nil,NO); row[@"detected"]=@YES; RCPrivate(baseFD.value); }
            @catch (NSException *exception) {
                if (RCMissing(exception)) { row[@"reason"]=@"configuration base absent"; continue; }
                @throw;
            }
            if (provider[@"supported"] && ![provider[@"supported"] boolValue]) {
                row[@"state"]=@"unsupported"; row[@"reason"]=@"flat Markdown CLI; bundle support unverified"; continue;
            }
            RCAgentSnapshot *record=nil;
            @try { RCAgentFD *parent=RCWalk(root,nil,NO); RCPrivate(parent.value); record=RCExisting(parent.value,@"revclip"); }
            @catch (NSException *exception) { if (!RCMissing(exception)) @throw; }
            RCUpdateRow(row,record,desired); row[@"action"]=@"none";
            if ([command isEqual:@"install"]) {
                if (sourceError) RCConflict([@"source bundle invalid: " stringByAppendingString:sourceError]);
                // Repeat the existing-product gate immediately before mkdir; do not create detection bases.
                RCAgentFD *gate=RCWalk(base,nil,NO); RCPrivate(gate.value);
                if (!RCSameIdentity(RCStat(baseFD.value),RCStat(gate.value))) RCConflict(@"configuration base changed");
                NSString *boundary=RCDescendant(root,base) ? base : home;
                row[@"action"]=RCInstall(root,boundary,payload,desired);
                RCAgentFD *parent=RCWalk(root,nil,NO); RCPrivate(parent.value);
                RCAgentSnapshot *after=RCExisting(parent.value,@"revclip");
                if (![after.manifest isEqual:desired]) RCConflict(@"final installed readback mismatch");
                RCUpdateRow(row,after,desired);
            }
        } @catch (NSException *exception) {
            row[@"state"]=@"conflict"; row[@"action"]=@"failed";
            row[@"reason"]=exception.reason ?: @"installer conflict"; failed=YES;
            row[@"manifest_verified"]=@NO; [row removeObjectForKey:@"manifest"]; row[@"update_available"]=NSNull.null;
            // A cleanup failure does not misreport an already verified publication as missing.
            if ([command isEqual:@"install"] && [row[@"detected"] boolValue] && root) {
                @try {
                    RCAgentFD *parent=RCWalk(root,nil,NO); RCPrivate(parent.value);
                    RCAgentSnapshot *record=RCExisting(parent.value,@"revclip");
                    if (record) RCUpdateRow(row,record,desired);
                } @catch (__unused NSException *ignored) { }
            }
        }
    }
    BOOL ok=!failed && !([command isEqual:@"install"] && sourceError);
    return @{@"schema_version":@1,@"command":command,@"app":app,@"skill":@"revclip",@"providers":rows,
        @"source_error":sourceError ?: (id)NSNull.null,@"ok":@(ok)};
}

@implementation RCAgentSkillInstaller
+ (int)runArguments:(NSArray<NSString *> *)arguments {
    @autoreleasepool {
        NSDictionary *report;
        int status=1;
        @try {
            if (![arguments isKindOfClass:NSArray.class] || arguments.count<1 || arguments.count>128 ||
                ![@[@"inspect",@"install"] containsObject:arguments.firstObject]) {
                @throw [NSException exceptionWithName:@"RCAgentInstallerUsage" reason:@"expected inspect or install" userInfo:nil];
            }
            NSString *command=arguments.firstObject;
            NSMutableDictionary *options=[NSMutableDictionary dictionary];
            NSMutableSet *providers=[NSMutableSet set];
            for (NSUInteger i=1;i<arguments.count;i++) {
                NSString *flag=arguments[i], *value=nil;
                if (![flag isKindOfClass:NSString.class]) RCConflict(@"arguments must be strings");
                NSRange equal=[flag rangeOfString:@"="];
                if (equal.location!=NSNotFound) { value=[flag substringFromIndex:NSMaxRange(equal)]; flag=[flag substringToIndex:equal.location]; }
                if (![@[@"--app",@"--home",@"--source",@"--provider"] containsObject:flag] || (!value && i+1>=arguments.count)) {
                    @throw [NSException exceptionWithName:@"RCAgentInstallerUsage" reason:@"unknown option or missing option value" userInfo:nil];
                }
                if (!value) value=arguments[++i];
                if (![value isKindOfClass:NSString.class] || !value.length || value.length>PATH_MAX) {
                    @throw [NSException exceptionWithName:@"RCAgentInstallerUsage" reason:@"invalid option value" userInfo:nil];
                }
                if ([flag isEqual:@"--provider"]) {
                    for (NSString *identifier in [value componentsSeparatedByString:@","]) {
                        if (!identifier.length) @throw [NSException exceptionWithName:@"RCAgentInstallerUsage" reason:@"empty provider id" userInfo:nil];
                        [providers addObject:identifier];
                    }
                } else {
                    if (options[flag]) @throw [NSException exceptionWithName:@"RCAgentInstallerUsage" reason:@"duplicate option" userInfo:nil];
                    options[flag]=value;
                }
            }
            NSString *app=options[@"--app"] ?: @"Revclip";
            if (![@[@"Revclip",@"revclip-demo"] containsObject:app])
                @throw [NSException exceptionWithName:@"RCAgentInstallerUsage" reason:@"--app must be Revclip or revclip-demo" userInfo:nil];
            NSString *home=RCAbsolute(options[@"--home"] ?: NSHomeDirectory(),NSHomeDirectory());
            report=RCRun(command,app,home,options[@"--source"],providers);
            status=[report[@"ok"] boolValue] ? 0 : 1;
        } @catch (NSException *exception) {
            status=[exception.name isEqual:@"RCAgentInstallerUsage"] ? 2 : 1;
            report=@{@"schema_version":@1,@"ok":@NO,@"error":exception.reason ?: @"native installer failed",@"providers":@[]};
        }
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:NULL];
        if (!json || json.length>=1024*1024) {
            const char *message="{\"schema_version\":1,\"ok\":false,\"error\":\"report serialization failed\",\"providers\":[]}\n";
            (void)fwrite(message,1,strlen(message),stdout); return 1;
        }
        if (fwrite(json.bytes,1,json.length,stdout)!=json.length || fputc('\n',stdout)==EOF || fflush(stdout)!=0) return 1;
        return status;
    }
}
@end
