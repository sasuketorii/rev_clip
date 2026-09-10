#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RCPanicEraseService : NSObject

+ (instancetype)shared;

/// Best-effort 1-pass zero-fill overwrite of a file at the given path.
/// Does NOT delete the file. Caller must delete it after overwrite.
+ (void)secureOverwriteFileAtPath:(NSString *)path;

/// YES while panic erase is in progress. All write services must check this flag
/// at their entry points and bail out if YES.
@property (atomic, assign, readonly) BOOL isPanicInProgress;

/// Execute full panic erase sequence. Runs on dedicated background panicQueue.
/// Completion is called on panicQueue. App will terminate after erase completes.
- (void)executePanicEraseWithCompletion:(nullable void(^)(BOOL success))completion;

@end

NS_ASSUME_NONNULL_END
