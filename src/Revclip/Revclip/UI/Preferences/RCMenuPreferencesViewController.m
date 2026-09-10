//
//  RCMenuPreferencesViewController.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import "RCMenuPreferencesViewController.h"
#import "RCConstants.h"

static CGFloat const kRCMenuPreferencesContentInset = 16.0;
static CGFloat const kRCMenuPreferencesColumnSpacing = 12.0;
static CGFloat const kRCMenuPreferencesRowSpacing = 10.0;
static CGFloat const kRCMenuPreferencesRowLabelWidth = 132.0;
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
}

#pragma mark - Interface

- (void)buildInterface {
    NSTextField *titleLabel = [self sectionLabelWithText:NSLocalizedString(@"Menu Settings", nil)];
    NSStackView *leftColumn = [self columnStackView];
    NSStackView *rightColumn = [self columnStackView];

    self.numberOfItemsInlineTextField = [self numericTextFieldWithMinValue:0 maxValue:99];
    self.numberOfItemsInlineStepper = [self numericStepperWithMinValue:0 maxValue:99];
    [leftColumn addArrangedSubview:[self numericRowWithTitle:NSLocalizedString(@"Number of items inline", nil)
                                                   textField:self.numberOfItemsInlineTextField
                                                     stepper:self.numberOfItemsInlineStepper]];

    self.numberOfItemsInFolderTextField = [self numericTextFieldWithMinValue:1 maxValue:99];
    self.numberOfItemsInFolderStepper = [self numericStepperWithMinValue:1 maxValue:99];
    [leftColumn addArrangedSubview:[self numericRowWithTitle:NSLocalizedString(@"Number of items in folder", nil)
                                                   textField:self.numberOfItemsInFolderTextField
                                                     stepper:self.numberOfItemsInFolderStepper]];

    self.maxTitleLengthTextField = [self numericTextFieldWithMinValue:1 maxValue:200];
    self.maxTitleLengthStepper = [self numericStepperWithMinValue:1 maxValue:200];
    [leftColumn addArrangedSubview:[self numericRowWithTitle:NSLocalizedString(@"Max title length", nil)
                                                   textField:self.maxTitleLengthTextField
                                                     stepper:self.maxTitleLengthStepper]];

    self.markWithNumbersButton = [self checkBoxWithTitle:NSLocalizedString(@"Mark with numbers", nil)];
    [leftColumn addArrangedSubview:self.markWithNumbersButton];

    self.startNumberingFromZeroButton = [self checkBoxWithTitle:NSLocalizedString(@"Start numbering from 0", nil)];
    [leftColumn addArrangedSubview:self.startNumberingFromZeroButton];

    self.addNumericKeyEquivalentsButton = [self checkBoxWithTitle:NSLocalizedString(@"Add numeric key equivalents", nil)];
    [leftColumn addArrangedSubview:self.addNumericKeyEquivalentsButton];

    self.addClearHistoryItemButton = [self checkBoxWithTitle:NSLocalizedString(@"Add clear history item", nil)];
    [leftColumn addArrangedSubview:self.addClearHistoryItemButton];

    self.showAlertBeforeClearButton = [self checkBoxWithTitle:NSLocalizedString(@"Show alert before clear", nil)];
    [leftColumn addArrangedSubview:self.showAlertBeforeClearButton];

    self.showTooltipButton = [self checkBoxWithTitle:NSLocalizedString(@"Show tooltip", nil)];
    [rightColumn addArrangedSubview:self.showTooltipButton];

    self.maxTooltipLengthTextField = [self numericTextFieldWithMinValue:1 maxValue:10000];
    self.maxTooltipLengthStepper = [self numericStepperWithMinValue:1 maxValue:10000];
    [rightColumn addArrangedSubview:[self numericRowWithTitle:NSLocalizedString(@"Max tooltip length", nil)
                                                    textField:self.maxTooltipLengthTextField
                                                      stepper:self.maxTooltipLengthStepper]];

    self.showImagePreviewButton = [self checkBoxWithTitle:NSLocalizedString(@"Show image preview", nil)];
    [rightColumn addArrangedSubview:self.showImagePreviewButton];

    self.thumbnailWidthTextField = [self numericTextFieldWithMinValue:16 maxValue:512];
    self.thumbnailWidthStepper = [self numericStepperWithMinValue:16 maxValue:512];
    [rightColumn addArrangedSubview:[self numericRowWithTitle:NSLocalizedString(@"Thumbnail width", nil)
                                                    textField:self.thumbnailWidthTextField
                                                      stepper:self.thumbnailWidthStepper]];

    self.thumbnailHeightTextField = [self numericTextFieldWithMinValue:16 maxValue:512];
    self.thumbnailHeightStepper = [self numericStepperWithMinValue:16 maxValue:512];
    [rightColumn addArrangedSubview:[self numericRowWithTitle:NSLocalizedString(@"Thumbnail height", nil)
                                                    textField:self.thumbnailHeightTextField
                                                      stepper:self.thumbnailHeightStepper]];

    self.showColorPreviewButton = [self checkBoxWithTitle:NSLocalizedString(@"Show color preview", nil)];
    [rightColumn addArrangedSubview:self.showColorPreviewButton];

    self.showIconButton = [self checkBoxWithTitle:NSLocalizedString(@"Show icon", nil)];
    [rightColumn addArrangedSubview:self.showIconButton];

    self.iconSizeTextField = [self numericTextFieldWithMinValue:8 maxValue:64];
    self.iconSizeStepper = [self numericStepperWithMinValue:8 maxValue:64];
    [rightColumn addArrangedSubview:[self numericRowWithTitle:NSLocalizedString(@"Icon size", nil)
                                                    textField:self.iconSizeTextField
                                                      stepper:self.iconSizeStepper]];

    NSStackView *columnsStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    columnsStack.translatesAutoresizingMaskIntoConstraints = NO;
    columnsStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    columnsStack.alignment = NSLayoutAttributeTop;
    columnsStack.distribution = NSStackViewDistributionFillEqually;
    columnsStack.spacing = kRCMenuPreferencesColumnSpacing;
    [columnsStack addArrangedSubview:leftColumn];
    [columnsStack addArrangedSubview:rightColumn];

    [self.view addSubview:titleLabel];
    [self.view addSubview:columnsStack];

    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:kRCMenuPreferencesContentInset],
        [titleLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:kRCMenuPreferencesContentInset],

        [columnsStack.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:12.0],
        [columnsStack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:kRCMenuPreferencesContentInset],
        [columnsStack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-kRCMenuPreferencesContentInset],
        [columnsStack.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.bottomAnchor constant:-kRCMenuPreferencesContentInset],
    ]];
}

- (NSTextField *)sectionLabelWithText:(NSString *)text {
    NSTextField *label = [NSTextField labelWithString:text];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [NSFont boldSystemFontOfSize:13.0];
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

- (NSStackView *)columnStackView {
    NSStackView *stackView = [[NSStackView alloc] initWithFrame:NSZeroRect];
    stackView.translatesAutoresizingMaskIntoConstraints = NO;
    stackView.orientation = NSUserInterfaceLayoutOrientationVertical;
    stackView.alignment = NSLayoutAttributeLeading;
    stackView.distribution = NSStackViewDistributionFill;
    stackView.spacing = kRCMenuPreferencesRowSpacing;
    return stackView;
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

- (NSView *)numericRowWithTitle:(NSString *)title textField:(NSTextField *)textField stepper:(NSStepper *)stepper {
    NSTextField *label = [NSTextField labelWithString:title];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    [label.widthAnchor constraintEqualToConstant:kRCMenuPreferencesRowLabelWidth].active = YES;

    NSStackView *controlStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    controlStack.translatesAutoresizingMaskIntoConstraints = NO;
    controlStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    controlStack.alignment = NSLayoutAttributeCenterY;
    controlStack.distribution = NSStackViewDistributionFill;
    controlStack.spacing = 6.0;
    [controlStack addArrangedSubview:textField];
    [controlStack addArrangedSubview:stepper];

    NSStackView *row = [[NSStackView alloc] initWithFrame:NSZeroRect];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.distribution = NSStackViewDistributionFill;
    row.spacing = 8.0;
    [row addArrangedSubview:label];
    [row addArrangedSubview:controlStack];

    return row;
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

@end
