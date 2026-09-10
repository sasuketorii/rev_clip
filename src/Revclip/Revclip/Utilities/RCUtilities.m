//
//  RCUtilities.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import "RCUtilities.h"

#import "RCConstants.h"

static NSString * const kRCDatabaseFileName = @"revclip.db";
static NSString * const kRCNeverIndexFileName = @".metadata_never_index";
static NSNumber * const kRCDirectoryPermissions = @(0700);
static NSNumber * const kRCFilePermissions = @(0600);

@interface RCUtilities ()

+ (BOOL)applyPOSIXPermissions:(NSNumber *)permissions toPath:(NSString *)path fileManager:(NSFileManager *)fileManager;
+ (BOOL)isProtectedClipDataFileName:(NSString *)fileName;

@end

@implementation RCUtilities

+ (void)registerDefaultSettings {
    NSDictionary *defaultSettings = @{
        kRCPrefMaxHistorySizeKey: @30,
        kRCPrefAutoExpiryEnabledKey: @NO,
        kRCPrefAutoExpiryValueKey: @30,
        kRCPrefAutoExpiryUnitKey: @0,
        kRCPrefMaxClipSizeBytesKey: @52428800,
        kRCPrefInputPasteCommandKey: @YES,
        kRCPrefReorderClipsAfterPasting: @YES,
        kRCPrefShowStatusItemKey: @1,
        kRCPrefStoreTypesKey: @{
            @"String": @YES,
            @"RTF": @YES,
            @"RTFD": @YES,
            @"PDF": @YES,
            @"Filenames": @YES,
            @"URL": @YES,
            @"TIFF": @YES
        },
        kRCPrefOverwriteSameHistory: @YES,
        kRCPrefCopySameHistory: @YES,
        kRCCollectCrashReport: @YES,
        kRCLoginItem: @YES,
        kRCSuppressAlertForLoginItem: @NO,
        kRCPrefNumberOfItemsPlaceInlineKey: @0,
        kRCPrefNumberOfItemsPlaceInsideFolderKey: @10,
        kRCPrefMaxMenuItemTitleLengthKey: @40,
        kRCPrefMenuIconSizeKey: @16,
        kRCPrefShowIconInTheMenuKey: @YES,
        kRCMenuItemsAreMarkedWithNumbersKey: @YES,
        kRCPrefMenuItemsTitleStartWithZeroKey: @NO,
        kRCShowToolTipOnMenuItemKey: @YES,
        kRCMaxLengthOfToolTipKey: @10000,
        kRCShowImageInTheMenuKey: @YES,
        kRCPrefShowColorPreviewInTheMenu: @YES,
        kRCAddNumericKeyEquivalentsKey: @NO,
        kRCThumbnailWidthKey: @100,
        kRCThumbnailHeightKey: @32,
        kRCPrefAddClearHistoryMenuItemKey: @YES,
        kRCPrefShowAlertBeforeClearHistoryKey: @YES,
        kRCEnableAutomaticCheckKey: @YES,
        kRCUpdateCheckIntervalKey: @86400,
        kRCBetaPastePlainText: @YES,
        kRCBetaPastePlainTextModifier: @0,
        kRCBetaDeleteHistory: @NO,
        kRCBetaDeleteHistoryModifier: @0,
        kRCBetaPasteAndDeleteHistory: @NO,
        kRCBetaPasteAndDeleteHistoryModifier: @0,
        kRCBetaObserveScreenshot: @NO,
        kRCSuppressAlertForDeleteSnippet: @NO,
    };

    [[NSUserDefaults standardUserDefaults] registerDefaults:defaultSettings];
}

+ (NSString *)applicationSupportPath {
    NSString *configuredPath = [kRCApplicationSupportDirectoryPath stringByExpandingTildeInPath];
    if (configuredPath.length > 0) {
        return [configuredPath stringByStandardizingPath];
    }

    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *basePath = paths.firstObject;
    if (basePath.length == 0) {
        basePath = [[NSHomeDirectory() stringByAppendingPathComponent:@"Library"] stringByAppendingPathComponent:@"Application Support"];
    }

    return [[basePath stringByAppendingPathComponent:@"Revclip"] stringByStandardizingPath];
}

+ (NSString *)clipDataDirectoryPath {
    NSString *configuredPath = [kRCClipDataDirectoryPath stringByExpandingTildeInPath];
    if (configuredPath.length > 0) {
        return [configuredPath stringByStandardizingPath];
    }

    NSString *clipPath = [[self applicationSupportPath] stringByAppendingPathComponent:@"ClipsData"];
    return [clipPath stringByStandardizingPath];
}

+ (BOOL)ensureDirectoryExists:(NSString *)path {
    NSString *expandedPath = [[path stringByExpandingTildeInPath] stringByStandardizingPath];
    if (expandedPath.length == 0) {
        return NO;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if ([fileManager fileExistsAtPath:expandedPath isDirectory:&isDirectory]) {
        if (!isDirectory) {
            return NO;
        }

        [self applyPOSIXPermissions:kRCDirectoryPermissions toPath:expandedPath fileManager:fileManager];
        return YES;
    }

    NSError *error = nil;
    BOOL created = [fileManager createDirectoryAtPath:expandedPath
                          withIntermediateDirectories:YES
                                           attributes:@{ NSFilePosixPermissions: kRCDirectoryPermissions }
                                                error:&error];
    if (!created) {
        NSLog(@"[RCUtilities] Failed to create directory: %@ (%@)", expandedPath, error.localizedDescription);
    }
    return created;
}

+ (void)applyDataProtectionAttributes {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *applicationSupportPath = [self applicationSupportPath];
    NSString *clipDataDirectoryPath = [self clipDataDirectoryPath];

    [self ensureDirectoryExists:applicationSupportPath];
    [self ensureDirectoryExists:clipDataDirectoryPath];

    [self applyPOSIXPermissions:kRCDirectoryPermissions toPath:applicationSupportPath fileManager:fileManager];
    [self applyPOSIXPermissions:kRCDirectoryPermissions toPath:clipDataDirectoryPath fileManager:fileManager];

    NSURL *applicationSupportURL = [NSURL fileURLWithPath:applicationSupportPath isDirectory:YES];
    NSError *backupError = nil;
    BOOL excludedFromBackup = [applicationSupportURL setResourceValue:@YES
                                                               forKey:NSURLIsExcludedFromBackupKey
                                                                error:&backupError];
    if (!excludedFromBackup && backupError != nil) {
        NSLog(@"[RCUtilities] Failed to exclude Application Support from backup: %@",
              backupError.localizedDescription);
    }

    NSString *neverIndexPath = [clipDataDirectoryPath stringByAppendingPathComponent:kRCNeverIndexFileName];
    if (![fileManager fileExistsAtPath:neverIndexPath]) {
        BOOL createdNeverIndex = [fileManager createFileAtPath:neverIndexPath
                                                       contents:[NSData data]
                                                     attributes:@{ NSFilePosixPermissions: kRCFilePermissions }];
        if (!createdNeverIndex) {
            NSLog(@"[RCUtilities] Failed to create Spotlight exclusion marker file.");
        }
    } else {
        [self applyPOSIXPermissions:kRCFilePermissions toPath:neverIndexPath fileManager:fileManager];
    }

    NSString *databaseBasePath = [applicationSupportPath stringByAppendingPathComponent:kRCDatabaseFileName];
    NSArray<NSString *> *databaseSuffixes = @[@"", @"-journal", @"-wal", @"-shm"];
    for (NSString *suffix in databaseSuffixes) {
        NSString *databasePath = [databaseBasePath stringByAppendingString:suffix];
        [self applyPOSIXPermissions:kRCFilePermissions toPath:databasePath fileManager:fileManager];
    }

    NSDirectoryEnumerator<NSString *> *enumerator = [fileManager enumeratorAtPath:clipDataDirectoryPath];
    for (NSString *relativePath in enumerator) {
        if (![self isProtectedClipDataFileName:relativePath]) {
            continue;
        }

        NSString *absolutePath = [clipDataDirectoryPath stringByAppendingPathComponent:relativePath];
        NSDictionary<NSFileAttributeKey, id> *attributes = [fileManager attributesOfItemAtPath:absolutePath error:nil];
        if (attributes == nil) {
            continue;
        }

        NSString *fileType = attributes[NSFileType];
        if ([fileType isEqualToString:NSFileTypeSymbolicLink]) {
            continue;
        }

        BOOL isDirectory = NO;
        if (![fileManager fileExistsAtPath:absolutePath isDirectory:&isDirectory] || isDirectory) {
            continue;
        }

        [self applyPOSIXPermissions:kRCFilePermissions toPath:absolutePath fileManager:fileManager];
    }
}

+ (BOOL)applyPOSIXPermissions:(NSNumber *)permissions toPath:(NSString *)path fileManager:(NSFileManager *)fileManager {
    NSString *expandedPath = [[path stringByExpandingTildeInPath] stringByStandardizingPath];
    if (expandedPath.length == 0 || permissions == nil) {
        return NO;
    }

    BOOL isDirectory = NO;
    if (![fileManager fileExistsAtPath:expandedPath isDirectory:&isDirectory]) {
        return NO;
    }

    NSError *error = nil;
    BOOL applied = [fileManager setAttributes:@{ NSFilePosixPermissions: permissions }
                                 ofItemAtPath:expandedPath
                                        error:&error];
    if (!applied && error != nil) {
        NSLog(@"[RCUtilities] Failed to set POSIX permissions for '%@': %@", expandedPath, error.localizedDescription);
    }
    return applied;
}

+ (BOOL)isProtectedClipDataFileName:(NSString *)fileName {
    NSString *lowercaseName = fileName.lowercaseString;
    return [lowercaseName hasSuffix:@".rcclip"]
        || [lowercaseName hasSuffix:@".thumbnail.tiff"]
        || [lowercaseName hasSuffix:@".thumb"];
}

@end
