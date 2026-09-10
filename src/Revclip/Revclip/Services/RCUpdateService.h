//
//  RCUpdateService.h
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const RCUpdateServiceDidFailNotification;

extern NSString * const RCUpdateServiceErrorUserInfoKey;
extern NSString * const RCUpdateServiceFailureReasonUserInfoKey;
extern NSString * const RCUpdateServiceUpdateCheckUserInfoKey;

typedef NS_ENUM(NSInteger, RCUpdateServiceUpdateCheck) {
    RCUpdateServiceUpdateCheckUnknown = -1,
    RCUpdateServiceUpdateCheckUpdates = 0,
    RCUpdateServiceUpdateCheckUpdatesInBackground = 1,
    RCUpdateServiceUpdateCheckUpdateInformation = 2,
};

@interface RCUpdateService : NSObject

+ (instancetype)shared;

/// Sparkle の SPUStandardUpdaterController を初期化
- (void)setupUpdater;

/// 手動アップデートチェック
- (BOOL)checkForUpdates;

/// アップデートチェック可能かどうか
@property (nonatomic, readonly) BOOL canCheckForUpdates;

/// 自動チェックの有効/無効
@property (nonatomic, assign, getter=isAutomaticallyChecksForUpdates) BOOL automaticallyChecksForUpdates;

/// アップデート間隔（秒）
@property (nonatomic, assign) NSTimeInterval updateCheckInterval;

/// 直近のアップデート関連エラー
@property (nonatomic, strong, nullable, readonly) NSError *lastError;

@end

NS_ASSUME_NONNULL_END
