#import <Foundation/Foundation.h>
@class RCDatabaseManager;
NS_ASSUME_NONNULL_BEGIN
@interface RCSnippetCLIService : NSObject
+ (instancetype)shared;
- (void)start;
- (void)stop;
// Main-thread API; the caller persists editor drafts before invoking it.
- (instancetype)initWithDatabase:(RCDatabaseManager *)database;
- (NSDictionary *)executeRequest:(NSDictionary *)request;
@end
NS_ASSUME_NONNULL_END
