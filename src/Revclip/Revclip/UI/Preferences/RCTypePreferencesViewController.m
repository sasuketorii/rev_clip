//
//  RCTypePreferencesViewController.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
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

    NSDictionary<NSString *, id> *storeTypes = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kRCPrefStoreTypesKey];
    [self setCheckbox:self.plainTextCheckbox enabled:[self isStoreTypeEnabledForKey:kRCStoreTypeString inStoreTypes:storeTypes]];
    [self setCheckbox:self.richTextCheckbox enabled:[self isStoreTypeEnabledForKey:kRCStoreTypeRTF inStoreTypes:storeTypes]];
    [self setCheckbox:self.richTextWithAttachmentsCheckbox enabled:[self isStoreTypeEnabledForKey:kRCStoreTypeRTFD inStoreTypes:storeTypes]];
    [self setCheckbox:self.pdfCheckbox enabled:[self isStoreTypeEnabledForKey:kRCStoreTypePDF inStoreTypes:storeTypes]];
    [self setCheckbox:self.filenamesCheckbox enabled:[self isStoreTypeEnabledForKey:kRCStoreTypeFilenames inStoreTypes:storeTypes]];
    [self setCheckbox:self.urlCheckbox enabled:[self isStoreTypeEnabledForKey:kRCStoreTypeURL inStoreTypes:storeTypes]];
    [self setCheckbox:self.imagesTiffCheckbox enabled:[self isStoreTypeEnabledForKey:kRCStoreTypeTIFF inStoreTypes:storeTypes]];
}

- (IBAction)storeTypeCheckboxDidChange:(id)sender {
    (void)sender;

    NSDictionary<NSString *, NSNumber *> *storeTypes = @{
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

@end
