#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RCPanicEraseService : NSObject

+ (instancetype)shared;

/// Best-effort 1-pass zero-fill overwrite of a regular file at the given path.
/// The path is opened with O_NOFOLLOW and is never followed when it names a
/// symbolic link. Does NOT delete the file. Caller must delete it after
/// overwrite. This does not guarantee physical erasure on SSDs or snapshots.
+ (BOOL)secureOverwriteFileAtPath:(NSString *)path;

/// YES while panic erase is active or a failed attempt is holding the write
/// barrier. All write services must check this flag at their entry points and
/// bail out if YES.
@property (atomic, assign, readonly) BOOL isPanicInProgress;

/// YES only while an erase attempt is actively draining or cleaning storage.
/// A failed attempt clears this state while isPanicInProgress remains set as
/// the write barrier, allowing the app delegate to distinguish retryable
/// failure from an active destructive operation.
@property (atomic, assign, readonly) BOOL isEraseAttemptActive;

/// Execute full panic erase sequence. Runs on dedicated background panicQueue.
/// Completion is always called on the main queue. The app requests termination
/// only after a successful erase; a failed attempt leaves the panic barrier in
/// place so the caller can report the failure and retry safely.
- (void)executePanicEraseWithCompletion:(nullable void(^)(BOOL success))completion;

@end

NS_ASSUME_NONNULL_END
