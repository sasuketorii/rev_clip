#import <Cocoa/Cocoa.h>

/// Shared presentation only; controllers retain their existing settings actions and bindings.
@interface RCPreferencesPage : NSView
+ (instancetype)pageWithRows:(NSArray<NSArray *> *)rows;
+ (NSSwitch *)switchForController:(NSViewController *)controller key:(NSString *)key;
@end

@interface RCPreferencesTextField : NSTextField
@end

@interface RCPreferencesSurface : NSView
@property CGFloat cornerRadius;
@property BOOL drawsBorder;
@end
