#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const RCSettingsDidChangeNotification;

/// In-process backend. The socket owner is responsible for transport/authentication.
@interface RCSettingsCLIService : NSObject
+ (instancetype)shared;
/// {op:"settings-schema"}, {op:"settings-get", key?:string},
/// {op:"settings-set", values:{key:value}}, {op:"app-action", action:string}.
/// Returns {ok:true,result:object} or {ok:false,error:string}.
/// Validates every key before mutation; executes defaults/KVO and UI effects on main.
/// Callers off main must not hold a lock or queue that the main thread needs.
/// Cleanup and UI actions are asynchronous; success does not mean cleanup/update completion.
- (NSDictionary *)executeRequest:(NSDictionary *)request;
@end

NS_ASSUME_NONNULL_END
