//
//  RCSingleInstanceLock.h
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Current project: AGPL-3.0-only; legacy portions: MIT. See THIRD_PARTY_NOTICES.md.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, RCSingleInstanceLockResult) {
    RCSingleInstanceLockResultAcquired = 0,
    // Another process holds the lock for the same data store.
    RCSingleInstanceLockResultHeld,
    // The lock file could not be opened or locked. Callers fail open.
    RCSingleInstanceLockResultError,
};

/// Opens `path` and takes a non-blocking exclusive flock. On Acquired, `*fdOut` is the
/// descriptor, which stays locked until RCSingleInstanceLockRelease. The descriptor is
/// close-on-exec so helper processes never inherit the lock.
RCSingleInstanceLockResult RCSingleInstanceLockTryAcquire(NSString *path, int *fdOut);
void RCSingleInstanceLockRelease(int fd);

/// YES when `environment` describes an XCTest-hosted process. Pure function of its input.
BOOL RCSingleInstanceLockIsXCTestEnvironment(NSDictionary<NSString *, NSString *> *environment);

/// Takes the process-wide lock on `<application support>/instance.lock`. Call before
/// NSApplicationMain. Does nothing and reports Acquired in an XCTest host. Safe to call
/// again after a release; a second call while holding the lock is a no-op.
RCSingleInstanceLockResult RCSingleInstanceLockAcquireForProcess(void);
/// Drops the process-wide lock so a relaunched instance can take it.
void RCSingleInstanceLockReleaseForProcess(void);

NS_ASSUME_NONNULL_END
