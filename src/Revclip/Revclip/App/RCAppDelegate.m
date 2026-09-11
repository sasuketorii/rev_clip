#import "RCLocalization.h"
//
//  RCAppDelegate.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
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
#import "RCScreenshotMonitorService.h"
#import "RCSnippetEditorWindowController.h"
#import "RCSnippetImportExportService.h"
#import "RCUpdateService.h"
#import "RCUtilities.h"

@import UniformTypeIdentifiers;

static UTType *RCSnippetImportExportContentType(void) {
    UTType *contentType = [UTType typeWithFilenameExtension:@"revclipsnippets"];
    return (contentType != nil) ? contentType : UTTypeData;
}

@interface RCAppDelegate ()

- (void)presentSnippetImportExportError:(NSError *)error title:(NSString *)title;
- (BOOL)promptMergeOptionReturningMerge:(BOOL *)merge;

@end

@implementation RCAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // 0. Move to Applications check (before any setup)
    [[RCMoveToApplicationsService shared] checkAndMoveIfNeeded];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(languageDidChange:) name:RCLanguageDidChangeNotification object:nil];
    [RCLocalization localizeMenu:NSApp.mainMenu table:@"MainMenu"];

    // 1. Register defaults
    [RCUtilities registerDefaultSettings];
    [RCAppearanceController applySavedAppearance];

    // 2. Database setup
    RCDatabaseManager *databaseManager = [RCDatabaseManager shared];
    [databaseManager setupDatabase];

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
    [menuManager setupStatusItem];
    [hotKeyService loadAndRegisterHotKeysFromDefaults];
    [dataCleanService startCleanupTimer];
    [clipboardService startMonitoring];
    [clipboardService captureCurrentClipboard];
    [privacyService presentClipboardAccessGuidanceIfNeeded];

    // 6. Accessibility
    [[RCAccessibilityService shared] checkAndRequestAccessibilityWithAlert];

    // 7. Sparkle updater
    [[RCUpdateService shared] setupUpdater];

    // 8. Screenshot monitoring (Beta)
    [[RCScreenshotMonitorService shared] startMonitoring];

    // 9. Login item registration
    BOOL loginItemEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:kRCLoginItem];
    if (loginItemEnabled) {
        [[RCLoginItemService shared] setLoginItemEnabled:YES];
    }

    NSLog(@"[Revclip] Application did finish launching.");
}

- (void)languageDidChange:(NSNotification *)notification {
    [RCLocalization localizeMenu:NSApp.mainMenu table:@"MainMenu"];
    [[RCMenuManager shared] rebuildMenu];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;
    return [[RCSnippetEditorWindowController shared] saveChangesIfLoaded] ? NSTerminateNow : NSTerminateCancel;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
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
