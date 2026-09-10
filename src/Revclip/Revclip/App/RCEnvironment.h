//
//  RCEnvironment.h
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class RCClipboardService;
@class RCPasteService;
@class RCHotKeyService;
@class RCAccessibilityService;
@class RCExcludeAppService;
@class RCDataCleanService;
@class RCLoginItemService;
@class RCPrivacyService;
@class RCMenuManager;
@class RCDatabaseManager;

@interface RCEnvironment : NSObject

+ (instancetype)shared;

// Services
@property (nonatomic, strong, nullable) RCClipboardService *clipboardService;
@property (nonatomic, strong, nullable) RCPasteService *pasteService;
@property (nonatomic, strong, nullable) RCHotKeyService *hotKeyService;
@property (nonatomic, strong, nullable) RCAccessibilityService *accessibilityService;
@property (nonatomic, strong, nullable) RCExcludeAppService *excludeAppService;
@property (nonatomic, strong, nullable) RCDataCleanService *dataCleanService;
@property (nonatomic, strong, nullable) RCLoginItemService *loginItemService;
@property (nonatomic, strong, nullable) RCPrivacyService *privacyService;

// Managers
@property (nonatomic, strong, nullable) RCMenuManager *menuManager;
@property (nonatomic, strong, nullable) RCDatabaseManager *databaseManager;

@end

NS_ASSUME_NONNULL_END
