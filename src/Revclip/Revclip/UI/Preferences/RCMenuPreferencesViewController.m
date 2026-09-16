#import "RCPreferencesPage.h"
#import "RCLocalization.h"
//
//  RCMenuPreferencesViewController.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Current project: AGPL-3.0-only; legacy portions: MIT. See THIRD_PARTY_NOTICES.md.
//

#import "RCMenuPreferencesViewController.h"
#import "RCConstants.h"

static CGFloat const kRCMenuPreferencesValueFieldWidth = 50.0;

@interface RCMenuPreferencesViewController ()

@property (nonatomic, strong) NSTextField *numberOfItemsInlineTextField;
@property (nonatomic, strong) NSStepper *numberOfItemsInlineStepper;
@property (nonatomic, strong) NSTextField *numberOfItemsInFolderTextField;
@property (nonatomic, strong) NSStepper *numberOfItemsInFolderStepper;
@property (nonatomic, strong) NSTextField *maxTitleLengthTextField;
@property (nonatomic, strong) NSStepper *maxTitleLengthStepper;
@property (nonatomic, strong) NSButton *markWithNumbersButton;
@property (nonatomic, strong) NSButton *startNumberingFromZeroButton;
@property (nonatomic, strong) NSButton *addNumericKeyEquivalentsButton;
@property (nonatomic, strong) NSButton *addClearHistoryItemButton;
@property (nonatomic, strong) NSButton *showAlertBeforeClearButton;
@property (nonatomic, strong) NSButton *showTooltipButton;
@property (nonatomic, strong) NSTextField *maxTooltipLengthTextField;
@property (nonatomic, strong) NSStepper *maxTooltipLengthStepper;
@property (nonatomic, strong) NSButton *showImagePreviewButton;
@property (nonatomic, strong) NSTextField *thumbnailWidthTextField;
@property (nonatomic, strong) NSStepper *thumbnailWidthStepper;
@property (nonatomic, strong) NSTextField *thumbnailHeightTextField;
@property (nonatomic, strong) NSStepper *thumbnailHeightStepper;
@property (nonatomic, strong) NSButton *showColorPreviewButton;
@property (nonatomic, strong) NSButton *showIconButton;
@property (nonatomic, strong) NSTextField *iconSizeTextField;
@property (nonatomic, strong) NSStepper *iconSizeStepper;

@end

@implementation RCMenuPreferencesViewController

- (void)dealloc {
    // Unbind all Cocoa Bindings to prevent dangling KVO observations
    [self.numberOfItemsInlineTextField unbind:NSValueBinding];
    [self.numberOfItemsInlineStepper unbind:NSValueBinding];
    [self.numberOfItemsInFolderTextField unbind:NSValueBinding];
    [self.numberOfItemsInFolderStepper unbind:NSValueBinding];
    [self.maxTitleLengthTextField unbind:NSValueBinding];
    [self.maxTitleLengthStepper unbind:NSValueBinding];
    [self.markWithNumbersButton unbind:NSValueBinding];
    [self.startNumberingFromZeroButton unbind:NSValueBinding];
    [self.startNumberingFromZeroButton unbind:NSEnabledBinding];
    [self.addNumericKeyEquivalentsButton unbind:NSValueBinding];
    [self.addClearHistoryItemButton unbind:NSValueBinding];
    [self.showAlertBeforeClearButton unbind:NSValueBinding];
    [self.showAlertBeforeClearButton unbind:NSEnabledBinding];
    [self.showTooltipButton unbind:NSValueBinding];
    [self.maxTooltipLengthTextField unbind:NSValueBinding];
    [self.maxTooltipLengthTextField unbind:NSEnabledBinding];
    [self.maxTooltipLengthStepper unbind:NSValueBinding];
    [self.maxTooltipLengthStepper unbind:NSEnabledBinding];
    [self.showImagePreviewButton unbind:NSValueBinding];
    [self.thumbnailWidthTextField unbind:NSValueBinding];
    [self.thumbnailWidthTextField unbind:NSEnabledBinding];
    [self.thumbnailWidthStepper unbind:NSValueBinding];
    [self.thumbnailWidthStepper unbind:NSEnabledBinding];
    [self.thumbnailHeightTextField unbind:NSValueBinding];
    [self.thumbnailHeightTextField unbind:NSEnabledBinding];
    [self.thumbnailHeightStepper unbind:NSValueBinding];
    [self.thumbnailHeightStepper unbind:NSEnabledBinding];
    [self.showColorPreviewButton unbind:NSValueBinding];
    [self.showIconButton unbind:NSValueBinding];
    [self.iconSizeTextField unbind:NSValueBinding];
    [self.iconSizeTextField unbind:NSEnabledBinding];
    [self.iconSizeStepper unbind:NSValueBinding];
    [self.iconSizeStepper unbind:NSEnabledBinding];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    [self buildInterface];
    [self configureBindings];
    [self configureDependentBindings];
    [self arrangeSettingsPage];
}

#pragma mark - Interface

- (void)buildInterface {
    self.numberOfItemsInlineTextField = [self numericTextFieldWithMinValue:0 maxValue:99];
    self.numberOfItemsInlineStepper = [self numericStepperWithMinValue:0 maxValue:99];
    self.numberOfItemsInFolderTextField = [self numericTextFieldWithMinValue:1 maxValue:99];
    self.numberOfItemsInFolderStepper = [self numericStepperWithMinValue:1 maxValue:99];
    self.maxTitleLengthTextField = [self numericTextFieldWithMinValue:1 maxValue:200];
    self.maxTitleLengthStepper = [self numericStepperWithMinValue:1 maxValue:200];
    self.markWithNumbersButton = [self checkBoxWithTitle:RCLocalizedString(@"Mark with numbers", nil)];
    self.startNumberingFromZeroButton = [self checkBoxWithTitle:RCLocalizedString(@"Start numbering from 0", nil)];
    self.addNumericKeyEquivalentsButton = [self checkBoxWithTitle:RCLocalizedString(@"Add numeric key equivalents", nil)];
    self.addClearHistoryItemButton = [self checkBoxWithTitle:RCLocalizedString(@"Add clear history item", nil)];
    self.showAlertBeforeClearButton = [self checkBoxWithTitle:RCLocalizedString(@"Show alert before clear", nil)];
    self.showTooltipButton = [self checkBoxWithTitle:RCLocalizedString(@"Show tooltip", nil)];
    self.maxTooltipLengthTextField = [self numericTextFieldWithMinValue:1 maxValue:10000];
    self.maxTooltipLengthStepper = [self numericStepperWithMinValue:1 maxValue:10000];
    self.showImagePreviewButton = [self checkBoxWithTitle:RCLocalizedString(@"Show image preview", nil)];
    self.thumbnailWidthTextField = [self numericTextFieldWithMinValue:16 maxValue:512];
    self.thumbnailWidthStepper = [self numericStepperWithMinValue:16 maxValue:512];
    self.thumbnailHeightTextField = [self numericTextFieldWithMinValue:16 maxValue:512];
    self.thumbnailHeightStepper = [self numericStepperWithMinValue:16 maxValue:512];
    self.showColorPreviewButton = [self checkBoxWithTitle:RCLocalizedString(@"Show color preview", nil)];
    self.showIconButton = [self checkBoxWithTitle:RCLocalizedString(@"Show icon", nil)];
    self.iconSizeTextField = [self numericTextFieldWithMinValue:8 maxValue:64];
    self.iconSizeStepper = [self numericStepperWithMinValue:8 maxValue:64];
}

- (NSTextField *)numericTextFieldWithMinValue:(NSInteger)minValue maxValue:(NSInteger)maxValue {
    NSTextField *textField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    textField.translatesAutoresizingMaskIntoConstraints = NO;
    textField.controlSize = NSControlSizeSmall;
    textField.alignment = NSTextAlignmentRight;
    textField.formatter = [self integerFormatterWithMinValue:minValue maxValue:maxValue];
    [textField.widthAnchor constraintEqualToConstant:kRCMenuPreferencesValueFieldWidth].active = YES;
    return textField;
}

- (NSStepper *)numericStepperWithMinValue:(NSInteger)minValue maxValue:(NSInteger)maxValue {
    NSStepper *stepper = [[NSStepper alloc] initWithFrame:NSZeroRect];
    stepper.translatesAutoresizingMaskIntoConstraints = NO;
    stepper.controlSize = NSControlSizeSmall;
    stepper.minValue = (double)minValue;
    stepper.maxValue = (double)maxValue;
    stepper.increment = 1.0;
    stepper.valueWraps = NO;
    stepper.autorepeat = YES;
    return stepper;
}

- (NSButton *)checkBoxWithTitle:(NSString *)title {
    NSButton *button = [NSButton checkboxWithTitle:title target:nil action:nil];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.controlSize = NSControlSizeSmall;
    button.allowsMixedState = NO;
    return button;
}

- (NSNumberFormatter *)integerFormatterWithMinValue:(NSInteger)minValue maxValue:(NSInteger)maxValue {
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterNoStyle;
    formatter.allowsFloats = NO;
    formatter.minimum = @(minValue);
    formatter.maximum = @(maxValue);
    formatter.usesGroupingSeparator = NO;
    return formatter;
}

#pragma mark - Bindings

- (void)configureBindings {
    [NSUserDefaultsController sharedUserDefaultsController].appliesImmediately = YES;

    [self bindNumericPreferenceKey:kRCPrefNumberOfItemsPlaceInlineKey
                         textField:self.numberOfItemsInlineTextField
                           stepper:self.numberOfItemsInlineStepper];
    [self bindNumericPreferenceKey:kRCPrefNumberOfItemsPlaceInsideFolderKey
                         textField:self.numberOfItemsInFolderTextField
                           stepper:self.numberOfItemsInFolderStepper];
    [self bindNumericPreferenceKey:kRCPrefMaxMenuItemTitleLengthKey
                         textField:self.maxTitleLengthTextField
                           stepper:self.maxTitleLengthStepper];
    [self bindTogglePreferenceKey:kRCMenuItemsAreMarkedWithNumbersKey button:self.markWithNumbersButton];
    [self bindTogglePreferenceKey:kRCPrefMenuItemsTitleStartWithZeroKey button:self.startNumberingFromZeroButton];
    [self bindTogglePreferenceKey:kRCAddNumericKeyEquivalentsKey button:self.addNumericKeyEquivalentsButton];
    [self bindTogglePreferenceKey:kRCPrefAddClearHistoryMenuItemKey button:self.addClearHistoryItemButton];
    [self bindTogglePreferenceKey:kRCPrefShowAlertBeforeClearHistoryKey button:self.showAlertBeforeClearButton];
    [self bindTogglePreferenceKey:kRCShowToolTipOnMenuItemKey button:self.showTooltipButton];
    [self bindNumericPreferenceKey:kRCMaxLengthOfToolTipKey
                         textField:self.maxTooltipLengthTextField
                           stepper:self.maxTooltipLengthStepper];
    [self bindTogglePreferenceKey:kRCShowImageInTheMenuKey button:self.showImagePreviewButton];
    [self bindNumericPreferenceKey:kRCThumbnailWidthKey
                         textField:self.thumbnailWidthTextField
                           stepper:self.thumbnailWidthStepper];
    [self bindNumericPreferenceKey:kRCThumbnailHeightKey
                         textField:self.thumbnailHeightTextField
                           stepper:self.thumbnailHeightStepper];
    [self bindTogglePreferenceKey:kRCPrefShowColorPreviewInTheMenu button:self.showColorPreviewButton];
    [self bindTogglePreferenceKey:kRCPrefShowIconInTheMenuKey button:self.showIconButton];
    [self bindNumericPreferenceKey:kRCPrefMenuIconSizeKey
                         textField:self.iconSizeTextField
                           stepper:self.iconSizeStepper];
}

- (void)configureDependentBindings {
    [self bindEnabledStateForObject:self.startNumberingFromZeroButton
                   toPreferenceKey:kRCMenuItemsAreMarkedWithNumbersKey];
    [self bindEnabledStateForObject:self.maxTooltipLengthTextField
                   toPreferenceKey:kRCShowToolTipOnMenuItemKey];
    [self bindEnabledStateForObject:self.maxTooltipLengthStepper
                   toPreferenceKey:kRCShowToolTipOnMenuItemKey];
    [self bindEnabledStateForObject:self.thumbnailWidthTextField
                   toPreferenceKey:kRCShowImageInTheMenuKey];
    [self bindEnabledStateForObject:self.thumbnailWidthStepper
                   toPreferenceKey:kRCShowImageInTheMenuKey];
    [self bindEnabledStateForObject:self.thumbnailHeightTextField
                   toPreferenceKey:kRCShowImageInTheMenuKey];
    [self bindEnabledStateForObject:self.thumbnailHeightStepper
                   toPreferenceKey:kRCShowImageInTheMenuKey];
    [self bindEnabledStateForObject:self.iconSizeTextField
                   toPreferenceKey:kRCPrefShowIconInTheMenuKey];
    [self bindEnabledStateForObject:self.iconSizeStepper
                   toPreferenceKey:kRCPrefShowIconInTheMenuKey];
    [self bindEnabledStateForObject:self.showAlertBeforeClearButton
                   toPreferenceKey:kRCPrefAddClearHistoryMenuItemKey];
}

- (void)bindNumericPreferenceKey:(NSString *)preferenceKey
                       textField:(NSTextField *)textField
                         stepper:(NSStepper *)stepper {
    NSDictionary *textFieldOptions = @{
        NSContinuouslyUpdatesValueBindingOption: @YES,
    };

    [self bindValueForObject:textField toPreferenceKey:preferenceKey options:textFieldOptions];
    [self bindValueForObject:stepper toPreferenceKey:preferenceKey options:nil];
}

- (void)bindTogglePreferenceKey:(NSString *)preferenceKey button:(NSButton *)button {
    [self bindValueForObject:button toPreferenceKey:preferenceKey options:nil];
}

- (void)bindValueForObject:(id)object
           toPreferenceKey:(NSString *)preferenceKey
                   options:(nullable NSDictionary *)options {
    NSString *keyPath = [NSString stringWithFormat:@"values.%@", preferenceKey];
    [object bind:NSValueBinding
        toObject:[NSUserDefaultsController sharedUserDefaultsController]
     withKeyPath:keyPath
         options:options];
}

- (void)bindEnabledStateForObject:(id)object toPreferenceKey:(NSString *)preferenceKey {
    NSString *keyPath = [NSString stringWithFormat:@"values.%@", preferenceKey];
    [object bind:NSEnabledBinding
        toObject:[NSUserDefaultsController sharedUserDefaultsController]
     withKeyPath:keyPath
         options:nil];
}

- (void)arrangeSettingsPage {
    self.view = [RCPreferencesPage pageWithRows:@[
        @[RCLocalizedString(@"Number of items inline", nil), self.numberOfItemsInlineTextField, self.numberOfItemsInlineStepper],
        @[RCLocalizedString(@"Number of items in folder", nil), self.numberOfItemsInFolderTextField, self.numberOfItemsInFolderStepper],
        @[RCLocalizedString(@"Max title length", nil), self.maxTitleLengthTextField, self.maxTitleLengthStepper],
        @[RCLocalizedString(@"Mark with numbers", nil), [RCPreferencesPage switchForController:self key:@"markWithNumbersButton"]],
        @[RCLocalizedString(@"Start numbering from 0", nil), [RCPreferencesPage switchForController:self key:@"startNumberingFromZeroButton"]],
        @[RCLocalizedString(@"Add numeric key equivalents", nil), [RCPreferencesPage switchForController:self key:@"addNumericKeyEquivalentsButton"]],
        @[RCLocalizedString(@"Add clear history item", nil), [RCPreferencesPage switchForController:self key:@"addClearHistoryItemButton"]],
        @[RCLocalizedString(@"Show alert before clear", nil), [RCPreferencesPage switchForController:self key:@"showAlertBeforeClearButton"]],
        @[RCLocalizedString(@"Show tooltip", nil), [RCPreferencesPage switchForController:self key:@"showTooltipButton"]],
        @[RCLocalizedString(@"Max tooltip length", nil), self.maxTooltipLengthTextField, self.maxTooltipLengthStepper],
        @[RCLocalizedString(@"Show image preview", nil), [RCPreferencesPage switchForController:self key:@"showImagePreviewButton"]],
        @[RCLocalizedString(@"Thumbnail width", nil), self.thumbnailWidthTextField, self.thumbnailWidthStepper],
        @[RCLocalizedString(@"Thumbnail height", nil), self.thumbnailHeightTextField, self.thumbnailHeightStepper],
        @[RCLocalizedString(@"Show color preview", nil), [RCPreferencesPage switchForController:self key:@"showColorPreviewButton"]],
        @[RCLocalizedString(@"Show icon", nil), [RCPreferencesPage switchForController:self key:@"showIconButton"]],
        @[RCLocalizedString(@"Icon size", nil), self.iconSizeTextField, self.iconSizeStepper],
    ]];
}

@end
