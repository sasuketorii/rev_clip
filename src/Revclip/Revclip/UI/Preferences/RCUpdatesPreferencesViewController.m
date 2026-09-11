#import "RCLocalization.h"
//
//  RCUpdatesPreferencesViewController.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import "RCUpdatesPreferencesViewController.h"

#import "RCUpdateService.h"

static const NSInteger kRCDefaultUpdateCheckInterval = 86400;

@interface RCUpdatesPreferencesViewController ()

@property (nonatomic, weak) IBOutlet NSButton *automaticCheckButton;
@property (nonatomic, weak) IBOutlet NSPopUpButton *checkIntervalPopUpButton;
@property (nonatomic, weak) IBOutlet NSButton *checkNowButton;
@property (nonatomic, weak) IBOutlet NSProgressIndicator *checkProgressIndicator;
@property (nonatomic, weak) IBOutlet NSTextField *versionInfoLabel;
@property (nonatomic, strong, nullable) dispatch_source_t checkCompletionTimer;

@end

@implementation RCUpdatesPreferencesViewController

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:RCUpdateServiceDidFailNotification
                                                  object:[RCUpdateService shared]];
    [self cancelCheckCompletionTimer];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [RCLocalization localizeView:self.view table:@"RCUpdatesPreferencesView"];

    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
    [notificationCenter addObserver:self
                           selector:@selector(handleUpdateServiceFailureNotification:)
                               name:RCUpdateServiceDidFailNotification
                             object:[RCUpdateService shared]];

    [self loadUpdateSettings];
    [self updateVersionInfo];
}

- (void)loadUpdateSettings {
    RCUpdateService *updateService = [RCUpdateService shared];
    BOOL automaticCheckEnabled = updateService.automaticallyChecksForUpdates;
    self.automaticCheckButton.state = automaticCheckEnabled ? NSControlStateValueOn : NSControlStateValueOff;

    NSInteger intervalInSeconds = (NSInteger)updateService.updateCheckInterval;
    NSMenuItem *intervalItem = [self.checkIntervalPopUpButton.menu itemWithTag:intervalInSeconds];
    if (intervalItem == nil) {
        intervalInSeconds = kRCDefaultUpdateCheckInterval;
        updateService.updateCheckInterval = (NSTimeInterval)intervalInSeconds;
    }
    [self.checkIntervalPopUpButton selectItemWithTag:intervalInSeconds];

    [self updateIntervalControlState];
}

- (void)updateVersionInfo {
    NSDictionary<NSString *, id> *infoDictionary = NSBundle.mainBundle.infoDictionary;
    NSString *shortVersion = [infoDictionary[@"CFBundleShortVersionString"] isKindOfClass:NSString.class] ? infoDictionary[@"CFBundleShortVersionString"] : @"";
    NSString *buildVersion = [infoDictionary[@"CFBundleVersion"] isKindOfClass:NSString.class] ? infoDictionary[@"CFBundleVersion"] : @"";

    if (shortVersion.length > 0 && buildVersion.length > 0) {
        self.versionInfoLabel.stringValue = [NSString stringWithFormat:RCLocalizedString(@"Version %@ (%@)", nil), shortVersion, buildVersion];
        return;
    }
    if (shortVersion.length > 0) {
        self.versionInfoLabel.stringValue = [NSString stringWithFormat:RCLocalizedString(@"Version %@", nil), shortVersion];
        return;
    }
    if (buildVersion.length > 0) {
        self.versionInfoLabel.stringValue = [NSString stringWithFormat:RCLocalizedString(@"Build %@", nil), buildVersion];
        return;
    }

    self.versionInfoLabel.stringValue = RCLocalizedString(@"Version -", nil);
}

- (void)updateIntervalControlState {
    BOOL automaticCheckEnabled = self.automaticCheckButton.state == NSControlStateValueOn;
    self.checkIntervalPopUpButton.enabled = automaticCheckEnabled;
}

- (IBAction)automaticCheckToggled:(NSButton *)sender {
    BOOL automaticCheckEnabled = sender.state == NSControlStateValueOn;
    [RCUpdateService shared].automaticallyChecksForUpdates = automaticCheckEnabled;
    [self updateIntervalControlState];
}

- (IBAction)checkIntervalChanged:(NSPopUpButton *)sender {
    NSInteger intervalInSeconds = sender.selectedTag;
    if (intervalInSeconds <= 0) {
        intervalInSeconds = kRCDefaultUpdateCheckInterval;
        [sender selectItemWithTag:intervalInSeconds];
    }

    [RCUpdateService shared].updateCheckInterval = (NSTimeInterval)intervalInSeconds;
}

- (IBAction)checkNowClicked:(id)sender {
    (void)sender;

    RCUpdateService *updateService = [RCUpdateService shared];

    self.checkNowButton.enabled = NO;
    self.checkProgressIndicator.hidden = NO;
    [self.checkProgressIndicator startAnimation:nil];

    BOOL didStartCheck = [updateService checkForUpdates];
    if (didStartCheck) {
        [self startCheckCompletionPolling];
    } else {
        [self restoreManualCheckUIState];
    }
}

- (void)cancelCheckCompletionTimer {
    if (self.checkCompletionTimer != nil) {
        dispatch_source_cancel(self.checkCompletionTimer);
        self.checkCompletionTimer = nil;
    }
}

- (void)startCheckCompletionPolling {
    // Cancel any existing polling timer to prevent duplicates
    [self cancelCheckCompletionTimer];

    __block NSInteger pollCount = 0;
    __weak typeof(self) weakSelf = self;

    // Sparkle の canCheckForUpdates が YES に戻るまでポーリング（最大60回 = 30秒）
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                              (uint64_t)(0.5 * NSEC_PER_SEC),
                              (uint64_t)(0.1 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            dispatch_source_cancel(timer);
            return;
        }

        pollCount++;
        BOOL canCheck = [RCUpdateService shared].canCheckForUpdates;
        if (canCheck || pollCount >= 60) {
            strongSelf.checkNowButton.enabled = YES;
            [strongSelf.checkProgressIndicator stopAnimation:nil];
            strongSelf.checkProgressIndicator.hidden = YES;
            [strongSelf cancelCheckCompletionTimer];
        }
    });

    self.checkCompletionTimer = timer;
    dispatch_resume(timer);
}

- (void)handleUpdateServiceFailureNotification:(NSNotification *)notification {
    if (notification.object != [RCUpdateService shared]) {
        NSLog(@"[RCUpdatesPreferencesViewController] Ignoring update failure from unexpected sender.");
        return;
    }

    RCUpdateServiceUpdateCheck updateCheck = [self normalizedUpdateCheckFromNotification:notification];

    if ([self shouldRestoreManualCheckUIStateForUpdateCheck:updateCheck]) {
        [self restoreManualCheckUIState];
    }

    if (![self shouldShowFailureAlertForUpdateCheck:updateCheck]) {
        NSLog(@"[RCUpdatesPreferencesViewController] Ignoring non-user initiated update failure (check: %ld).",
              (long)updateCheck);
        return;
    }

    id errorObject = notification.userInfo[RCUpdateServiceErrorUserInfoKey];
    id reasonObject = notification.userInfo[RCUpdateServiceFailureReasonUserInfoKey];
    NSString *errorDescription = nil;
    if ([errorObject isKindOfClass:[NSError class]]) {
        errorDescription = ((NSError *)errorObject).localizedDescription;
    }
    NSString *failureReason = [reasonObject isKindOfClass:NSString.class] ? (NSString *)reasonObject : @"";
    NSLog(@"[RCUpdatesPreferencesViewController] Update service failure: %@ (reason: %@)",
          errorDescription.length > 0 ? errorDescription : @"Unknown error",
          failureReason.length > 0 ? failureReason : @"No reason");

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = RCLocalizedString(@"アップデートの確認に失敗しました", nil);
    alert.informativeText = RCLocalizedString(@"アップデートの確認中に問題が発生しました。しばらくしてからもう一度お試しください。", nil);
    [alert addButtonWithTitle:RCLocalizedString(@"OK", nil)];

    NSWindow *window = self.view.window;
    if (window != nil) {
        [alert beginSheetModalForWindow:window completionHandler:nil];
    } else {
        NSLog(@"[RCUpdatesPreferencesViewController] Skipping failure alert because no window is attached.");
    }
}

- (BOOL)shouldShowFailureAlertForUpdateCheck:(NSInteger)updateCheck {
    return updateCheck == RCUpdateServiceUpdateCheckUpdates;
}

- (RCUpdateServiceUpdateCheck)normalizedUpdateCheckFromNotification:(NSNotification *)notification {
    id updateCheckObject = notification.userInfo[RCUpdateServiceUpdateCheckUserInfoKey];
    if (![updateCheckObject isKindOfClass:[NSNumber class]]) {
        return RCUpdateServiceUpdateCheckUnknown;
    }

    NSInteger rawValue = [((NSNumber *)updateCheckObject) integerValue];
    switch (rawValue) {
        case RCUpdateServiceUpdateCheckUpdates:
        case RCUpdateServiceUpdateCheckUpdatesInBackground:
        case RCUpdateServiceUpdateCheckUpdateInformation:
            return (RCUpdateServiceUpdateCheck)rawValue;
        default:
            return RCUpdateServiceUpdateCheckUnknown;
    }
}

- (BOOL)shouldRestoreManualCheckUIStateForUpdateCheck:(NSInteger)updateCheck {
    return updateCheck == RCUpdateServiceUpdateCheckUpdates
        || updateCheck == RCUpdateServiceUpdateCheckUnknown;
}

- (void)restoreManualCheckUIState {
    self.checkNowButton.enabled = YES;
    [self.checkProgressIndicator stopAnimation:nil];
    self.checkProgressIndicator.hidden = YES;
    [self cancelCheckCompletionTimer];
}

@end
