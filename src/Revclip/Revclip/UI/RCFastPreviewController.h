#import <Cocoa/Cocoa.h>
NS_ASSUME_NONNULL_BEGIN
/// Displays help without replacing NSMenuItem views or dispatching menu actions.
@interface RCFastPreviewController : NSObject
- (void)highlightItem:(nullable NSMenuItem *)item text:(nullable NSString *)text;
- (void)highlightItem:(nullable NSMenuItem *)item text:(nullable NSString *)text imageData:(nullable NSData *)imageData;
- (void)hide;
@end
NS_ASSUME_NONNULL_END
