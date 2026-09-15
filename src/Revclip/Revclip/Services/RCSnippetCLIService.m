#import "RCSnippetCLIService.h"
#import "RCDatabaseManager.h"
#import "RCSnippetMedia.h"
#import "RCSnippetEditorWindowController.h"
#import "RCConstants.h"
#import "RCUtilities.h"
#import "RCHotKeyService.h"
#import <sys/socket.h>
#import <arpa/inet.h>
#import <sys/un.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <poll.h>
#import <unistd.h>
#import <errno.h>

static const NSUInteger RCRequestLimit = 16 * 1024 * 1024;
static NSDictionary *RCFailure(NSString *message) { return @{@"ok":@NO,@"error":message}; }
static NSDictionary *RCSuccess(id result) { return @{@"ok":@YES,@"result":result}; }
static BOOL RCString(id value) { return [value isKindOfClass:NSString.class]; }
static NSDictionary *RCJSONSnippet(NSDictionary *snippet) {
    NSMutableDictionary *result = [snippet mutableCopy];
    NSData *media = result[@"media_data"];
    [result removeObjectForKey:@"media_data"];
    result[@"media_bytes"] = @(media.length);
    return result;
}
// Deadline covers the whole transfer, including clients sending one byte at a time.
static BOOL RCTransfer(int fd, void *bytes, size_t length, BOOL writing) {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 5;
    while (length) {
        int remaining = (int)((deadline - NSProcessInfo.processInfo.systemUptime) * 1000);
        if (remaining <= 0) return NO;
        struct pollfd pollFD = {fd, writing ? POLLOUT : POLLIN, 0};
        int ready = poll(&pollFD, 1, remaining);
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0) return NO;
        ssize_t count = writing ? send(fd, bytes, length, 0) : recv(fd, bytes, length, 0);
        if (count < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (count <= 0) return NO;
        bytes = (char *)bytes + count; length -= (size_t)count;
    }
    return YES;
}
@interface RCSnippetCLIService ()
@property RCDatabaseManager *database;
@property dispatch_source_t listener;
@property NSString *socketPath;
@property int lockFD;
@end
@implementation RCSnippetCLIService
+ (instancetype)shared {
    static RCSnippetCLIService *service; static dispatch_once_t once;
    dispatch_once(&once, ^{ service = [[self alloc] initWithDatabase:RCDatabaseManager.shared]; });
    return service;
}
- (instancetype)initWithDatabase:(RCDatabaseManager *)database {
    if ((self = [super init])) { _database = database; _lockFD = -1; }
    return self;
}
- (NSDictionary *)executeRequest:(NSDictionary *)request {
    if (![request isKindOfClass:NSDictionary.class]) return RCFailure(@"Expected JSON object");
    NSString *operation = request[@"op"];
    if (!RCString(operation)) return RCFailure(@"Missing op");
    NSSet *operations = [NSSet setWithArray:@[@"folders",@"folder-create",@"folder-delete",@"list",@"get",@"create",@"update",@"delete"]];
    if (![operations containsObject:operation]) return RCFailure(@"Unknown operation");
    NSSet *keys = [NSSet setWithArray:@[@"op",@"id",@"folder",@"title",@"content",@"image_base64",@"enabled"]];
    for (NSString *key in request) {
        if (![keys containsObject:key]) return RCFailure(@"Unknown field");
        if (![key isEqual:@"enabled"] && !RCString(request[key])) return RCFailure(@"Fields must be strings");
    }
    if (request[@"enabled"] && (! [request[@"enabled"] isKindOfClass:NSNumber.class] ||
        ![@[@0,@1] containsObject:request[@"enabled"]])) return RCFailure(@"enabled must be boolean");
    if (request[@"title"] && ([request[@"title"] length] == 0 || [request[@"title"] length] > 4096)) return RCFailure(@"Title must contain 1–4096 characters");
    if ([request[@"content"] lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 1024*1024) return RCFailure(@"Text exceeds 1 MiB");
    if (request[@"content"] && request[@"image_base64"]) return RCFailure(@"Choose content or image, not both");
    NSData *image = nil;
    if (request[@"image_base64"]) {
        if ([request[@"image_base64"] length] > 14*1024*1024) return RCFailure(@"Image exceeds limit");
        image = [[NSData alloc] initWithBase64EncodedString:request[@"image_base64"] options:0];
        if (![RCSnippetMedia isValidImageData:image]) return RCFailure(@"Invalid image (single image, maximum 10 MiB / 16 megapixels)");
    }
    NSArray *catalog = [self.database fetchSnippetCatalog];
    if (!catalog) return RCFailure(@"Could not read templates");
    NSDictionary *folder = nil, *snippet = nil;
    NSMutableArray *snippets = [NSMutableArray array], *folders = [NSMutableArray array];
    NSInteger folderIndex = 0;
    for (NSDictionary *entry in catalog) {
        folderIndex = MAX(folderIndex, [entry[@"folder_index"] integerValue]+1);
        if ([entry[@"identifier"] isEqual:request[@"folder"]]) folder = entry;
        NSMutableDictionary *summary = [entry mutableCopy]; [summary removeObjectForKey:@"snippets"];
        [folders addObject:summary];
        for (NSDictionary *row in entry[@"snippets"]) {
            if ([row[@"identifier"] isEqual:request[@"id"]]) snippet = row;
            if (!request[@"folder"] || [entry[@"identifier"] isEqual:request[@"folder"]]) [snippets addObject:RCJSONSnippet(row)];
        }
    }
    if (request[@"folder"] && !folder) return RCFailure(@"Folder not found");
    if ([operation isEqual:@"folders"]) return RCSuccess(folders);
    if ([operation isEqual:@"list"]) return RCSuccess(snippets);
    if ([operation isEqual:@"get"] || [operation isEqual:@"update"] || [operation isEqual:@"delete"]) {
        if (!snippet) return RCFailure(@"Template ID not found");
    }
    if ([operation isEqual:@"get"]) return RCSuccess(RCJSONSnippet(snippet));
    BOOL success = NO;
    NSString *identifier = request[@"id"] ?: NSUUID.UUID.UUIDString;
    if ([operation isEqual:@"folder-create"]) {
        if (!request[@"title"]) return RCFailure(@"title is required");
        success = [self.database insertSnippetFolder:@{@"identifier":identifier,@"title":request[@"title"],@"folder_index":@(folderIndex),@"enabled":@YES}];
    } else if ([operation isEqual:@"folder-delete"]) {
        // Deliberately refuse cascading deletion of populated folders.
        NSDictionary *target = nil;
        for (NSDictionary *entry in catalog) if ([entry[@"identifier"] isEqual:request[@"id"]]) target = entry;
        if (!target) return RCFailure(@"Folder ID not found");
        if ([target[@"snippets"] count]) return RCFailure(@"Folder must be empty");
        success = [self.database deleteSnippetFolder:identifier];
    } else if ([operation isEqual:@"delete"]) {
        success = [self.database deleteSnippet:identifier];
    } else {
        NSMutableDictionary *changes = [NSMutableDictionary dictionary];
        for (NSString *key in @[@"title",@"content",@"enabled"]) if (request[key]) changes[key] = request[key];
        if (request[@"content"]) changes[@"media_data"] = NSData.data;
        if (image) { changes[@"media_data"] = image; changes[@"content"] = @""; }
        if (folder) changes[@"folder_id"] = folder[@"identifier"];
        if ([operation isEqual:@"create"]) {
            if (!folder || !request[@"title"] || (!request[@"content"] && !image)) return RCFailure(@"create requires folder, title and content or image");
            changes[@"identifier"] = identifier;
            NSInteger index = 0;
            for (NSDictionary *row in folder[@"snippets"]) index = MAX(index,[row[@"snippet_index"] integerValue]+1);
            changes[@"snippet_index"] = @(index);
            success = [self.database insertSnippet:changes];
        } else {
            if (!changes.count) return RCFailure(@"No fields to update");
            success = [self.database updateSnippet:identifier withDict:changes];
        }
    }
    return success ? RCSuccess(@{@"identifier":identifier}) : RCFailure(@"Save failed; no success reported");
}
- (void)serveClient:(int)client {
    uid_t uid; gid_t gid;
    if (getpeereid(client, &uid, &gid) != 0 || uid != geteuid()) return;
    int one = 1; setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    fcntl(client, F_SETFL, O_NONBLOCK);
    uint32_t length;
    if (!RCTransfer(client, &length, sizeof(length), NO)) return;
    length = ntohl(length);
    if (!length || length > RCRequestLimit) return;
    NSMutableData *data = [NSMutableData dataWithLength:length];
    if (!RCTransfer(client, data.mutableBytes, length, NO)) return;
    id request = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    __block NSDictionary *response;
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (![[RCSnippetEditorWindowController shared] saveChangesIfLoaded]) {
            response = RCFailure(@"Editor is loading media or its draft could not be saved"); return;
        }
        response = [self executeRequest:request];
        NSString *op = [request isKindOfClass:NSDictionary.class] ? request[@"op"] : nil;
        if ([response[@"ok"] boolValue] && ![@[@"folders",@"list",@"get"] containsObject:op ?: @""]) {
            [[RCSnippetEditorWindowController shared] reloadIfLoaded];
            [NSNotificationCenter.defaultCenter postNotificationName:RCSnippetsDidChangeNotification object:self];
            [[RCHotKeyService shared] reloadFolderHotKeys];
        }
    });
    NSData *output = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
    if (output.length > 32*1024*1024) output = [NSJSONSerialization dataWithJSONObject:RCFailure(@"Response too large; filter by folder") options:0 error:nil];
    uint32_t size = htonl((uint32_t)output.length);
    if (RCTransfer(client, &size, sizeof(size), YES)) RCTransfer(client, (void *)output.bytes, output.length, YES);
}
- (void)start {
    if (self.listener) return;
    self.socketPath = [[RCUtilities applicationSupportPath] stringByAppendingPathComponent:@"cli.sock"];
    const char *path = self.socketPath.fileSystemRepresentation;
    struct sockaddr_un address = {0}; address.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof(address.sun_path)) { NSLog(@"[CLI] Socket path too long"); return; }
    self.lockFD = open([[self.socketPath stringByAppendingString:@".lock"] fileSystemRepresentation], O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW, 0600);
    if (self.lockFD < 0) return;
    if (flock(self.lockFD, LOCK_EX|LOCK_NB)) { close(self.lockFD); self.lockFD = -1; return; }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { [self stop]; return; }
    fcntl(fd, F_SETFD, FD_CLOEXEC); fcntl(fd, F_SETFL, O_NONBLOCK);
    strlcpy(address.sun_path,path,sizeof(address.sun_path)); unlink(path);
    if (bind(fd,(struct sockaddr *)&address,sizeof(address)) || chmod(path,0600) || listen(fd,8)) {
        close(fd); [self stop]; return;
    }
    dispatch_queue_t queue = dispatch_queue_create("com.revclip.cli", DISPATCH_QUEUE_SERIAL);
    self.listener = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,fd,0,queue);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.listener, ^{
        int client = accept(fd,NULL,NULL);
        if (client < 0) return;
        fcntl(client,F_SETFD,FD_CLOEXEC);
        @autoreleasepool { [weakSelf serveClient:client]; }
        close(client);
    });
    dispatch_source_set_cancel_handler(self.listener, ^{ close(fd); });
    dispatch_resume(self.listener);
}
- (void)stop {
    if (self.listener) { dispatch_source_cancel(self.listener); self.listener = nil; }
    if (self.lockFD >= 0) {
        unlink(self.socketPath.fileSystemRepresentation);
        close(self.lockFD); self.lockFD = -1;
    }
}
@end
