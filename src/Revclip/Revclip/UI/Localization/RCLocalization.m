#import "RCLocalization.h"

NSNotificationName const RCLanguageDidChangeNotification = @"RCLanguageDidChangeNotification";
static NSBundle *RCCurrentLanguageBundle;
static NSArray<NSString *> *RCSupportedLanguages(void) {
    return @[@"ja", @"en", @"ko", @"zh-Hans", @"fr", @"de", @"pt-BR", @"it"];
}

@implementation RCLocalization
+ (NSString *)selectedLanguage {
    id languages = [NSUserDefaults.standardUserDefaults persistentDomainForName:NSBundle.mainBundle.bundleIdentifier][@"AppleLanguages"];
    if (![languages isKindOfClass:NSArray.class] || [languages count] == 0 || ![languages[0] isKindOfClass:NSString.class]) { return @""; }
    return [NSBundle preferredLocalizationsFromArray:RCSupportedLanguages() forPreferences:languages].firstObject ?: @"en";
}

+ (NSBundle *)languageBundle {
    @synchronized(self) {
        if (!RCCurrentLanguageBundle) {
            NSString *language = self.selectedLanguage;
            if (language.length == 0) {
                NSArray *preferred = [NSUserDefaults.standardUserDefaults persistentDomainForName:NSGlobalDomain][@"AppleLanguages"];
                language = [NSBundle preferredLocalizationsFromArray:RCSupportedLanguages() forPreferences:preferred ?: NSLocale.preferredLanguages].firstObject ?: @"en";
            }
            RCCurrentLanguageBundle = [NSBundle bundleWithPath:[NSBundle.mainBundle pathForResource:language ofType:@"lproj"]] ?: NSBundle.mainBundle;
        }
        return RCCurrentLanguageBundle;
    }
}

+ (void)setLanguage:(NSString *)language {
    NSAssert(NSThread.isMainThread, @"UI language changes must run on the main thread");
    if (language.length && ![RCSupportedLanguages() containsObject:language]) { return; }
    if (language.length) { [NSUserDefaults.standardUserDefaults setObject:@[language] forKey:@"AppleLanguages"]; }
    else { [NSUserDefaults.standardUserDefaults removeObjectForKey:@"AppleLanguages"]; }
    @synchronized(self) { RCCurrentLanguageBundle = nil; }
    [NSNotificationCenter.defaultCenter postNotificationName:RCLanguageDidChangeNotification object:nil];
}

+ (NSString *)titleForIdentifier:(NSString *)identifier table:(NSString *)table {
    if (!identifier.length) { return nil; }
    NSString *key = [identifier stringByAppendingString:@".title"];
    NSString *value = [self.languageBundle localizedStringForKey:key value:@"" table:table];
    return [value isEqualToString:key] ? nil : value;
}

+ (void)localizeMenu:(NSMenu *)menu table:(NSString *)table {
    for (NSMenuItem *item in menu.itemArray) {
        NSString *title = [self titleForIdentifier:item.identifier table:table];
        if (title) { item.title = title; }
        if (item.submenu) { [self localizeMenu:item.submenu table:table]; }
    }
}

+ (void)localizeView:(NSView *)view table:(NSString *)table {
    NSString *title = [self titleForIdentifier:view.identifier table:table];
    if ([view isKindOfClass:NSTextField.class] && ![(NSTextField *)view isEditable] && title) {
        [(NSTextField *)view setStringValue:title];
    } else if ([view isKindOfClass:NSButton.class] && title) {
        [(NSButton *)view setTitle:title];
    }
    if ([view isKindOfClass:NSPopUpButton.class]) { [self localizeMenu:[(NSPopUpButton *)view menu] table:table]; }
    for (NSView *child in view.subviews) { [self localizeView:child table:table]; }
}
@end

NSString *RCLocalizedString(NSString *key, NSString *comment) {
    return [RCLocalization.languageBundle localizedStringForKey:key value:nil table:nil];
}
