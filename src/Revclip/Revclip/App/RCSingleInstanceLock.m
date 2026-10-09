//
//  RCSingleInstanceLock.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Current project: AGPL-3.0-only; legacy portions: MIT. See THIRD_PARTY_NOTICES.md.
//

#import "RCSingleInstanceLock.h"
#import "RCUtilities.h"
#import <fcntl.h>
#import <sys/file.h>
#import <unistd.h>

static int sProcessLockFD = -1;

RCSingleInstanceLockResult RCSingleInstanceLockTryAcquire(NSString *path, int *fdOut) {
    if (fdOut != NULL) {
        *fdOut = -1;
    }
    if (path.length == 0) {
        return RCSingleInstanceLockResultError;
    }

    int fd = open(path.fileSystemRepresentation, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) {
        return RCSingleInstanceLockResultError;
    }
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        int lockError = errno;
        close(fd);
        return lockError == EWOULDBLOCK ? RCSingleInstanceLockResultHeld : RCSingleInstanceLockResultError;
    }
    if (fdOut != NULL) {
        *fdOut = fd;
    } else {
        close(fd);
    }
    return RCSingleInstanceLockResultAcquired;
}

void RCSingleInstanceLockRelease(int fd) {
    if (fd >= 0) {
        close(fd);
    }
}

BOOL RCSingleInstanceLockIsXCTestEnvironment(NSDictionary<NSString *, NSString *> *environment) {
    for (NSString *key in @[@"XCTestConfigurationFilePath", @"XCTestBundlePath", @"XCTestSessionIdentifier"]) {
        if (environment[key].length > 0) {
            return YES;
        }
    }
    return [environment[@"DYLD_INSERT_LIBRARIES"] containsString:@"libXCTestBundleInject"];
}

RCSingleInstanceLockResult RCSingleInstanceLockAcquireForProcess(void) {
    if (RCSingleInstanceLockIsXCTestEnvironment(NSProcessInfo.processInfo.environment)) {
        return RCSingleInstanceLockResultAcquired;
    }
    if (sProcessLockFD >= 0) {
        return RCSingleInstanceLockResultAcquired;
    }

    NSString *directory = [RCUtilities applicationSupportPath];
    if (![RCUtilities ensureDirectoryExists:directory]) {
        return RCSingleInstanceLockResultError;
    }
    return RCSingleInstanceLockTryAcquire([directory stringByAppendingPathComponent:@"instance.lock"], &sProcessLockFD);
}

void RCSingleInstanceLockReleaseForProcess(void) {
    RCSingleInstanceLockRelease(sProcessLockFD);
    sProcessLockFD = -1;
}
