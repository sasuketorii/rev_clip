#import "RCLocalization.h"
//
//  RCAppDelegate.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Current project: AGPL-3.0-only; legacy portions: MIT. See THIRD_PARTY_NOTICES.md.
//

#import "RCAppDelegate.h"
#import "Revclip-Swift.h"

#import "RCAccessibilityService.h"
#import "RCClipboardService.h"
#import "RCDataCleanService.h"
#import "RCConstants.h"
#import "RCEnvironment.h"
#import "RCExcludeAppService.h"
#import "RCDatabaseManager.h"
#import "RCHotKeyService.h"
#import "RCLoginItemService.h"
#import "RCMenuManager.h"
#import "RCMoveToApplicationsService.h"
#import "RCPreferencesWindowController.h"
#import "RCPasteService.h"
#import "RCPrivacyService.h"
#import "RCPanicEraseService.h"
#import "RCScreenshotMonitorService.h"
#import "RCSnippetEditorWindowController.h"
#import "RCSnippetImportExportService.h"
#import "RCSnippetCLIService.h"
#import "RCUpdateService.h"
#import "RCUtilities.h"

@import UniformTypeIdentifiers;

static UTType *RCSnippetImportExportContentType(void) {
    UTType *contentType = [UTType typeWithFilenameExtension:@"revclipsnippets"];
    return (contentType != nil) ? contentType : UTTypeData;
}

@interface RCAppDelegate ()
@property(nonatomic) BOOL clipboardTerminationPending;
@property(nonatomic) BOOL userOpenReady;
@property(nonatomic) NSTimeInterval userOpenWaitingSince;
@property(nonatomic) NSUInteger userOpenWaitingGeneration;
@property(nonatomic) NSUInteger clipboardTerminationGeneration;

- (void)presentSnippetImportExportError:(NSError *)error title:(NSString *)title;
- (BOOL)promptMergeOptionReturningMerge:(BOOL *)merge;
- (NSApplicationTerminateReply)beginClipboardTerminationForApplication:(NSApplication *)application
                                                            clipboard:(RCClipboardService *)clipboard;
- (void)scheduleClipboardTerminationTimeout:(dispatch_block_t)timeout;
- (BOOL)clipboardMayResumeAfterCancelledTermination;
- (void)handleUserOpen;
- (void)handleUserLaunch;
- (BOOL)userOpenApplicationIsActive;
- (BOOL)userOpenModalWindowPresent;
- (NSTimeInterval)userOpenClock;
- (NSUInteger)userOpenMonitoringGeneration;
- (void)presentMenuForUserOpen;

@end

@implementation RCAppDelegate

// Whether this launch was caused by a Services request. AERegistry.h only says the
// keyword is "present in a kAEOpenApplication event". Published code reads it as the
// enum value of keyAEPropData, the same shape as the long-established login item check
// (keyAEPropData == keyAELaunchedAsLogInItem); a parameter under the keyword itself is
// the other literal reading. Both are accepted, and neither is confirmed on a current
// macOS yet, so the launch log below records the shape that actually arrived. Anything
// else, including a login item launch, is an ordinary launch and keeps its guidance.
+ (BOOL)launchEventIndicatesService:(NSAppleEventDescriptor *)event {
    if (event == nil || event.eventClass != kCoreEventClass || event.eventID != kAEOpenApplication) { return NO; }
    NSAppleEventDescriptor *property = [event paramDescriptorForKeyword:keyAEPropData];
    if (property != nil && property.enumCodeValue == keyAELaunchedAsServiceItem) { return YES; }
    return [event paramDescriptorForKeyword:keyAELaunchedAsServiceItem] != nil;
}

+ (BOOL)launchEventIsUserOpen:(NSAppleEventDescriptor *)event {
    if (event == nil || event.eventClass != kCoreEventClass || event.eventID != kAEOpenApplication) { return NO; }
    // keyAELaunchedAsLogInItem, keyAELaunchedAsServiceItem, or anything not known here.
    if ([event paramDescriptorForKeyword:keyAEPropData] != nil) { return NO; }
    return [event paramDescriptorForKeyword:keyAELaunchedAsLogInItem] == nil &&
        [event paramDescriptorForKeyword:keyAELaunchedAsServiceItem] == nil;
}

+ (BOOL)selfRelaunchStamp:(NSTimeInterval)stamp coversLaunchAt:(NSTimeInterval)now {
    return stamp > 0 && now >= stamp && now - stamp <= 300.0;
}

#pragma mark - Opened by the user

static const NSTimeInterval kRCUserOpenActivationWait = 1.0;

// Opening Revclip from Applications (first launch, or again while it runs) shows the
// same menu as the main hotkey, through the same entry: that path already drops a
// request after Clear, Panic or quit, coalesces repeats and never stacks menus. Only a
// user's own open reaches this. Opened again while running, macOS activates Revclip
// (seen on a real reopen), so a reopen that leaves it inactive (`open -g`) shows
// nothing. Activation can arrive just after the event; it is awaited through the
// activation callback, with a time comparison instead of a timer.
- (void)handleUserOpen {
    self.userOpenWaitingSince = 0;
    if (!self.userOpenReady || self.clipboardTerminationPending || [self userOpenModalWindowPresent]) { return; }
    if (![self userOpenApplicationIsActive]) {
        self.userOpenWaitingSince = [self userOpenClock];
        self.userOpenWaitingGeneration = [self userOpenMonitoringGeneration];
        return;
    }
    [self presentMenuForUserOpen];
}

// First launch. macOS does not activate an agent application (LSUIElement) when it is
// opened, and asking with -activate did not activate it either (seen on real launches:
// active=false, no menu). So the first launch does not wait for activation at all: the
// main hotkey's menu has always been shown while Revclip is not active, and this is
// the same call. What keeps other launches out is the launch event (login item,
// Services), the self-relaunch stamp and, for a script's `open -g`, which sends the
// same event as a user's open, the -suppressLaunchMenu launch argument.
- (void)handleUserLaunch {
    self.userOpenWaitingSince = 0;
    if (!self.userOpenReady || self.clipboardTerminationPending || [self userOpenModalWindowPresent]) { return; }
    [self presentMenuForUserOpen];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    NSTimeInterval since = self.userOpenWaitingSince;
    if (since <= 0) { return; }
    NSTimeInterval waited = [self userOpenClock] - since;
    self.userOpenWaitingSince = 0;
    // A Clear, Panic or stop and restart during the wait ends the request: the menu
    // entry only guards requests from the moment it is called.
    if (waited >= 0 && waited <= kRCUserOpenActivationWait &&
        [self userOpenMonitoringGeneration] == self.userOpenWaitingGeneration) { [self handleUserOpen]; }
}

// A window that is already open keeps AppKit's behaviour (it comes forward).
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)hasVisibleWindows {
    if (hasVisibleWindows) { return YES; }
    [self handleUserOpen];
    return NO;
}

- (BOOL)userOpenApplicationIsActive { return NSApp.isActive; }
- (BOOL)userOpenModalWindowPresent { return NSApp.modalWindow != nil; }
- (NSTimeInterval)userOpenClock { return NSProcessInfo.processInfo.systemUptime; }
- (NSUInteger)userOpenMonitoringGeneration { return [RCClipboardService shared].monitoringGeneration; }
- (void)presentMenuForUserOpen { [[RCMenuManager shared] popUpStatusMenuFromHotKey]; }

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // XCTest hosts must never migrate the signed-in user's store or start capture.
    if (NSClassFromString(@"XCTestCase") != nil) return;
    // What caused this launch, read once and first: the alerts below run modal loops,
    // after which the current event can be another one, or none.
    NSAppleEventDescriptor *launchEvent = NSAppleEventManager.sharedAppleEventManager.currentAppleEvent;
    BOOL launchedAsService = [RCAppDelegate launchEventIndicatesService:launchEvent];
    BOOL launchedByUser = [RCAppDelegate launchEventIsUserOpen:launchEvent];
    // 0. Move to Applications check (before any setup).
    [[RCMoveToApplicationsService shared] checkAndMoveIfNeeded];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(languageDidChange:) name:RCLanguageDidChangeNotification object:nil];
    [RCLocalization localizeMenu:NSApp.mainMenu table:@"MainMenu"];

    // 1. Register defaults
    [RCUtilities registerDefaultSettings];
    [RCAppearanceController applySavedAppearance];

    // 2. Database setup
    RCDatabaseManager *databaseManager = [RCDatabaseManager shared];
    if (![databaseManager setupDatabase]) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = RCLocalizedString(@"Protected storage unavailable", @"");
        alert.informativeText = RCLocalizedString(@"Revclip could not safely open its saved data. Unlock your login keychain and try again. Existing data has not been replaced with an empty history.", @"");
        [alert addButtonWithTitle:RCLocalizedString(@"Quit Revclip", @"")];
        [alert runModal];
        [NSApp terminate:nil];
        return;
    }

    // 2.5 Data protection (permissions + backup/index exclusions)
    [RCUtilities applyDataProtectionAttributes];

    // 3. Core services
    RCPrivacyService *privacyService = [RCPrivacyService shared];
    [privacyService refreshClipboardAccessState];

    RCClipboardService *clipboardService = [RCClipboardService shared];
    RCMenuManager *menuManager = [RCMenuManager shared];
    RCPasteService *pasteService = [RCPasteService shared];
    RCHotKeyService *hotKeyService = [RCHotKeyService shared];
    RCAccessibilityService *accessibilityService = [RCAccessibilityService shared];
    RCDataCleanService *dataCleanService = [RCDataCleanService shared];
    RCExcludeAppService *excludeAppService = [RCExcludeAppService shared];
    RCLoginItemService *loginItemService = [RCLoginItemService shared];

    // 4. Environment
    RCEnvironment *environment = [RCEnvironment shared];
    environment.databaseManager = databaseManager;
    environment.clipboardService = clipboardService;
    environment.menuManager = menuManager;
    environment.pasteService = pasteService;
    environment.hotKeyService = hotKeyService;
    environment.accessibilityService = accessibilityService;
    environment.dataCleanService = dataCleanService;
    environment.excludeAppService = excludeAppService;
    environment.loginItemService = loginItemService;
    environment.privacyService = privacyService;

    // 5. UI & Services setup
    [[RCOCRCoordinator shared] startObserving];
    [menuManager setupStatusItem];
    [hotKeyService loadAndRegisterHotKeysFromDefaults];
    [dataCleanService startCleanupTimer];
    [clipboardService startMonitoring];
    [clipboardService captureCurrentClipboard];
    // Launched by macOS to answer a Services request (the first contact for a new
    // user, from another application's context menu): the modal guidance below would
    // sit in front of the menu that request is waiting for. It is shown on the next
    // ordinary launch instead. An ordinary launch is unchanged.
    if (!launchedAsService) { [privacyService presentClipboardAccessGuidanceIfNeeded]; }

    // Services entry. Registered only now: a request that launched the app is delivered
    // once a provider exists, and by this point history and templates can be read.
    NSApp.servicesProvider = menuManager;
    NSUpdateDynamicServices();

    // 6. Accessibility
    if (!launchedAsService) { [[RCAccessibilityService shared] checkAndRequestAccessibilityWithAlert]; }

    // 7. Sparkle updater uses the distribution feed in the bundle metadata.
    [[RCUpdateService shared] setupUpdater];

    // 8. Screenshot monitoring (Beta)
    [[RCScreenshotMonitorService shared] startMonitoring];

    // 9. Login item registration
    BOOL loginItemEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:kRCLoginItem];
    if (loginItemEnabled) {
        [[RCLoginItemService shared] setLoginItemEnabled:YES];
    }

    [[RCSnippetCLIService shared] start];

    // Last, after every first-run alert: the menu for a launch the user made. Not after
    // Revclip relaunched itself; the stamp is consumed either way.
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL selfRelaunch = [RCAppDelegate selfRelaunchStamp:[defaults doubleForKey:kRCSelfRelaunchStampKey]
                                          coversLaunchAt:NSDate.date.timeIntervalSinceReferenceDate];
    [defaults removeObjectForKey:kRCSelfRelaunchStampKey];
    self.userOpenReady = YES;
    if (!selfRelaunch && launchedByUser && ![defaults boolForKey:kRCSuppressLaunchMenuKey]) { [self handleUserLaunch]; }
    NSLog(@"[Revclip] Application did finish launching. event=%@ prdt=%@ svit=%d service=%d",
          NSFileTypeForHFSTypeCode(launchEvent.eventID), NSFileTypeForHFSTypeCode([launchEvent paramDescriptorForKeyword:keyAEPropData].enumCodeValue),
          [launchEvent paramDescriptorForKeyword:keyAELaunchedAsServiceItem] != nil, launchedAsService);
}

- (void)languageDidChange:(NSNotification *)notification {
    [RCLocalization localizeMenu:NSApp.mainMenu table:@"MainMenu"];
    [[RCMenuManager shared] rebuildMenu];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    if (NSClassFromString(@"XCTestCase") != nil) return NSTerminateNow;
    if (self.clipboardTerminationPending) return NSTerminateLater;
    if ([RCPanicEraseService shared].isPanicInProgress) {
        return [RCPanicEraseService shared].isEraseAttemptActive ? NSTerminateCancel : NSTerminateNow;
    }
    if (![[RCSnippetEditorWindowController shared] saveChangesIfLoaded]) return NSTerminateCancel;
    return [self beginClipboardTerminationForApplication:sender clipboard:RCClipboardService.shared];
}

- (void)scheduleClipboardTerminationTimeout:(dispatch_block_t)timeout {
    // terminate: can hold a main-dispatch block while AppKit runs its modal
    // termination loop. The watchdog must not wait behind that same block.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), timeout);
}

- (BOOL)clipboardMayResumeAfterCancelledTermination {
    return !RCPanicEraseService.shared.isPanicInProgress;
}

// Inject both boundaries so lifecycle tests never terminate their XCTest host or
// start a production clipboard singleton. All state and replies live on main.
- (NSApplicationTerminateReply)beginClipboardTerminationForApplication:(NSApplication *)application
                                                            clipboard:(RCClipboardService *)clipboard {
    if (!NSThread.isMainThread || !application || !clipboard) return NSTerminateCancel;
    if (self.clipboardTerminationPending) return NSTerminateLater;
    self.clipboardTerminationPending = YES;
    NSUInteger generation = ++self.clipboardTerminationGeneration;
    BOOL wasMonitoring = clipboard.isMonitoring;
    [clipboard stopMonitoring];

    __weak typeof(self) weakSelf = self;
    void (^finish)(BOOL) = ^(BOOL drained) {
        // Even a synchronous test completion must reply after NSTerminateLater
        // has returned to AppKit. A late completion cannot approve another quit.
        // A main-queue dispatch cannot reenter the block that called terminate:.
        // Deliver through the run loop, explicitly including AppKit's deferred
        // termination mode. Keep the asynchronous return and generation guard.
        CFRunLoopRef mainRunLoop = CFRunLoopGetMain();
        CFRunLoopPerformBlock(mainRunLoop,
                              (__bridge CFArrayRef)@[NSRunLoopCommonModes, NSModalPanelRunLoopMode], ^{
            typeof(self) self = weakSelf;
            if (!self || !self.clipboardTerminationPending ||
                self.clipboardTerminationGeneration != generation) return;
            self.clipboardTerminationPending = NO;
            if (!drained && wasMonitoring && [self clipboardMayResumeAfterCancelledTermination]) {
                [clipboard startMonitoring];
            }
            // Flush is only a queue-drain barrier, not a claim that every write
            // succeeded. Timeout never cancels or discards accepted queue work.
            [application replyToApplicationShouldTerminate:drained];
        });
        CFRunLoopWakeUp(mainRunLoop);
    };
    [self scheduleClipboardTerminationTimeout:^{ finish(NO); }];
    [clipboard flushQueueWithCompletion:^{ finish(YES); }];
    return NSTerminateLater;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    if (NSClassFromString(@"XCTestCase") != nil) return;
    [[RCSnippetCLIService shared] stop];
    (void)notification;
    [[RCScreenshotMonitorService shared] stopMonitoring];
    [[RCDataCleanService shared] stopCleanupTimer];
    [[RCClipboardService shared] stopMonitoring];
    [[RCHotKeyService shared] unregisterAllHotKeys];

    // Nil out environment properties to break retain cycles
    RCEnvironment *environment = [RCEnvironment shared];
    environment.clipboardService = nil;
    environment.pasteService = nil;
    environment.hotKeyService = nil;
    environment.accessibilityService = nil;
    environment.excludeAppService = nil;
    environment.dataCleanService = nil;
    environment.loginItemService = nil;
    environment.privacyService = nil;
    environment.menuManager = nil;
    environment.databaseManager = nil;
}

- (IBAction)showPreferencesWindow:(id)sender {
    [[RCPreferencesWindowController shared] showWindow:sender];
}

- (IBAction)showPreferences:(id)sender {
    [self showPreferencesWindow:sender];
}

- (IBAction)showSnippetEditor:(id)sender {
    [[RCSnippetEditorWindowController shared] showWindow:sender];
}

- (IBAction)importSnippets:(id)sender {
    (void)sender;
    if (![[RCSnippetEditorWindowController shared] saveChangesIfLoaded]) { return; }

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.allowedContentTypes = @[
        RCSnippetImportExportContentType(),
        UTTypeXML,
        UTTypePropertyList,
    ];

    NSString *clipyDirectoryPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/com.clipy-app.Clipy"];
    BOOL isDirectory = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:clipyDirectoryPath isDirectory:&isDirectory] && isDirectory) {
        panel.directoryURL = [NSURL fileURLWithPath:clipyDirectoryPath];
    }

    NSModalResponse openResponse = [panel runModal];
    if (openResponse != NSModalResponseOK || panel.URL == nil) {
        return;
    }

    BOOL merge = YES;
    if (![self promptMergeOptionReturningMerge:&merge]) {
        return;
    }

    NSError *importError = nil;
    BOOL imported = [[RCSnippetImportExportService shared] importSnippetsFromURL:panel.URL
                                                                            merge:merge
                                                                            error:&importError];
    if (!imported) {
        [self presentSnippetImportExportError:importError title:RCLocalizedString(@"Failed to Import Snippets", nil)];
        return;
    }

    [[RCSnippetEditorWindowController shared] reloadIfLoaded];
    [[RCHotKeyService shared] reloadFolderHotKeys];
    [[RCMenuManager shared] rebuildMenu];
}

- (IBAction)exportSnippets:(id)sender {
    (void)sender;

    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.canCreateDirectories = YES;
    panel.nameFieldStringValue = @"snippets.revclipsnippets";
    panel.allowedContentTypes = @[RCSnippetImportExportContentType()];

    NSModalResponse saveResponse = [panel runModal];
    if (saveResponse != NSModalResponseOK || panel.URL == nil) {
        return;
    }

    NSError *exportError = nil;
    BOOL exported = [[RCSnippetImportExportService shared] exportSnippetsToURL:panel.URL error:&exportError];
    if (!exported) {
        [self presentSnippetImportExportError:exportError title:RCLocalizedString(@"Failed to Export Snippets", nil)];
    }
}

#pragma mark - Private

- (void)presentSnippetImportExportError:(NSError *)error title:(NSString *)title {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleCritical;
    alert.messageText = title;
    alert.informativeText = error.localizedDescription ?: RCLocalizedString(@"An unknown error occurred.", nil);
    [alert addButtonWithTitle:RCLocalizedString(@"OK", nil)];
    [alert runModal];
}

- (BOOL)promptMergeOptionReturningMerge:(BOOL *)merge {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = RCLocalizedString(@"How do you want to import snippets?", nil);
    alert.informativeText = RCLocalizedString(@"Choose whether to merge with existing snippets or replace them all.", nil);
    [alert addButtonWithTitle:RCLocalizedString(@"Merge with existing snippets", nil)];
    [alert addButtonWithTitle:RCLocalizedString(@"Replace all snippets", nil)];
    [alert addButtonWithTitle:RCLocalizedString(@"Cancel", nil)];

    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) {
        if (merge != NULL) {
            *merge = YES;
        }
        return YES;
    }
    if (response == NSAlertSecondButtonReturn) {
        if (merge != NULL) {
            *merge = NO;
        }
        return YES;
    }
    return NO;
}

@end
