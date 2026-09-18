#import "RCPreferencesPage.h"
#import "RCLocalization.h"
//
//  RCShortcutsPreferencesViewController.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Current project: AGPL-3.0-only; legacy portions: MIT. See THIRD_PARTY_NOTICES.md.
//

#import "RCShortcutsPreferencesViewController.h"

#import "RCConstants.h"
#import "RCHotKeyRecorderView.h"
#import "RCHotKeyService.h"
#import "RCSettingsCLIService.h"


@interface RCShortcutsPreferencesViewController () <RCHotKeyRecorderViewDelegate>

@property (nonatomic, weak) IBOutlet RCHotKeyRecorderView *mainMenuRecorderView;
@property (nonatomic, weak) IBOutlet RCHotKeyRecorderView *historyMenuRecorderView;
@property (nonatomic, weak) IBOutlet RCHotKeyRecorderView *snippetMenuRecorderView;
@property (nonatomic, weak) IBOutlet RCHotKeyRecorderView *clearHistoryRecorderView;

- (void)reloadRecordersFromDefaults;
- (void)resetHotKeysToDefaults;

@end

@implementation RCShortcutsPreferencesViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [RCLocalization localizeView:self.view table:@"RCShortcutsPreferencesView"];

    self.mainMenuRecorderView.delegate = self;
    self.historyMenuRecorderView.delegate = self;
    self.snippetMenuRecorderView.delegate = self;
    self.clearHistoryRecorderView.delegate = self;

    [self reloadRecordersFromDefaults];
    [self arrangeSettingsPage];
}

// The CLI can change the same shortcuts while this page is open or hidden.
- (void)viewWillAppear {
    [super viewWillAppear];
    [self reloadRecordersFromDefaults];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadRecordersFromDefaults)
                                               name:RCSettingsDidChangeNotification object:nil];
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    [NSNotificationCenter.defaultCenter removeObserver:self name:RCSettingsDidChangeNotification object:nil];
}

#pragma mark - Actions

- (IBAction)resetToDefaults:(id)sender {
    (void)sender;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = RCLocalizedString(@"Reset all shortcuts to defaults?", nil);
    alert.informativeText = RCLocalizedString(@"Main Menu, History Menu, and Snippet Menu will be restored. Clear History will be removed.", nil);
    [alert addButtonWithTitle:RCLocalizedString(@"Reset", nil)];
    [alert addButtonWithTitle:RCLocalizedString(@"Cancel", nil)];

    NSWindow *window = self.view.window;
    if (window != nil) {
        __weak typeof(self) weakSelf = self;
        [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse returnCode) {
            typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            if (returnCode == NSAlertFirstButtonReturn) {
                [strongSelf resetHotKeysToDefaults];
            }
        }];
        return;
    }

    if ([alert runModal] == NSAlertFirstButtonReturn) {
        [self resetHotKeysToDefaults];
    }
}

#pragma mark - RCHotKeyRecorderViewDelegate

- (void)hotKeyRecorderView:(RCHotKeyRecorderView *)recorderView didRecordKeyCombo:(RCKeyCombo)keyCombo {
    NSString *slot = [self slotForRecorderView:recorderView];
    if (slot == nil) { return; }
    [self applyAssignments:@[[RCHotKeyAssignment assignmentSettingSlot:slot combo:keyCombo]]];
}

- (void)hotKeyRecorderViewDidClearKeyCombo:(RCHotKeyRecorderView *)recorderView {
    NSString *slot = [self slotForRecorderView:recorderView];
    if (slot == nil) { return; }
    [self applyAssignments:@[[RCHotKeyAssignment assignmentClearingSlot:slot]]];
}

// Validation, registration and storage are one service contract shared with the
// faster OCR page and the CLI. A refused shortcut leaves the previous one working,
// and the recorder shows that previous value again.
- (void)applyAssignments:(NSArray<RCHotKeyAssignment *> *)assignments {
    RCHotKeyAssignmentResult *result = [[RCHotKeyService shared] applyAssignments:assignments];
    [self reloadRecordersFromDefaults];
    [self.mainMenuRecorderView showAssignmentResult:result];
}

- (nullable NSString *)slotForRecorderView:(RCHotKeyRecorderView *)recorderView {
    if (recorderView == self.mainMenuRecorderView) { return RCHotKeySlotMain; }
    if (recorderView == self.historyMenuRecorderView) { return RCHotKeySlotHistory; }
    if (recorderView == self.snippetMenuRecorderView) { return RCHotKeySlotSnippet; }
    if (recorderView == self.clearHistoryRecorderView) { return RCHotKeySlotClearHistory; }
    return nil;
}

#pragma mark - Private

- (void)reloadRecordersFromDefaults {
    RCHotKeyService *service = [RCHotKeyService shared];
    self.mainMenuRecorderView.keyCombo = [service configuredKeyComboForSlot:RCHotKeySlotMain];
    self.historyMenuRecorderView.keyCombo = [service configuredKeyComboForSlot:RCHotKeySlotHistory];
    self.snippetMenuRecorderView.keyCombo = [service configuredKeyComboForSlot:RCHotKeySlotSnippet];
    self.clearHistoryRecorderView.keyCombo = [service configuredKeyComboForSlot:RCHotKeySlotClearHistory];
}

- (void)resetHotKeysToDefaults {
    // One batch: the defaults are checked against each other and applied together.
    [self applyAssignments:@[[RCHotKeyAssignment assignmentRestoringDefaultForSlot:RCHotKeySlotMain],
                             [RCHotKeyAssignment assignmentRestoringDefaultForSlot:RCHotKeySlotHistory],
                             [RCHotKeyAssignment assignmentRestoringDefaultForSlot:RCHotKeySlotSnippet],
                             [RCHotKeyAssignment assignmentRestoringDefaultForSlot:RCHotKeySlotClearHistory]]];
}

- (void)arrangeSettingsPage {
    NSTextField *warning = [NSTextField wrappingLabelWithString:@""];
    warning.textColor = NSColor.systemYellowColor;
    for (RCHotKeyRecorderView *recorder in @[self.mainMenuRecorderView, self.historyMenuRecorderView, self.snippetMenuRecorderView, self.clearHistoryRecorderView]) recorder.warningLabel = warning;
    self.view = [RCPreferencesPage pageWithRows:@[
        @[([RCLocalization titleForIdentifier:@"ZgK-s1-dYB" table:@"RCShortcutsPreferencesView"] ?: @"メインメニュー:"), self.mainMenuRecorderView],
        @[([RCLocalization titleForIdentifier:@"xhM-yq-5Ef" table:@"RCShortcutsPreferencesView"] ?: @"履歴メニュー:"), self.historyMenuRecorderView],
        @[([RCLocalization titleForIdentifier:@"MV8-qY-5rU" table:@"RCShortcutsPreferencesView"] ?: @"テンプレートメニュー:"), self.snippetMenuRecorderView],
        @[([RCLocalization titleForIdentifier:@"W4b-7h-QK2" table:@"RCShortcutsPreferencesView"] ?: @"履歴消去:"), self.clearHistoryRecorderView],
        @[@"", warning],
        @[ @"", [NSButton buttonWithTitle:([RCLocalization titleForIdentifier:@"D9f-HL-0Nb" table:@"RCShortcutsPreferencesView"] ?: RCLocalizedString(@"Reset to Defaults", nil)) target:self action:@selector(resetToDefaults:)] ],
    ]];
}

@end
