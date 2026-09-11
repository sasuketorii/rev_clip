//
//  RCStorageTestEnvironment.m
//  RevclipTests
//
//  Isolate every test-bundle storage access before an XCTest case can touch a
//  shared manager. This file is test-only and never ships in the application.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <sys/stat.h>

#import "RCUtilities.h"

@interface RCStorageCipher : NSObject
+ (void)installEphemeralSharedKeyForTesting:(NSData *)keyData;
@end

#if !DEBUG
#error "Revclip storage tests require a Debug test host with an isolated storage environment."
#else

static NSString *gRCStorageTestRoot;
static NSString *gRCStorageTestClips;

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
