#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted on the main thread when a shared submission starts or finishes.
FOUNDATION_EXPORT NSNotificationName const RCBugReportServiceDidChangeNotification;

/// GUI and CLI share this transport. Invoke on the main thread; completion is always asynchronous on main.
@interface RCBugReportService : NSObject
+ (instancetype)shared;
- (void)submitTitle:(NSString *)title
        description:(NSString *)description
            contact:(NSString *)contact
            consent:(BOOL)consent
         completion:(void (^)(NSDictionary *response))completion;

@property (nonatomic, readonly, getter=isSubmitting) BOOL submitting;
/// Memory only: current or failed submission inputs, retained independently of any preferences page.
/// Cleared on success. No clipboard, history, logs, IP lookup or disk persistence.
@property (nonatomic, copy, readonly, nullable) NSDictionary *draft;
@property (nonatomic, copy, readonly, nullable) NSDictionary *lastResponse;
/// The same four locally generated fields that the service adds after validating consent.
@property (nonatomic, copy, readonly) NSDictionary<NSString *, NSString *> *sourceMetadata;
@end

NS_ASSUME_NONNULL_END
