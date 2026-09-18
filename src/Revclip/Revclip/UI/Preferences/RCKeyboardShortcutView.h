#import <AppKit/AppKit.h>
#import "RCHotKeyService.h"

NS_ASSUME_NONNULL_BEGIN
/// Display-only overlay on the supplied US keyboard photograph.
@interface RCKeyboardShortcutView : NSView
@property (nonatomic) RCKeyCombo keyCombo;
@property (nonatomic, readonly) NSSet<NSNumber *> *highlightedKeyCodes;
+ (NSRect)imageRectForKeyCode:(UInt32)keyCode;
@end
NS_ASSUME_NONNULL_END
