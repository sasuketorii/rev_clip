#import "RCLocalization.h"
//
//  RCMoveToApplicationsService.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import "RCMoveToApplicationsService.h"
#import <Cocoa/Cocoa.h>

static NSString * const kRCMoveToApplicationsErrorDomain = @"com.revclip.movetoapplications";

@interface RCMoveToApplicationsService ()

- (BOOL)isRunningFromBuildDirectory;
- (NSString *)applicationsBundlePath;
- (NSString *)bundleVersionAtPath:(NSString *)bundlePath;
- (NSComparisonResult)compareBundleVersion:(NSString *)leftVersion toBundleVersion:(NSString *)rightVersion;
- (void)moveApplicationToApplicationsFromPath:(NSString *)sourcePath;
- (void)showMoveFailedAlertWithError:(NSError *)error;
- (void)showDowngradePreventedAlertFromVersion:(NSString *)installedVersion toVersion:(NSString *)candidateVersion;
- (void)relaunchApplicationAtPath:(NSString *)applicationPath;

@end

@implementation RCMoveToApplicationsService

+ (instancetype)shared {
    static RCMoveToApplicationsService *sharedService = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedService = [[self alloc] init];
    });
    return sharedService;
}

- (void)checkAndMoveIfNeeded {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self checkAndMoveIfNeeded];
        });
        return;
    }

    NSString *bundlePath = NSBundle.mainBundle.bundlePath;
    if (bundlePath.length == 0) {
        return;
    }

    if ([bundlePath hasPrefix:@"/Applications/"]) {
        return;
    }

    if ([self isRunningFromBuildDirectory]) {
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = RCLocalizedString(@"Move to Applications folder?", nil);
    alert.informativeText = RCLocalizedString(@"Revclip needs to be in the Applications folder to work properly. Would you like to move it there?", nil);
    [alert addButtonWithTitle:RCLocalizedString(@"Move to Applications", nil)];
    [alert addButtonWithTitle:RCLocalizedString(@"Do Not Move", nil)];

    NSModalResponse response = [alert runModal];
    if (response != NSAlertFirstButtonReturn) {
        return;
    }

    [self moveApplicationToApplicationsFromPath:bundlePath];
}

- (BOOL)isRunningFromBuildDirectory {
    NSString *bundlePath = [NSBundle mainBundle].bundlePath;
    NSArray<NSString *> *pathComponents = [bundlePath pathComponents];
    NSArray<NSString *> *buildMarkers = @[@"DerivedData", @"Build", @"Xcode"];
    for (NSString *component in pathComponents) {
        for (NSString *marker in buildMarkers) {
            if ([component isEqualToString:marker]) {
                return YES;
            }
        }
    }
    return NO;
}

- (void)moveApplicationToApplicationsFromPath:(NSString *)sourcePath {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *destinationPath = [self applicationsBundlePath];
    NSURL *destinationURL = [NSURL fileURLWithPath:destinationPath];
    NSString *applicationsDirectoryPath = destinationPath.stringByDeletingLastPathComponent;
    NSString *bundleBaseName = destinationPath.lastPathComponent.stringByDeletingPathExtension;
    if (bundleBaseName.length == 0) {
        bundleBaseName = @"Revclip";
    }
    NSString *temporaryBundlePath = [applicationsDirectoryPath stringByAppendingPathComponent:[NSString stringWithFormat:@".%@_installing_%@.app", bundleBaseName, [NSUUID UUID].UUIDString]];
    NSURL *temporaryBundleURL = [NSURL fileURLWithPath:temporaryBundlePath];

    if ([fileManager fileExistsAtPath:destinationPath]) {
        NSString *sourceVersion = [self bundleVersionAtPath:sourcePath];
        NSString *installedVersion = [self bundleVersionAtPath:destinationPath];
        if (sourceVersion.length > 0
            && installedVersion.length > 0
            && [self compareBundleVersion:installedVersion toBundleVersion:sourceVersion] == NSOrderedDescending) {
            [self showDowngradePreventedAlertFromVersion:installedVersion toVersion:sourceVersion];
            return;
        }
    }

    [fileManager removeItemAtPath:temporaryBundlePath error:NULL];

    NSError *copyError = nil;
    if (![fileManager copyItemAtPath:sourcePath toPath:temporaryBundlePath error:&copyError]) {
        [self showMoveFailedAlertWithError:copyError];
        return;
    }

    NSError *replaceError = nil;
    if ([fileManager fileExistsAtPath:destinationPath]) {
        NSURL *resultingURL = nil;
        if (![fileManager replaceItemAtURL:destinationURL
                               withItemAtURL:temporaryBundleURL
                              backupItemName:nil
                                     options:0
                            resultingItemURL:&resultingURL
                                       error:&replaceError]) {
            [fileManager removeItemAtURL:temporaryBundleURL error:NULL];
            [self showMoveFailedAlertWithError:replaceError];
            return;
        }
    } else {
        if (![fileManager moveItemAtPath:temporaryBundlePath
                                  toPath:destinationPath
                                   error:&replaceError]) {
            [fileManager removeItemAtURL:temporaryBundleURL error:NULL];
            [self showMoveFailedAlertWithError:replaceError];
            return;
        }
    }

    // Clean up the original application bundle after successful move
    if (![sourcePath isEqualToString:destinationPath]) {
        [fileManager removeItemAtPath:sourcePath error:NULL];
    }

    [self relaunchApplicationAtPath:destinationPath];
}

- (void)relaunchApplicationAtPath:(NSString *)applicationPath {
    NSTask *openTask = [[NSTask alloc] init];
    openTask.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"];
    openTask.arguments = @[@"-n", applicationPath];

    openTask.terminationHandler = ^(NSTask *task) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (task.terminationStatus == 0) {
                [NSApp terminate:nil];
                return;
            }

            NSError *terminationError = [NSError errorWithDomain:kRCMoveToApplicationsErrorDomain
                                                             code:(NSInteger)task.terminationStatus
                                                         userInfo:@{
                                                             NSLocalizedDescriptionKey: RCLocalizedString(@"Failed to relaunch the app from Applications.", nil),
                                                             NSLocalizedFailureReasonErrorKey: [NSString stringWithFormat:@"open exited with status %d", task.terminationStatus],
                                                         }];
            [self showMoveFailedAlertWithError:terminationError];
        });
    };

    NSError *launchError = nil;
    if (![openTask launchAndReturnError:&launchError]) {
        openTask.terminationHandler = nil;
        [self showMoveFailedAlertWithError:launchError];
        return;
    }
}

- (void)showMoveFailedAlertWithError:(NSError *)error {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showMoveFailedAlertWithError:error];
        });
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleCritical;
    alert.messageText = RCLocalizedString(@"Could not move Revclip to Applications folder", nil);
    alert.informativeText = error.localizedDescription ?: RCLocalizedString(@"An unknown error occurred while moving Revclip.", nil);
    [alert addButtonWithTitle:RCLocalizedString(@"OK", nil)];
    [alert runModal];
}

- (NSString *)applicationsBundlePath {
    NSString *bundleName = NSBundle.mainBundle.bundlePath.lastPathComponent;
    if (bundleName.length == 0) {
        bundleName = @"Revclip.app";
    }
    return [@"/Applications" stringByAppendingPathComponent:bundleName];
}

- (NSString *)bundleVersionAtPath:(NSString *)bundlePath {
    if (bundlePath.length == 0) {
        return @"";
    }

    NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
    NSDictionary *info = bundle.infoDictionary;
    id bundleVersionValue = info[@"CFBundleVersion"];
    NSString *bundleVersion = [bundleVersionValue isKindOfClass:[NSString class]] ? bundleVersionValue : [bundleVersionValue respondsToSelector:@selector(stringValue)] ? [bundleVersionValue stringValue] : @"";
    if (bundleVersion.length > 0) {
        return [bundleVersion stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }

    id shortVersionValue = info[@"CFBundleShortVersionString"];
    NSString *shortVersion = [shortVersionValue isKindOfClass:[NSString class]] ? shortVersionValue : [shortVersionValue respondsToSelector:@selector(stringValue)] ? [shortVersionValue stringValue] : @"";
    return [shortVersion stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (NSComparisonResult)compareBundleVersion:(NSString *)leftVersion toBundleVersion:(NSString *)rightVersion {
    if (leftVersion.length == 0 && rightVersion.length == 0) {
        return NSOrderedSame;
    }
    if (leftVersion.length == 0) {
        return NSOrderedAscending;
    }
    if (rightVersion.length == 0) {
        return NSOrderedDescending;
    }

    return [leftVersion compare:rightVersion options:NSNumericSearch];
}

- (void)showDowngradePreventedAlertFromVersion:(NSString *)installedVersion toVersion:(NSString *)candidateVersion {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showDowngradePreventedAlertFromVersion:installedVersion toVersion:candidateVersion];
        });
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = RCLocalizedString(@"A newer version is already installed in Applications.", nil);
    alert.informativeText = [NSString stringWithFormat:RCLocalizedString(@"Installed version (%@) is newer than this app (%@). Move was canceled to prevent a downgrade.", nil),
                              installedVersion.length > 0 ? installedVersion : @"-",
                              candidateVersion.length > 0 ? candidateVersion : @"-"];
    [alert addButtonWithTitle:RCLocalizedString(@"OK", nil)];
    [alert runModal];
}

@end
