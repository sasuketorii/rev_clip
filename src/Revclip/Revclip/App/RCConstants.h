//
//  RCConstants.h
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, RCAutoExpiryUnit) {
    RCAutoExpiryUnitDay = 0,
    RCAutoExpiryUnitHour = 1,
    RCAutoExpiryUnitMinute = 2,
};

// General
extern NSString * const kRCPrefMaxHistorySizeKey;              // Default: 30
extern NSString * const kRCPrefAutoExpiryEnabledKey;           // Default: NO
extern NSString * const kRCPrefAutoExpiryValueKey;             // Default: 30
extern NSString * const kRCPrefAutoExpiryUnitKey;              // Default: 0 (day)
extern NSString * const kRCPrefMaxClipSizeBytesKey;            // Default: 52428800 (50MB)
extern NSString * const kRCPrefInputPasteCommandKey;           // Default: YES
extern NSString * const kRCPrefReorderClipsAfterPasting;       // Default: YES
extern NSString * const kRCPrefShowStatusItemKey;              // Default: 1 (black)
extern NSString * const kRCPrefStoreTypesKey;                  // Default: all types YES
extern NSString * const kRCPrefOverwriteSameHistory;           // Default: YES
extern NSString * const kRCPrefCopySameHistory;                // Default: YES
extern NSString * const kRCCollectCrashReport;                 // Default: YES
extern NSString * const kRCLoginItem;                              // Default: YES
extern NSString * const kRCSuppressAlertForLoginItem;              // Default: NO

// Menu
extern NSString * const kRCPrefNumberOfItemsPlaceInlineKey;        // Default: 0
extern NSString * const kRCPrefNumberOfItemsPlaceInsideFolderKey;  // Default: 10
extern NSString * const kRCPrefMaxMenuItemTitleLengthKey;          // Default: 40
extern NSString * const kRCPrefMenuIconSizeKey;                    // Default: 16
extern NSString * const kRCPrefShowIconInTheMenuKey;               // Default: YES
extern NSString * const kRCMenuItemsAreMarkedWithNumbersKey;       // Default: YES
extern NSString * const kRCPrefMenuItemsTitleStartWithZeroKey;     // Default: NO
extern NSString * const kRCShowToolTipOnMenuItemKey;               // Default: YES
extern NSString * const kRCMaxLengthOfToolTipKey;                  // Default: 10000
extern NSString * const kRCShowImageInTheMenuKey;                  // Default: YES
extern NSString * const kRCPrefShowColorPreviewInTheMenu;          // Default: YES
extern NSString * const kRCAddNumericKeyEquivalentsKey;            // Default: NO
extern NSString * const kRCThumbnailWidthKey;                      // Default: 100
extern NSString * const kRCThumbnailHeightKey;                     // Default: 32
extern NSString * const kRCPrefAddClearHistoryMenuItemKey;         // Default: YES
extern NSString * const kRCPrefShowAlertBeforeClearHistoryKey;     // Default: YES

// Shortcuts
extern NSString * const kRCHotKeyMainKeyCombo;
extern NSString * const kRCHotKeyHistoryKeyCombo;
extern NSString * const kRCHotKeySnippetKeyCombo;
extern NSString * const kRCClearHistoryKeyCombo;
extern NSString * const kRCPanicButtonKeyCombo;
extern NSString * const kRCFolderKeyCombos;
extern NSString * const kRCMigrateNewKeyCombo;
extern NSString * const kRCPrefHotKeysKey;

// Updates
extern NSString * const kRCEnableAutomaticCheckKey;     // Default: YES
extern NSString * const kRCUpdateCheckIntervalKey;      // Default: 86400

// Beta
extern NSString * const kRCBetaPastePlainText;                      // Default: YES
extern NSString * const kRCBetaPastePlainTextModifier;              // Default: 0 (Cmd)
extern NSString * const kRCBetaDeleteHistory;                       // Default: NO
extern NSString * const kRCBetaDeleteHistoryModifier;               // Default: 0 (Cmd)
extern NSString * const kRCBetaPasteAndDeleteHistory;               // Default: NO
extern NSString * const kRCBetaPasteAndDeleteHistoryModifier;       // Default: 0 (Cmd)
extern NSString * const kRCBetaObserveScreenshot;                   // Default: NO

// Exclude
extern NSString * const kRCExcludeApplications;

// Snippets
extern NSString * const kRCSuppressAlertForDeleteSnippet;
extern NSString * const RCSnippetsDidChangeNotification;

// Paths
extern NSString * const kRCApplicationSupportDirectoryPath;         // ~/Library/Application Support/Revclip/
extern NSString * const kRCClipDataDirectoryPath;                   // ~/Library/Application Support/Revclip/ClipsData/

NS_ASSUME_NONNULL_END
