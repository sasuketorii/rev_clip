#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSNotificationName const RCLanguageDidChangeNotification;
FOUNDATION_EXPORT NSString *RCLocalizedString(NSString *key, NSString * _Nullable comment) NS_SWIFT_NAME(RCLocalizedString(_:comment:));

@interface RCLocalization : NSObject
+ (NSString *)selectedLanguage;
+ (void)setLanguage:(NSString *)language;
+ (NSBundle *)languageBundle;
+ (void)localizeView:(NSView *)view table:(NSString *)table;
+ (void)localizeMenu:(NSMenu *)menu table:(NSString *)table;
@end
NS_ASSUME_NONNULL_END
