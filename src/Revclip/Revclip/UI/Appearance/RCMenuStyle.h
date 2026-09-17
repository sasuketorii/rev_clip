#import <Cocoa/Cocoa.h>
NS_ASSUME_NONNULL_BEGIN
@interface RCMenuStyle : NSObject
+ (BOOL)isEnabled;
+ (NSString *)paletteKey;
+ (nullable NSColor *)colorForKey:(NSString *)key;
+ (void)applyToItem:(NSMenuItem *)item;
+ (void)refreshMenu:(NSMenu *)menu;
// While set, a styled row offers its item here, synchronously and before tracking is
// cancelled. When the block takes it (YES) the row sends no action. A styled row
// normally sends its action after tracking ended, which is too late for a caller that
// has to answer from inside the menu call (the Services entry).
+ (void)setSelectionInterceptor:(nullable BOOL (^)(NSMenuItem *item))interceptor;
@end
NS_ASSUME_NONNULL_END
