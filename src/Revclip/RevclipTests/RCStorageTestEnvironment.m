//
//  RCStorageTestEnvironment.m
//  RevclipTests
//
//  Isolate every test-bundle storage access before an XCTest case can touch a
//  shared manager. This file is test-only and never ships in the application.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <sys/stat.h>

#import "RCUtilities.h"

@interface RCStorageCipher : NSObject
+ (void)installEphemeralSharedKeyForTesting:(NSData *)keyData;
@end

#if !DEBUG && !RC_TESTING
#error "Revclip storage tests require a Debug or RC_TESTING test host with an isolated storage environment."
#else

static NSString *gRCStorageTestRoot;
static NSString *gRCStorageTestClips;
static NSUserDefaults *gRCTestDefaults;
static NSUserDefaultsController *gRCTestDefaultsController;
static NSPasteboard *gRCTestPasteboard;

// Never delegate preference reads/writes to CFPreferences. In particular the
// explicit host-domain lookup used by localization must see these same values.
@interface RCMemoryTestDefaults : NSUserDefaults
@property(nonatomic, strong) NSMutableDictionary *domains;
@property(nonatomic, strong) NSMutableDictionary *registered;
@property(nonatomic, copy) NSString *hostDomain;
@end
@implementation RCMemoryTestDefaults
- (instancetype)init {
    // A fresh suite prevents super's initialization from selecting the host's
    // persistent domain; all subsequent storage operations below are in memory.
    self = [super initWithSuiteName:[@"RevclipTests.Memory." stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (self) {
        _hostDomain = NSBundle.mainBundle.bundleIdentifier;
        if (!_hostDomain.length) abort();
        _domains = [NSMutableDictionary dictionaryWithObject:[NSMutableDictionary dictionary] forKey:_hostDomain];
        _domains[NSGlobalDomain] = [@{@"AppleLanguages": @[@"en"]} mutableCopy];
        _registered = [NSMutableDictionary dictionary];
    }
    return self;
}
- (id)objectForKey:(NSString *)key { @synchronized(self) { return self.domains[self.hostDomain][key] ?: self.registered[key]; } }
- (void)setObject:(id)value forKey:(NSString *)key {
    @synchronized(self) {
        if (value) self.domains[self.hostDomain][key] = [value copy];
        else [self.domains[self.hostDomain] removeObjectForKey:key];
    }
    [NSNotificationCenter.defaultCenter postNotificationName:NSUserDefaultsDidChangeNotification object:self];
}
- (void)removeObjectForKey:(NSString *)key { [self setObject:nil forKey:key]; }
- (void)registerDefaults:(NSDictionary *)values { @synchronized(self) { [self.registered addEntriesFromDictionary:values]; } }
- (NSDictionary *)dictionaryRepresentation {
    @synchronized(self) {
        NSMutableDictionary *values = [self.registered mutableCopy];
        [values addEntriesFromDictionary:self.domains[self.hostDomain]];
        return [values copy];
    }
}
- (NSDictionary *)persistentDomainForName:(NSString *)name { @synchronized(self) { return [self.domains[name] copy]; } }
- (void)setPersistentDomain:(NSDictionary *)domain forName:(NSString *)name {
    @synchronized(self) { self.domains[name] = [domain mutableCopy]; }
    [NSNotificationCenter.defaultCenter postNotificationName:NSUserDefaultsDidChangeNotification object:self];
}
- (void)removePersistentDomainForName:(NSString *)name {
    @synchronized(self) {
        if ([name isEqual:self.hostDomain]) self.domains[name] = [NSMutableDictionary dictionary];
        else [self.domains removeObjectForKey:name];
    }
}
- (NSArray *)persistentDomainNames { @synchronized(self) { return self.domains.allKeys; } }
- (NSDictionary *)volatileDomainForName:(NSString *)name {
    if ([name isEqual:NSRegistrationDomain]) { @synchronized(self) { return [self.registered copy]; } }
    return [self persistentDomainForName:name] ?: @{};
}
- (void)setVolatileDomain:(NSDictionary *)domain forName:(NSString *)name { [self setPersistentDomain:domain forName:name]; }
- (void)removeVolatileDomainForName:(NSString *)name { [self removePersistentDomainForName:name]; }
- (NSArray *)volatileDomainNames { return [self persistentDomainNames]; }
- (void)addSuiteNamed:(NSString *)name { (void)name; abort(); }
- (void)removeSuiteNamed:(NSString *)name { (void)name; abort(); }
- (BOOL)synchronize { return YES; }
- (BOOL)objectIsForcedForKey:(NSString *)key { (void)key; return NO; }
- (BOOL)objectIsForcedForKey:(NSString *)key inDomain:(NSString *)domain { (void)key; (void)domain; return NO; }
- (NSString *)stringForKey:(NSString *)key { id v=[self objectForKey:key]; return [v isKindOfClass:NSString.class] ? v : ([v isKindOfClass:NSNumber.class] ? [v stringValue] : nil); }
- (NSArray *)arrayForKey:(NSString *)key { id v=[self objectForKey:key]; return [v isKindOfClass:NSArray.class] ? v : nil; }
- (NSDictionary *)dictionaryForKey:(NSString *)key { id v=[self objectForKey:key]; return [v isKindOfClass:NSDictionary.class] ? v : nil; }
- (NSData *)dataForKey:(NSString *)key { id v=[self objectForKey:key]; return [v isKindOfClass:NSData.class] ? v : nil; }
- (NSArray *)stringArrayForKey:(NSString *)key {
    NSArray *values=[self arrayForKey:key];
    for (id value in values) if (![value isKindOfClass:NSString.class]) return nil;
    return values;
}
- (NSURL *)URLForKey:(NSString *)key { id v=[self objectForKey:key]; return [v isKindOfClass:NSURL.class] ? v : nil; }
- (void)setURL:(NSURL *)value forKey:(NSString *)key { [self setObject:value forKey:key]; }
- (NSInteger)integerForKey:(NSString *)key { id v=[self objectForKey:key]; return [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : 0; }
- (BOOL)boolForKey:(NSString *)key { id v=[self objectForKey:key]; return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : NO; }
- (float)floatForKey:(NSString *)key { id v=[self objectForKey:key]; return [v respondsToSelector:@selector(floatValue)] ? [v floatValue] : 0; }
- (double)doubleForKey:(NSString *)key { id v=[self objectForKey:key]; return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 0; }
- (void)setInteger:(NSInteger)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
- (void)setBool:(BOOL)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
- (void)setFloat:(float)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
- (void)setDouble:(double)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
@end

static id RCTestStandardDefaults(id self, SEL selector) {
    (void)self; (void)selector;
    if (!gRCTestDefaults) abort();
    return gRCTestDefaults;
}
static id RCTestDefaultsController(id self, SEL selector) {
    (void)self; (void)selector;
    if (!gRCTestDefaultsController) abort();
    return gRCTestDefaultsController;
}
static id RCTestGeneralPasteboard(id self, SEL selector) {
    (void)self; (void)selector;
    if (!gRCTestPasteboard) abort();
    return gRCTestPasteboard;
}
static void RCTestReplaceClassMethod(Class cls, SEL selector, IMP replacement) {
    Method method = class_getClassMethod(cls, selector);
    if (!method) abort();
    method_setImplementation(method, replacement);
    if (method_getImplementation(method) != replacement) abort();
}

static NSString *RCStorageTestApplicationSupportPath(id self, SEL selector) {
    (void)self;
    (void)selector;
    return gRCStorageTestRoot;
}

static NSString *RCStorageTestClipDataDirectoryPath(id self, SEL selector) {
    (void)self;
    (void)selector;
    return gRCStorageTestClips;
}

static void RCStorageTestCleanup(void) {
    @autoreleasepool {
        // Only our uniquely named board is released; never inspect or restore
        // anything from the user's general clipboard.
        [gRCTestPasteboard releaseGlobally];
        NSString *root = gRCStorageTestRoot;
        if (root.length > 0) {
            [[NSFileManager defaultManager] removeItemAtPath:root error:nil];
        }
        gRCStorageTestRoot = nil;
        gRCStorageTestClips = nil;
    }
}

__attribute__((constructor))
static void RCStorageTestInstallEnvironment(void) {
    @autoreleasepool {
        // Never obtain or snapshot the real general pasteboard or defaults.
        RCTestReplaceClassMethod(NSUserDefaults.class, @selector(standardUserDefaults), (IMP)RCTestStandardDefaults);
        RCTestReplaceClassMethod(NSPasteboard.class, @selector(generalPasteboard), (IMP)RCTestGeneralPasteboard);
        RCTestReplaceClassMethod(NSUserDefaultsController.class, @selector(sharedUserDefaultsController), (IMP)RCTestDefaultsController);
        gRCTestDefaults = [RCMemoryTestDefaults new];
        gRCTestPasteboard = [NSPasteboard pasteboardWithUniqueName];
        if (!gRCTestPasteboard || [gRCTestPasteboard.name isEqual:NSPasteboardNameGeneral]) abort();
        gRCTestDefaultsController = [[NSUserDefaultsController alloc] initWithDefaults:gRCTestDefaults initialValues:nil];
        if (!gRCTestDefaultsController || NSUserDefaults.standardUserDefaults != gRCTestDefaults ||
            NSUserDefaultsController.sharedUserDefaultsController.defaults != gRCTestDefaults ||
            NSPasteboard.generalPasteboard != gRCTestPasteboard) abort();
        NSString *probe = @"RevclipTests.IsolationProbe";
        [gRCTestDefaults setBool:YES forKey:probe];
        if (![gRCTestDefaults boolForKey:probe] ||
            ![[gRCTestDefaults persistentDomainForName:NSBundle.mainBundle.bundleIdentifier][probe] boolValue]) abort();
        [gRCTestDefaults removeObjectForKey:probe];
        if ([gRCTestDefaults objectForKey:probe]) abort();

        char template[] = "/tmp/RevclipTests-storage-XXXXXX";
        if (mkdtemp(template) == NULL) {
            abort();
        }

        gRCStorageTestRoot = [[NSString stringWithUTF8String:template] copy];
        gRCStorageTestClips = [gRCStorageTestRoot stringByAppendingPathComponent:@"ClipsData"];
        if (![[NSFileManager defaultManager] createDirectoryAtPath:gRCStorageTestClips
                                       withIntermediateDirectories:NO
                                                        attributes:@{NSFilePosixPermissions: @0700}
                                                             error:nil]) {
            abort();
        }
        if (chmod(gRCStorageTestRoot.fileSystemRepresentation, 0700) != 0) {
            abort();
        }

        Method applicationSupportMethod = class_getClassMethod(
            RCUtilities.class, @selector(applicationSupportPath));
        Method clipDataMethod = class_getClassMethod(
            RCUtilities.class, @selector(clipDataDirectoryPath));
        if (applicationSupportMethod == NULL || clipDataMethod == NULL) {
            abort();
        }
        method_setImplementation(applicationSupportMethod,
                                 (IMP)RCStorageTestApplicationSupportPath);
        method_setImplementation(clipDataMethod,
                                 (IMP)RCStorageTestClipDataDirectoryPath);

        uint8_t key[32];
        arc4random_buf(key, sizeof(key));
        [RCStorageCipher installEphemeralSharedKeyForTesting:
            [NSData dataWithBytes:key length:sizeof(key)]];

        atexit(RCStorageTestCleanup);
    }
}

#endif
