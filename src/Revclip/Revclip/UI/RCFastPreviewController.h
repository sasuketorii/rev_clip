#import <Cocoa/Cocoa.h>
NS_ASSUME_NONNULL_BEGIN
/// Displays help without replacing NSMenuItem views or dispatching menu actions.
@interface RCFastPreviewController : NSObject
- (void)highlightItem:(nullable NSMenuItem *)item text:(nullable NSString *)text;
- (void)hide;
@end
NS_ASSUME_NONNULL_END
