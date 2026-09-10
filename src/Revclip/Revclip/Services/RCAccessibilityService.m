//
//  RCAccessibilityService.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import "RCAccessibilityService.h"
#import <ApplicationServices/ApplicationServices.h>

@interface RCAccessibilityService ()

- (void)showAccessibilityAlert;
- (NSArray<NSURL *> *)accessibilitySettingsCandidateURLs;
- (void)openAccessibilitySettingsWithFallback;

@end

@implementation RCAccessibilityService

+ (instancetype)shared {
    static RCAccessibilityService *sharedService = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedService = [[self alloc] init];
    });
    return sharedService;
}

- (BOOL)isAccessibilityEnabled {
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt : @NO};
    return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}

- (void)requestAccessibilityPermission {
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt : @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}

- (void)checkAndRequestAccessibilityWithAlert {
    if ([self isAccessibilityEnabled]) {
        return;
    }

    [self requestAccessibilityPermission];
    [self showAccessibilityAlert];
}

- (void)showAccessibilityAlert {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showAccessibilityAlert];
        });
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = NSLocalizedString(@"Revclip requires Accessibility permission", nil);
    alert.informativeText = NSLocalizedString(@"Revclip needs Accessibility permission to paste clipboard items. Please enable it in System Settings > Privacy & Security > Accessibility.", nil);
    [alert addButtonWithTitle:NSLocalizedString(@"Open System Settings", nil)];
    [alert addButtonWithTitle:NSLocalizedString(@"Later", nil)];

    NSModalResponse response = [alert runModal];
    if (response != NSAlertFirstButtonReturn) {
        return;
    }

    [self openAccessibilitySettingsWithFallback];
}

- (NSArray<NSURL *> *)accessibilitySettingsCandidateURLs {
    NSMutableArray<NSURL *> *candidateURLs = [NSMutableArray array];

    if (@available(macOS 13.0, *)) {
        NSURL *modernURL = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"];
        if (modernURL != nil) {
            [candidateURLs addObject:modernURL];
        }
    }

    NSURL *legacyAccessibilityURL = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
    if (legacyAccessibilityURL != nil) {
        [candidateURLs addObject:legacyAccessibilityURL];
    }

    NSURL *legacySecurityPaneURL = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security"];
    if (legacySecurityPaneURL != nil) {
        [candidateURLs addObject:legacySecurityPaneURL];
    }

    return [candidateURLs copy];
}

- (void)openAccessibilitySettingsWithFallback {
    NSWorkspace *workspace = [NSWorkspace sharedWorkspace];

    for (NSURL *candidateURL in [self accessibilitySettingsCandidateURLs]) {
        if ([workspace openURL:candidateURL]) {
            return;
        }
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray<NSString *> *settingsAppPaths = @[
        @"/System/Applications/System Settings.app",
        @"/System/Applications/System Preferences.app",
    ];

    for (NSString *appPath in settingsAppPaths) {
        if (![fileManager fileExistsAtPath:appPath]) {
            continue;
        }
        if ([workspace openURL:[NSURL fileURLWithPath:appPath]]) {
            return;
        }
    }

    if ([workspace launchApplication:@"System Settings"]) {
        return;
    }
    if ([workspace launchApplication:@"System Preferences"]) {
        return;
    } else {
        NSLog(@"[RCAccessibilityService] Failed to open Accessibility settings via URL and app fallbacks.");
    }
}

@end
