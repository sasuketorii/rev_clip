#import "RCSetupPreferencesViewController.h"
#import "RCKeyboardShortcutView.h"
#import "RCHotKeyRecorderView.h"
#import "RCPreferencesPage.h"
#import "RCPreferencesWindowController.h"
#import "RCSettingsCLIService.h"
#import "RCLocalization.h"
#import "Revclip-Swift.h"

@interface RCSetupPreferencesViewController () <RCHotKeyRecorderViewDelegate>
@property (nonatomic, strong) NSSegmentedControl *featureSelector;
@property (nonatomic, strong) NSStackView *pageStack;
@property (nonatomic, strong) NSStackView *shortcutContent;
@property (nonatomic, strong) RCPermissionsPreferencesController *permissionsController;
@property (nonatomic, strong) NSView *displayedContent;
@property (nonatomic, strong) NSLayoutConstraint *contentWidth;
@property (nonatomic, strong) RCKeyboardShortcutView *keyboard;
@property (nonatomic, strong) RCHotKeyRecorderView *recorder;
@property (nonatomic, strong) NSTextField *defaultLabel;
@property (nonatomic, strong) NSTextField *layoutNote;
@property (nonatomic, strong) NSButton *ocrSettingsButton;
@property (nonatomic, copy) NSString *selectedSlot;
@property (nonatomic, copy) NSString *warningConflictSlot;
@property (nonatomic, copy) NSDictionary *warningShortcutState;
@end

@implementation RCSetupPreferencesViewController
- (RCHotKeyService *)hotKeyService { return RCHotKeyService.shared; }
- (void)loadView {
    self.selectedSlot = RCHotKeySlotMain;
    RCPreferencesPage *page = [RCPreferencesPage new];
    NSStackView *stack = [NSStackView new];
    self.pageStack = stack;
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 20;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [page addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:page.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:page.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:page.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:page.bottomAnchor constant:-16],
    ]];
    NSTextField *intro = [NSTextField wrappingLabelWithString:RCLocalizedString(@"Choose the shortcuts that feel natural to you. The highlighted keys show your saved shortcut.", nil)];
    intro.font = [NSFont systemFontOfSize:14];
    intro.textColor = NSColor.secondaryLabelColor;
    self.featureSelector = [NSSegmentedControl segmentedControlWithLabels:@[RCLocalizedString(@"Permission Status", nil), RCLocalizedString(@"Clipboard menu", nil), @"FasterOCR"]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(featureChanged:)];
    self.featureSelector.segmentDistribution = NSSegmentDistributionFillEqually;
    self.featureSelector.selectedSegment = 0;
    self.featureSelector.accessibilityLabel = RCLocalizedString(@"Setup", nil);
    self.keyboard = [RCKeyboardShortcutView new];
    self.recorder = [RCHotKeyRecorderView new];
    self.recorder.delegate = self;
    NSTextField *warning = [NSTextField wrappingLabelWithString:@""];
    warning.textColor = NSColor.systemYellowColor;
    self.recorder.warningLabel = warning;
    self.recorder.accessibilityLabel = RCLocalizedString(@"Shortcut", nil);
    NSView *recording = [RCPreferencesPage pageWithRows:@[@[RCLocalizedString(@"Shortcut", nil), self.recorder]]];
    NSTextField *instructions = [NSTextField wrappingLabelWithString:RCLocalizedString(@"Click the shortcut field, then press your preferred keys. Conflicting shortcuts will not replace your current setting.", nil)];
    instructions.textColor = NSColor.secondaryLabelColor;
    self.defaultLabel = [NSTextField wrappingLabelWithString:@""];
    self.defaultLabel.textColor = NSColor.secondaryLabelColor;
    self.layoutNote = [NSTextField wrappingLabelWithString:@""];
    self.layoutNote.textColor = NSColor.secondaryLabelColor;
    NSButton *restore = [NSButton buttonWithTitle:RCLocalizedString(@"Restore this shortcut's default", nil) target:self action:@selector(restoreDefault:)];
    self.ocrSettingsButton = [NSButton buttonWithTitle:RCLocalizedString(@"Open faster OCR settings", nil) target:self action:@selector(openOCRSettings:)];
    NSStackView *actions = [NSStackView stackViewWithViews:@[restore, self.ocrSettingsButton]];
    actions.spacing = 12;
    self.shortcutContent = [NSStackView new];
    self.shortcutContent.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.shortcutContent.alignment = NSLayoutAttributeLeading;
    self.shortcutContent.spacing = 20;
    self.shortcutContent.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:self.featureSelector];
    self.featureSelector.translatesAutoresizingMaskIntoConstraints = NO;
    [self.featureSelector.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    for (NSView *view in @[intro, self.keyboard, recording, warning, instructions, self.defaultLabel, self.layoutNote, actions]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [self.shortcutContent addArrangedSubview:view];
        [view.widthAnchor constraintEqualToAnchor:self.shortcutContent.widthAnchor].active = YES;
    }
    [self.featureSelector.heightAnchor constraintEqualToConstant:32].active = YES;
    [self.keyboard.heightAnchor constraintEqualToAnchor:self.keyboard.widthAnchor multiplier:1046.0/2546.0].active = YES;
    self.view = page;
    [self refreshShortcuts];
    [self featureChanged:self.featureSelector];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(defaultsChanged:) name:NSUserDefaultsDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(defaultsChanged:) name:RCSettingsDidChangeNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)viewWillAppear { [super viewWillAppear]; self.recorder.warningLabel.stringValue = @""; [self refreshShortcuts]; }
- (void)viewWillDisappear { [self.recorder stopRecording]; [super viewWillDisappear]; }
- (void)defaultsChanged:(NSNotification *)notification {
    if (!NSThread.isMainThread) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf defaultsChanged:nil]; });
        return;
    }
    if (!self.recorder.isRecording) {
        if (![self.warningShortcutState isEqual:[self shortcutState]]) self.recorder.warningLabel.stringValue = @"";
        if (self.view.window) [self refreshShortcuts];
    }
}
- (NSDictionary *)shortcutState {
    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    NSMutableArray *slots = [@[RCHotKeySlotMain, RCHotKeySlotOCR, RCHotKeySlotHistory, RCHotKeySlotSnippet, RCHotKeySlotClearHistory] mutableCopy];
    if (self.warningConflictSlot.length) [slots addObject:self.warningConflictSlot];
    for (NSString *slot in slots) {
        RCKeyCombo combo = [self.hotKeyService configuredKeyComboForSlot:slot];
        state[slot] = @[@(combo.keyCode), @(combo.modifiers)];
    }
    return state;
}
- (void)refreshShortcuts {
    RCKeyCombo combo = [self.hotKeyService configuredKeyComboForSlot:self.selectedSlot];
    if (self.recorder.keyCombo.keyCode != combo.keyCode || self.recorder.keyCombo.modifiers != combo.modifiers)
        self.recorder.warningLabel.stringValue = @"";
    self.recorder.keyCombo = combo;
    self.keyboard.keyCombo = combo;
    NSString *defaultKeys = [RCHotKeyRecorderView displayStringForKeyCombo:[RCHotKeyService defaultKeyComboForSlot:self.selectedSlot]];
    self.defaultLabel.stringValue = [NSString stringWithFormat:RCLocalizedString(@"Default: %@", nil), defaultKeys];
    BOOL externalKey = RCIsValidKeyCombo(combo) && NSIsEmptyRect([RCKeyboardShortcutView imageRectForKeyCode:combo.keyCode]);
    self.layoutNote.stringValue = RCLocalizedString(externalKey ? @"This key is not on the pictured US keyboard. Your shortcut is shown in the field above." : @"US keyboard illustration. Modifier keys are shown on the left; either side works.", nil);
    self.ocrSettingsButton.hidden = ![self.selectedSlot isEqualToString:RCHotKeySlotOCR];
    // Revalidate saved assignments too. Preserve a refusal for a newly attempted
    // value until the user changes context; no registration or preference writes.
    if (self.featureSelector.selectedSegment != 0 && self.recorder.warningLabel.stringValue.length == 0) {
        RCHotKeyAssignmentResult *result = [self.hotKeyService validateAssignments:@[[RCHotKeyAssignment assignmentKeepingSlot:self.selectedSlot]]];
        if (!result.succeeded) {
            self.warningConflictSlot = result.conflictingSlot;
            self.warningShortcutState = [self shortcutState];
            [self.recorder showAssignmentResult:result];
        }
    }
}
- (void)showPermissions {
    (void)self.view;
    self.featureSelector.selectedSegment = 0;
    [self featureChanged:self.featureSelector];
}
- (void)featureChanged:(NSSegmentedControl *)sender {
    [self.recorder stopRecording];
    // A refusal describes the attempted assignment in the previous slot, not
    // the shortcut already owned by the newly selected feature.
    self.recorder.warningLabel.stringValue = @"";
    NSView *content;
    if (sender.selectedSegment == 0) {
        if (!self.permissionsController) {
            self.permissionsController = [RCPermissionsPreferencesController new];
            [self addChildViewController:self.permissionsController];
        }
        content = self.permissionsController.view;
    } else {
        self.selectedSlot = sender.selectedSegment == 2 ? RCHotKeySlotOCR : RCHotKeySlotMain;
        content = self.shortcutContent;
    }
    if (content != self.displayedContent) {
        self.contentWidth.active = NO;
        if (self.displayedContent) [self.pageStack removeArrangedSubview:self.displayedContent];
        [self.displayedContent removeFromSuperview];
        content.translatesAutoresizingMaskIntoConstraints = NO;
        [self.pageStack addArrangedSubview:content];
        self.contentWidth = [content.widthAnchor constraintEqualToAnchor:self.pageStack.widthAnchor];
        self.contentWidth.active = YES;
        self.displayedContent = content;
    }
    [self refreshShortcuts];
    [self.featureSelector scrollRectToVisible:self.featureSelector.bounds];
}
- (void)applyAssignment:(RCHotKeyAssignment *)assignment {
    RCHotKeyAssignmentResult *result = [self.hotKeyService applyAssignments:@[assignment]];
    [self refreshShortcuts]; // Read the committed value, including a refused assignment.
    self.warningConflictSlot = result.conflictingSlot;
    self.warningShortcutState = [self shortcutState];
    [self.recorder showAssignmentResult:result];
}
- (void)hotKeyRecorderView:(RCHotKeyRecorderView *)view didRecordKeyCombo:(RCKeyCombo)combo {
    [self applyAssignment:[RCHotKeyAssignment assignmentSettingSlot:self.selectedSlot combo:combo]];
}
- (void)hotKeyRecorderViewDidClearKeyCombo:(RCHotKeyRecorderView *)view {
    [self applyAssignment:[RCHotKeyAssignment assignmentClearingSlot:self.selectedSlot]];
}
- (void)restoreDefault:(id)sender {
    [self.recorder stopRecording];
    [self applyAssignment:[RCHotKeyAssignment assignmentRestoringDefaultForSlot:self.selectedSlot]];
}
- (void)openOCRSettings:(id)sender { [RCPreferencesWindowController.shared showTab:@"ocr"]; }
@end
