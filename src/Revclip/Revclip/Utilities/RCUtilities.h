//
//  RCUtilities.h
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RCUtilities : NSObject

// 全デフォルト設定を登録
+ (void)registerDefaultSettings;

// Application Supportパスの取得
+ (NSString *)applicationSupportPath;

// クリップデータ保存ディレクトリパスの取得
+ (NSString *)clipDataDirectoryPath;

// ディレクトリの自動作成
+ (BOOL)ensureDirectoryExists:(NSString *)path;

// データ保護属性の適用（権限修復 + Backup/Spotlight除外）
+ (void)applyDataProtectionAttributes;

@end

NS_ASSUME_NONNULL_END
