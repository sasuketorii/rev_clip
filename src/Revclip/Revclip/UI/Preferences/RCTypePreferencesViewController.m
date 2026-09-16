#import "RCPreferencesPage.h"
#import "RCLocalization.h"
//
//  RCTypePreferencesViewController.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Current project: AGPL-3.0-only; legacy portions: MIT. See THIRD_PARTY_NOTICES.md.
//

#import "RCTypePreferencesViewController.h"

#import "RCConstants.h"

static NSString * const kRCStoreTypeString = @"String";
static NSString * const kRCStoreTypeRTF = @"RTF";
static NSString * const kRCStoreTypeRTFD = @"RTFD";
static NSString * const kRCStoreTypePDF = @"PDF";
static NSString * const kRCStoreTypeFilenames = @"Filenames";
static NSString * const kRCStoreTypeURL = @"URL";
static NSString * const kRCStoreTypeTIFF = @"TIFF";

@interface RCTypePreferencesViewController ()

@property (nonatomic, weak) IBOutlet NSButton *htmlCheckbox;
@property (nonatomic, weak) IBOutlet NSButton *plainTextCheckbox;
@property (nonatomic, weak) IBOutlet NSButton *richTextCheckbox;
@property (nonatomic, weak) IBOutlet NSButton *richTextWithAttachmentsCheckbox;
@property (nonatomic, weak) IBOutlet NSButton *pdfCheckbox;
@property (nonatomic, weak) IBOutlet NSButton *filenamesCheckbox;
@property (nonatomic, weak) IBOutlet NSButton *urlCheckbox;
@property (nonatomic, weak) IBOutlet NSButton *imagesTiffCheckbox;

@end

@implementation RCTypePreferencesViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [RCLocalization localizeView:self.view table:@"RCTypePreferencesView"];

    NSDictionary<NSString *, id> *storeTypes = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kRCPrefStoreTypesKey];
    [self setCheckbox:self.htmlCheckbox enabled:[self isStoreTypeEnabledForKey:@"HTML" inStoreTypes:storeTypes]];
    [self setCheckbox:self.plainTextCheckbox enabled:[self isStoreTypeEnabledForKey:kRCStoreTypeString inStoreTypes:storeTypes]];
    [self setCheckbox:self.richTextCheckbox enabled:[self isStoreTypeEnabledForKey:kRCStoreTypeRTF inStoreTypes:storeTypes]];
    [self setCheckbox:self.richTextWithAttachmentsCheckbox enabled:[self isStoreTypeEnabledForKey:kRCStoreTypeRTFD inStoreTypes:storeTypes]];
    [self setCheckbox:self.pdfCheckbox enabled:[self isStoreTypeEnabledForKey:kRCStoreTypePDF inStoreTypes:storeTypes]];
    [self setCheckbox:self.filenamesCheckbox enabled:[self isStoreTypeEnabledForKey:kRCStoreTypeFilenames inStoreTypes:storeTypes]];
    [self setCheckbox:self.urlCheckbox enabled:[self isStoreTypeEnabledForKey:kRCStoreTypeURL inStoreTypes:storeTypes]];
    [self setCheckbox:self.imagesTiffCheckbox enabled:[self isStoreTypeEnabledForKey:kRCStoreTypeTIFF inStoreTypes:storeTypes]];
    [self arrangeSettingsPage];
}

- (IBAction)storeTypeCheckboxDidChange:(id)sender {
    (void)sender;

    NSDictionary<NSString *, NSNumber *> *storeTypes = @{
        @"HTML": @([self isCheckboxEnabled:self.htmlCheckbox]),
        kRCStoreTypeString: @([self isCheckboxEnabled:self.plainTextCheckbox]),
        kRCStoreTypeRTF: @([self isCheckboxEnabled:self.richTextCheckbox]),
        kRCStoreTypeRTFD: @([self isCheckboxEnabled:self.richTextWithAttachmentsCheckbox]),
        kRCStoreTypePDF: @([self isCheckboxEnabled:self.pdfCheckbox]),
        kRCStoreTypeFilenames: @([self isCheckboxEnabled:self.filenamesCheckbox]),
        kRCStoreTypeURL: @([self isCheckboxEnabled:self.urlCheckbox]),
        kRCStoreTypeTIFF: @([self isCheckboxEnabled:self.imagesTiffCheckbox]),
    };

    [[NSUserDefaults standardUserDefaults] setObject:storeTypes forKey:kRCPrefStoreTypesKey];
}

- (void)setCheckbox:(NSButton *)checkbox enabled:(BOOL)enabled {
    checkbox.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
}

- (BOOL)isCheckboxEnabled:(NSButton *)checkbox {
    return checkbox.state == NSControlStateValueOn;
}

- (BOOL)isStoreTypeEnabledForKey:(NSString *)key inStoreTypes:(NSDictionary<NSString *, id> * _Nullable)storeTypes {
    id value = storeTypes[key];
    if ([value isKindOfClass:[NSNumber class]]) {
        return [((NSNumber *)value) boolValue];
    }
    if ([value isKindOfClass:[NSString class]]) {
        return [((NSString *)value) boolValue];
    }
    return YES;
}

- (void)arrangeSettingsPage {
    self.view = [RCPreferencesPage pageWithRows:@[
        @[[[(NSButton *)[self valueForKey:@"plainTextCheckbox"] title] componentsSeparatedByString:@" (NS"].firstObject, [RCPreferencesPage switchForController:self key:@"plainTextCheckbox"]],
        @[[[(NSButton *)[self valueForKey:@"richTextCheckbox"] title] componentsSeparatedByString:@" (NS"].firstObject, [RCPreferencesPage switchForController:self key:@"richTextCheckbox"]],
        @[[[(NSButton *)[self valueForKey:@"richTextWithAttachmentsCheckbox"] title] componentsSeparatedByString:@" (NS"].firstObject, [RCPreferencesPage switchForController:self key:@"richTextWithAttachmentsCheckbox"]],
        @[[[(NSButton *)[self valueForKey:@"htmlCheckbox"] title] componentsSeparatedByString:@" (NS"].firstObject, [RCPreferencesPage switchForController:self key:@"htmlCheckbox"]],
        @[[[(NSButton *)[self valueForKey:@"pdfCheckbox"] title] componentsSeparatedByString:@" (NS"].firstObject, [RCPreferencesPage switchForController:self key:@"pdfCheckbox"]],
        @[[[(NSButton *)[self valueForKey:@"filenamesCheckbox"] title] componentsSeparatedByString:@" (NS"].firstObject, [RCPreferencesPage switchForController:self key:@"filenamesCheckbox"]],
        @[[[(NSButton *)[self valueForKey:@"urlCheckbox"] title] componentsSeparatedByString:@" (NS"].firstObject, [RCPreferencesPage switchForController:self key:@"urlCheckbox"]],
        @[[[(NSButton *)[self valueForKey:@"imagesTiffCheckbox"] title] componentsSeparatedByString:@" (NS"].firstObject, [RCPreferencesPage switchForController:self key:@"imagesTiffCheckbox"]],
    ]];
}

@end
