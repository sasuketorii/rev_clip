#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import "RCAgentSkillInstaller.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <arpa/inet.h>
#import <poll.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <math.h>
#import <stdio.h>
#import <string.h>

static const NSUInteger RCRequestLimit = 16 * 1024 * 1024;
static const NSUInteger RCResponseLimit = 32 * 1024 * 1024;
static void RCRequire(BOOL condition, NSString *message) {
    if (!condition) @throw [NSException exceptionWithName:@"RCCLIInputError" reason:message userInfo:nil];
}
static void RCUsageRequire(BOOL condition, NSString *message) {
    if (!condition) @throw [NSException exceptionWithName:@"RCCLIUsageError" reason:message userInfo:nil];
}
static BOOL RCJSONWhitespace(unichar c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }
static NSTimeInterval RCNow(void) { return NSProcessInfo.processInfo.systemUptime; }
static void RCWait(int fd, short events, NSTimeInterval deadline) {
    for (;;) {
        double remaining = deadline - RCNow();
        RCRequire(remaining > 0, @"Operation timed out; delivery or write status may be unknown. Do not automatically retry.");
        struct pollfd descriptor = {fd, events, 0};
        int result = poll(&descriptor, 1, (int)MIN(25000.0, ceil(remaining * 1000.0)));
        if (result < 0 && errno == EINTR) continue;
        RCRequire(result >= 0, @"Could not poll input/socket");
        if (!result) continue;
        RCRequire(!(descriptor.revents & POLLNVAL), @"Invalid input/socket");
        return; // POLLHUP/POLLERR are resolved by read/recv/send/SO_ERROR.
    }
}
static void RCTransfer(int fd, void *bytes, NSUInteger length, BOOL writing, NSTimeInterval deadline) {
    while (length) {
        RCWait(fd, writing ? POLLOUT : POLLIN, deadline);
        ssize_t count = writing ? send(fd, bytes, length, 0) : recv(fd, bytes, length, 0);
        if (count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        RCRequire(count > 0, @"App closed the connection or socket transfer failed");
        bytes = (char *)bytes + count; length -= (NSUInteger)count;
    }
}
static NSData *RCReadFile(NSString *path, NSUInteger limit, BOOL allowStdin) {
    BOOL stdinInput = allowStdin && [path isEqual:@"-"];
    int fd = stdinInput ? dup(STDIN_FILENO) : open(path.fileSystemRepresentation, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    RCRequire(fd >= 0, @"Could not open input file/stdin");
    @try {
        struct stat info;
        RCRequire(fstat(fd, &info) == 0, @"Could not inspect input");
        RCRequire(stdinInput || S_ISREG(info.st_mode), @"Input must be a regular file");
        if (S_ISREG(info.st_mode)) RCRequire(info.st_size >= 0 && (uint64_t)info.st_size <= limit, @"Input exceeds size limit");
        NSMutableData *data = [NSMutableData data];
        NSTimeInterval deadline = RCNow() + 25;
        uint8_t buffer[16384];
        for (;;) {
            RCWait(fd, POLLIN, deadline);
            ssize_t count = read(fd, buffer, MIN(sizeof(buffer), limit + 1 - data.length));
            if (count < 0 && (errno == EINTR || errno == EAGAIN)) continue;
            RCRequire(count >= 0, @"Could not read input");
            if (!count) break;
            [data appendBytes:buffer length:(NSUInteger)count];
            RCRequire(data.length <= limit, @"Input exceeds size limit");
        }
        return [data copy];
    } @finally { close(fd); }
}
static NSString *RCUTF8(NSData *data) {
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    RCRequire(text != nil, @"Input must be valid UTF-8");
    return text;
}

// Foundation owns JSON decoding. This bounded lexical pass rejects duplicate
// object names (including escaped aliases) before Foundation can discard them.
@interface RCJSONKeyScanner : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic) NSUInteger offset;
- (unichar)peek;
- (void)valueAtDepth:(NSUInteger)depth;
@end
@implementation RCJSONKeyScanner
- (void)space {
    while (self.offset < self.text.length && RCJSONWhitespace([self.text characterAtIndex:self.offset])) self.offset++;
}
- (unichar)peek { [self space]; return self.offset < self.text.length ? [self.text characterAtIndex:self.offset] : 0; }
- (void)take:(unichar)character {
    RCRequire([self peek] == character, @"Invalid JSON syntax"); self.offset++;
}
- (NSString *)stringToken {
    [self take:'"']; NSUInteger start = self.offset - 1;
    BOOL escaped = NO, closed = NO;
    while (self.offset < self.text.length) {
        unichar c = [self.text characterAtIndex:self.offset++];
        if (!escaped && c == '"') { closed = YES; break; }
        if (!escaped && c == '\\') escaped = YES; else escaped = NO;
    }
    RCRequire(closed, @"Unterminated JSON string");
    NSString *token = [self.text substringWithRange:NSMakeRange(start, self.offset - start)];
    NSData *wrapped = [[NSString stringWithFormat:@"[%@]", token] dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *decoded = wrapped ? [NSJSONSerialization JSONObjectWithData:wrapped options:0 error:nil] : nil;
    RCRequire([decoded isKindOfClass:NSArray.class] && [decoded.firstObject isKindOfClass:NSString.class], @"Invalid JSON string");
    return decoded.firstObject;
}
- (void)valueAtDepth:(NSUInteger)depth {
    RCRequire(depth <= 64, @"JSON nesting exceeds 64 levels");
    unichar c = [self peek];
    if (c == '{') {
        self.offset++; NSMutableSet *names = [NSMutableSet set];
        if ([self peek] == '}') { self.offset++; return; }
        for (;;) {
            NSString *key = [self stringToken];
            RCRequire(![names containsObject:key], @"Duplicate JSON key"); [names addObject:key];
            [self take:':']; [self valueAtDepth:depth + 1];
            if ([self peek] == '}') { self.offset++; return; }
            [self take:','];
        }
    }
    if (c == '[') {
        self.offset++;
        if ([self peek] == ']') { self.offset++; return; }
        for (;;) {
            [self valueAtDepth:depth + 1];
            if ([self peek] == ']') { self.offset++; return; }
            [self take:','];
        }
    }
    if (c == '"') { [self stringToken]; return; }
    NSUInteger start = self.offset;
    while (self.offset < self.text.length) {
        unichar character = [self.text characterAtIndex:self.offset];
        if (character == ',' || character == ']' || character == '}' || RCJSONWhitespace(character)) break;
        self.offset++;
    }
    RCRequire(self.offset > start, @"Invalid JSON value");
    NSString *token = [self.text substringWithRange:NSMakeRange(start, self.offset - start)];
    RCRequire(![@[@"NaN",@"Infinity",@"-Infinity"] containsObject:token], @"Non-finite JSON number");
}
@end
static void RCFiniteJSON(id value) {
    if ([value isKindOfClass:NSNumber.class]) RCRequire(isfinite([value doubleValue]), @"Non-finite JSON number");
    else if ([value isKindOfClass:NSArray.class]) for (id item in value) RCFiniteJSON(item);
    else if ([value isKindOfClass:NSDictionary.class]) for (id key in value) RCFiniteJSON(value[key]);
}
static NSDictionary *RCSettingsJSON(NSString *text) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    RCRequire(data != nil && data.length <= 1024 * 1024, @"Settings input exceeds 1 MiB or is invalid UTF-8");
    RCJSONKeyScanner *scanner = [RCJSONKeyScanner new]; scanner.text = text;
    [scanner valueAtDepth:0];
    RCRequire([scanner peek] == 0, @"Invalid trailing JSON data");
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    RCRequire([value isKindOfClass:NSDictionary.class] && [value count] > 0, @"Settings must be a nonempty JSON object");
    RCFiniteJSON(value);
    return value;
}
static int RCOutput(NSDictionary *response) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:response options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    if (!data) { fputs("{\"ok\":false,\"error\":\"Invalid JSON response\"}\n", stdout); return 1; }
    if (fwrite(data.bytes, 1, data.length, stdout) != data.length || fputc('\n', stdout) == EOF) return 1;
    return [response[@"ok"] boolValue] ? 0 : 1;
}
static int RCHelp(void) {
    return RCOutput(@{@"ok":@YES, @"result":@{
        @"usage":@"revclip [--app Revclip|revclip-demo] COMMAND [OPTIONS]",
        @"default_app":@"Revclip",
        @"commands":@{@"settings-schema":@"", @"settings-get":@"[--key KEY]", @"settings-set":@"--json OBJECT | --file FILE|-",
            @"app-action":@"ACTION", @"bug-report":@"--title TITLE (--description TEXT | --description-file FILE|-) [--contact TEXT] --consent-source-info",
            @"folders":@"", @"folder-create":@"--title TITLE", @"folder-delete":@"ID", @"list":@"[--folder ID]", @"get":@"ID", @"delete":@"ID",
            @"create":@"--folder ID --title TITLE (--content TEXT | --content-file FILE|- | --image FILE) [--enabled true|false]",
            @"update":@"ID [--folder ID] [--title TITLE] [--content TEXT | --content-file FILE|- | --image FILE] [--enabled true|false]",
            @"agent":@"inspect|install [OPTIONS]"},
        @"report_consent":@"Explicit consent sends source IP, region, network, language, timezone and app/OS information. No automatic clipboard/history/log collection.",
        @"history_readable":@NO, @"clipboard_readable":@NO}});
}

static NSDictionary *RCRequest(NSArray<NSString *> *arguments, NSString **app, NSArray **agentArguments, BOOL *help) {
    NSUInteger offset = 0;
    *app = @"Revclip";
    NSMutableArray *filtered = [NSMutableArray array];
    BOOL literalArguments = NO;
    for (NSUInteger index = 0; index < arguments.count; index++) {
        NSString *arg = arguments[index];
        if ([arg isEqual:@"--"]) literalArguments = YES;
        if (!literalArguments && ([arg isEqual:@"--app"] || [arg hasPrefix:@"--app="])) {
            if ([arg hasPrefix:@"--app="]) *app = [arg substringFromIndex:6];
            else { RCUsageRequire(++index < arguments.count, @"--app requires a value"); *app = arguments[index]; }
            RCUsageRequire([@[@"Revclip",@"revclip-demo"] containsObject:*app], @"--app must be Revclip or revclip-demo");
        } else [filtered addObject:arg];
    }
    arguments = filtered;
    if ([arguments.firstObject isEqual:@"--help"] || [arguments.firstObject isEqual:@"-h"]) { *help = YES; return nil; }
    RCUsageRequire(offset < arguments.count, @"Missing command; use --help");
    NSString *op = arguments[offset++];
    if ([op isEqual:@"agent"]) {
        NSArray *tail = [arguments subarrayWithRange:NSMakeRange(offset, arguments.count - offset)];
        *agentArguments = [tail arrayByAddingObjectsFromArray:@[@"--app", *app]]; return nil;
    }
    NSDictionary *optionsByOp = @{@"settings-schema":@[], @"settings-get":@[@"key"], @"settings-set":@[@"json",@"file"],
        @"app-action":@[], @"bug-report":@[@"title",@"description",@"description-file",@"contact",@"consent-source-info"],
        @"folders":@[], @"folder-create":@[@"title"], @"folder-delete":@[], @"list":@[@"folder"], @"get":@[], @"delete":@[],
        @"create":@[@"folder",@"title",@"content",@"content-file",@"image",@"enabled"], @"update":@[@"folder",@"title",@"content",@"content-file",@"image",@"enabled"]};
    RCUsageRequire(optionsByOp[op] != nil, @"Unknown command; history and clipboard access are unavailable");
    NSMutableDictionary *options = [NSMutableDictionary dictionary]; NSMutableArray *positionals = [NSMutableArray array];
    BOOL positionalOnly = NO;
    while (offset < arguments.count) {
        NSString *arg = arguments[offset++];
        if (!positionalOnly && ([arg isEqual:@"--help"] || [arg isEqual:@"-h"])) { *help = YES; return nil; }
        if (!positionalOnly && [arg isEqual:@"--"]) { positionalOnly = YES; continue; }
        if (!positionalOnly && [arg hasPrefix:@"--"]) {
            NSRange equal = [arg rangeOfString:@"="];
            NSString *name = [arg substringWithRange:NSMakeRange(2, (equal.location == NSNotFound ? arg.length : equal.location) - 2)];
            RCUsageRequire([optionsByOp[op] containsObject:name], @"Unknown option for command");
            if ([name isEqual:@"consent-source-info"]) {
                RCUsageRequire(equal.location == NSNotFound, @"--consent-source-info takes no value"); options[name] = @YES; continue;
            }
            NSString *value;
            if (equal.location != NSNotFound) value = [arg substringFromIndex:equal.location + 1];
            else {
                RCUsageRequire(offset < arguments.count, @"Option requires a value"); value = arguments[offset++];
                RCUsageRequire(![value hasPrefix:@"--"], @"Option requires a value; use --option=value for text beginning with --");
            }
            options[name] = value;
        } else { RCUsageRequire(positionalOnly || ![arg hasPrefix:@"-"], @"Unknown option"); [positionals addObject:arg]; }
    }
    BOOL takesID = [@[@"get",@"delete",@"update",@"folder-delete"] containsObject:op];
    BOOL takesAction = [op isEqual:@"app-action"];
    RCUsageRequire(positionals.count == ((takesID || takesAction) ? 1u : 0u), @"Incorrect number of positional arguments");
    NSMutableDictionary *request = [@{@"op":op} mutableCopy];
    if (takesID) request[@"id"] = positionals[0];
    if (takesAction) request[@"action"] = positionals[0];
    for (NSString *key in @[@"key",@"folder",@"title",@"content",@"description",@"contact"]) if (options[key]) request[key] = options[key];
    if (options[@"enabled"]) {
        RCUsageRequire([@[@"true",@"false"] containsObject:options[@"enabled"]], @"--enabled must be true or false"); request[@"enabled"] = @([options[@"enabled"] isEqual:@"true"]);
    }
    if ([op isEqual:@"settings-set"]) {
        RCUsageRequire((options[@"json"] != nil) + (options[@"file"] != nil) == 1, @"Choose exactly one of --json or --file");
        NSString *text = options[@"json"] ?: RCUTF8(RCReadFile(options[@"file"], 1024 * 1024, YES));
        request[@"values"] = RCSettingsJSON(text);
    }
    NSUInteger contentCount = (options[@"content"] != nil) + (options[@"content-file"] != nil) + (options[@"image"] != nil);
    RCUsageRequire(contentCount <= 1, @"Choose one of --content, --content-file or --image");
    if ([op isEqual:@"create"]) RCUsageRequire(options[@"folder"] && options[@"title"] && contentCount == 1, @"create requires --folder, --title and content/image");
    if ([op isEqual:@"folder-create"]) RCUsageRequire(options[@"title"] != nil, @"folder-create requires --title");
    if (options[@"content-file"]) request[@"content"] = RCUTF8(RCReadFile(options[@"content-file"], 1024 * 1024, YES));
    if (options[@"image"]) request[@"image_base64"] = [RCReadFile(options[@"image"], 10 * 1024 * 1024, NO) base64EncodedStringWithOptions:0];
    if ([op isEqual:@"bug-report"]) {
        RCUsageRequire(options[@"consent-source-info"] != nil, @"--consent-source-info is required before reporting");
        RCUsageRequire(options[@"title"] && (options[@"description"] != nil) + (options[@"description-file"] != nil) == 1, @"Report requires --title and exactly one description input");
        if (options[@"description-file"]) request[@"description"] = RCUTF8(RCReadFile(options[@"description-file"], 16384, YES));
        request[@"contact"] = options[@"contact"] ?: @""; request[@"source_info_consent"] = @YES;
        NSDictionary *limits = @{@"title":@120,@"description":@2500,@"contact":@200};
        for (NSString *key in limits) {
            NSString *text = [request[key] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            RCRequire(text.length <= [limits[key] unsignedIntegerValue] && ([key isEqual:@"contact"] || text.length), @"Invalid report field length"); request[key] = text;
        }
    }
    return request;
}

static NSDictionary *RCSend(NSDictionary *request, NSString *app) {
    NSData *payload = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    RCRequire(payload != nil && payload.length <= RCRequestLimit, @"Request exceeds 16 MiB or is invalid JSON");
    NSString *path = [[[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"] stringByAppendingPathComponent:app] stringByAppendingPathComponent:@"cli.sock"];
    struct stat info;
    RCRequire(lstat(path.fileSystemRepresentation, &info) == 0, [NSString stringWithFormat:@"Start the updated %@.app first", app]);
    RCRequire(S_ISSOCK(info.st_mode) && info.st_uid == getuid() && (info.st_mode & 0077) == 0, @"Invalid app socket owner, type or permissions");
    struct sockaddr_un address = {0}; address.sun_family = AF_UNIX;
    RCRequire(strlen(path.fileSystemRepresentation) < sizeof(address.sun_path), @"App socket path is too long");
    strlcpy(address.sun_path, path.fileSystemRepresentation, sizeof(address.sun_path));
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    RCRequire(fd >= 0, @"Could not create socket");
    @try {
        RCRequire(fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 && fcntl(fd, F_SETFL, O_NONBLOCK) == 0, @"Could not configure socket");
        int one = 1; RCRequire(setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)) == 0, @"Could not configure socket");
        NSTimeInterval deadline = RCNow() + 25;
        if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
            RCRequire(errno == EINPROGRESS || errno == EAGAIN || errno == EINTR, [NSString stringWithFormat:@"Start the updated %@.app first", app]);
            RCWait(fd, POLLOUT, deadline);
            int error = 0; socklen_t size = sizeof(error);
            RCRequire(getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 && error == 0, @"Could not connect to app socket");
        }
        uid_t peer; gid_t group;
        RCRequire(getpeereid(fd, &peer, &group) == 0 && peer == getuid(), @"App socket peer has an unexpected owner");
        uint32_t size = htonl((uint32_t)payload.length);
        RCTransfer(fd, &size, sizeof(size), YES, deadline);
        RCTransfer(fd, (void *)payload.bytes, payload.length, YES, deadline);
        RCTransfer(fd, &size, sizeof(size), NO, deadline);
        NSUInteger length = ntohl(size);
        RCRequire(length > 0 && length <= RCResponseLimit, @"Response exceeds 32 MiB or is empty");
        NSMutableData *data = [NSMutableData dataWithLength:length];
        RCTransfer(fd, data.mutableBytes, length, NO, deadline);
        id response = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        RCRequire([response isKindOfClass:NSDictionary.class], @"Invalid app JSON response");
        id ok = response[@"ok"];
        RCRequire([ok isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)ok) == CFBooleanGetTypeID(), @"Invalid app response status");
        RCRequire([ok boolValue] ? response[@"result"] != nil : [response[@"error"] isKindOfClass:NSString.class], @"Invalid app response envelope");
        return response;
    } @finally { close(fd); }
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        @try {
            NSMutableArray *arguments = [NSMutableArray array];
            for (int index = 1; index < argc; index++) {
                NSString *argument = [NSString stringWithUTF8String:argv[index]];
                RCRequire(argument != nil, @"Arguments must be UTF-8"); [arguments addObject:argument];
            }
            NSString *app; NSArray *agentArguments = nil; BOOL help = NO;
            NSDictionary *request = RCRequest(arguments, &app, &agentArguments, &help);
            if (help) return RCHelp();
            if (agentArguments) return [RCAgentSkillInstaller runArguments:agentArguments];
            return RCOutput(RCSend(request, app));
        } @catch (NSException *exception) {
            BOOL usage = [exception.name isEqual:@"RCCLIUsageError"];
            NSString *message = (usage || [exception.name isEqual:@"RCCLIInputError"]) ? exception.reason : @"CLI could not process the request";
            int status = RCOutput(@{@"ok":@NO, @"error":message ?: @"CLI failed", @"note":@"If a write timed out, verify its result before retrying; it may have completed."});
            return usage ? 2 : status;
        }
    }
}
