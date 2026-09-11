#import "RCLocalization.h"
//
//  RCBetaPreferencesViewController.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import "RCBetaPreferencesViewController.h"
#import "RCConstants.h"
#import "RCScreenshotMonitorService.h"

static NSInteger const kRCBetaModifierMinimumIndex = 0;
static NSInteger const kRCBetaModifierMaximumIndex = 3;

@interface RCBetaPreferencesViewController ()

@property (nonatomic, weak) IBOutlet NSButton *pastePlainTextEnableButton;
@property (nonatomic, weak) IBOutlet NSPopUpButton *pastePlainTextModifierPopUpButton;
@property (nonatomic, weak) IBOutlet NSButton *deleteHistoryEnableButton;
@property (nonatomic, weak) IBOutlet NSPopUpButton *deleteHistoryModifierPopUpButton;
@property (nonatomic, weak) IBOutlet NSButton *pasteAndDeleteHistoryEnableButton;
@property (nonatomic, weak) IBOutlet NSPopUpButton *pasteAndDeleteHistoryModifierPopUpButton;
@property (nonatomic, weak) IBOutlet NSButton *observeScreenshotEnableButton;

- (IBAction)handleEnableCheckboxChanged:(id)sender;
- (IBAction)handleModifierPopUpChanged:(id)sender;

- (void)configureModifierPopUpButtons;
- (void)configureModifierPopUpButton:(NSPopUpButton *)popUpButton;
- (void)configureUnavailableFeatureControls;
- (void)loadSettingsFromUserDefaults;
- (void)applyEnableStateToModifierPopUpButtons;
- (void)updateModifierPopUpButton:(NSPopUpButton *)popUpButton withStoredValue:(NSInteger)value;
- (NSInteger)sanitizedModifierIndex:(NSInteger)value;
- (BOOL)isButtonChecked:(NSButton *)button;
- (BOOL)boolPreferenceForKey:(NSString *)key defaultValue:(BOOL)defaultValue;
- (NSInteger)integerPreferenceForKey:(NSString *)key defaultValue:(NSInteger)defaultValue;

@end

@implementation RCBetaPreferencesViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [RCLocalization localizeView:self.view table:@"RCBetaPreferencesView"];

    [self configureModifierPopUpButtons];
    [self loadSettingsFromUserDefaults];
    [self configureUnavailableFeatureControls];
}

#pragma mark - Actions

- (IBAction)handleEnableCheckboxChanged:(id)sender {
    NSButton *button = (NSButton *)sender;
    if (!button.isEnabled) {
        return;
    }

    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    BOOL isEnabled = [self isButtonChecked:button];

    if (button == self.pastePlainTextEnableButton) {
        [userDefaults setBool:isEnabled forKey:kRCBetaPastePlainText];
    } else if (button == self.deleteHistoryEnableButton) {
        [userDefaults setBool:isEnabled forKey:kRCBetaDeleteHistory];
    } else if (button == self.pasteAndDeleteHistoryEnableButton) {
        [userDefaults setBool:isEnabled forKey:kRCBetaPasteAndDeleteHistory];
    } else if (button == self.observeScreenshotEnableButton) {
        [userDefaults setBool:isEnabled forKey:kRCBetaObserveScreenshot];
        if (isEnabled) {
            [[RCScreenshotMonitorService shared] startMonitoring];
        } else {
            [[RCScreenshotMonitorService shared] stopMonitoring];
        }
    }

    [self applyEnableStateToModifierPopUpButtons];
}

- (IBAction)handleModifierPopUpChanged:(id)sender {
    NSPopUpButton *popUpButton = (NSPopUpButton *)sender;
    if (!popUpButton.isEnabled) {
        return;
    }

    NSInteger selectedIndex = [self sanitizedModifierIndex:popUpButton.indexOfSelectedItem];
    [popUpButton selectItemAtIndex:selectedIndex];

    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    if (popUpButton == self.pastePlainTextModifierPopUpButton) {
        [userDefaults setInteger:selectedIndex forKey:kRCBetaPastePlainTextModifier];
    } else if (popUpButton == self.deleteHistoryModifierPopUpButton) {
        [userDefaults setInteger:selectedIndex forKey:kRCBetaDeleteHistoryModifier];
    } else if (popUpButton == self.pasteAndDeleteHistoryModifierPopUpButton) {
        [userDefaults setInteger:selectedIndex forKey:kRCBetaPasteAndDeleteHistoryModifier];
    }
}

#pragma mark - Private

- (void)configureModifierPopUpButtons {
    [self configureModifierPopUpButton:self.pastePlainTextModifierPopUpButton];
    [self configureModifierPopUpButton:self.deleteHistoryModifierPopUpButton];
    [self configureModifierPopUpButton:self.pasteAndDeleteHistoryModifierPopUpButton];
}

- (void)configureModifierPopUpButton:(NSPopUpButton *)popUpButton {
    [popUpButton removeAllItems];
    [popUpButton addItemsWithTitles:@[
        @"Command",
        @"Shift",
        @"Control",
        @"Option",
    ]];
}

- (void)configureUnavailableFeatureControls {
    NSString *comingSoonText = RCLocalizedString(@"Coming soon", nil);

    self.deleteHistoryEnableButton.enabled = NO;
    self.deleteHistoryModifierPopUpButton.enabled = NO;
    self.pasteAndDeleteHistoryEnableButton.enabled = NO;
    self.pasteAndDeleteHistoryModifierPopUpButton.enabled = NO;

    self.deleteHistoryEnableButton.toolTip = comingSoonText;
    self.deleteHistoryModifierPopUpButton.toolTip = comingSoonText;
    self.pasteAndDeleteHistoryEnableButton.toolTip = comingSoonText;
    self.pasteAndDeleteHistoryModifierPopUpButton.toolTip = comingSoonText;
}

- (void)loadSettingsFromUserDefaults {
    self.pastePlainTextEnableButton.state = [self boolPreferenceForKey:kRCBetaPastePlainText defaultValue:YES] ? NSControlStateValueOn : NSControlStateValueOff;
    self.deleteHistoryEnableButton.state = [self boolPreferenceForKey:kRCBetaDeleteHistory defaultValue:NO] ? NSControlStateValueOn : NSControlStateValueOff;
    self.pasteAndDeleteHistoryEnableButton.state = [self boolPreferenceForKey:kRCBetaPasteAndDeleteHistory defaultValue:NO] ? NSControlStateValueOn : NSControlStateValueOff;
    self.observeScreenshotEnableButton.state = [self boolPreferenceForKey:kRCBetaObserveScreenshot defaultValue:NO] ? NSControlStateValueOn : NSControlStateValueOff;

    NSInteger pastePlainTextModifier = [self integerPreferenceForKey:kRCBetaPastePlainTextModifier defaultValue:0];
    NSInteger deleteHistoryModifier = [self integerPreferenceForKey:kRCBetaDeleteHistoryModifier defaultValue:0];
    NSInteger pasteAndDeleteHistoryModifier = [self integerPreferenceForKey:kRCBetaPasteAndDeleteHistoryModifier defaultValue:0];

    [self updateModifierPopUpButton:self.pastePlainTextModifierPopUpButton withStoredValue:pastePlainTextModifier];
    [self updateModifierPopUpButton:self.deleteHistoryModifierPopUpButton withStoredValue:deleteHistoryModifier];
    [self updateModifierPopUpButton:self.pasteAndDeleteHistoryModifierPopUpButton withStoredValue:pasteAndDeleteHistoryModifier];
    [self applyEnableStateToModifierPopUpButtons];
}

- (void)applyEnableStateToModifierPopUpButtons {
    self.pastePlainTextModifierPopUpButton.enabled = [self isButtonChecked:self.pastePlainTextEnableButton];
    self.deleteHistoryModifierPopUpButton.enabled = NO;
    self.pasteAndDeleteHistoryModifierPopUpButton.enabled = NO;
}

- (void)updateModifierPopUpButton:(NSPopUpButton *)popUpButton withStoredValue:(NSInteger)value {
    NSInteger safeValue = [self sanitizedModifierIndex:value];
    [popUpButton selectItemAtIndex:safeValue];
}

- (NSInteger)sanitizedModifierIndex:(NSInteger)value {
    if (value < kRCBetaModifierMinimumIndex || value > kRCBetaModifierMaximumIndex) {
        return kRCBetaModifierMinimumIndex;
    }
    return value;
}

- (BOOL)isButtonChecked:(NSButton *)button {
    return button.state == NSControlStateValueOn;
}

- (BOOL)boolPreferenceForKey:(NSString *)key defaultValue:(BOOL)defaultValue {
    id rawValue = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    if ([rawValue isKindOfClass:[NSNumber class]]) {
        return [rawValue boolValue];
    }
    if ([rawValue isKindOfClass:[NSString class]]) {
        return [(NSString *)rawValue boolValue];
    }
    return defaultValue;
}

- (NSInteger)integerPreferenceForKey:(NSString *)key defaultValue:(NSInteger)defaultValue {
    id rawValue = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    if ([rawValue isKindOfClass:[NSNumber class]]) {
        return [rawValue integerValue];
    }
    if ([rawValue isKindOfClass:[NSString class]]) {
        return [(NSString *)rawValue integerValue];
    }
    return defaultValue;
}

@end
