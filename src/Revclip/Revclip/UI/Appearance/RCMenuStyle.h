#import <Cocoa/Cocoa.h>
NS_ASSUME_NONNULL_BEGIN
@interface RCMenuStyle : NSObject
+ (BOOL)isEnabled;
+ (NSString *)paletteKey;
+ (nullable NSColor *)colorForKey:(NSString *)key;
+ (void)applyToItem:(NSMenuItem *)item;
+ (void)refreshMenu:(NSMenu *)menu;
@end
NS_ASSUME_NONNULL_END
