//
//  RCDataCleanService.h
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class RCDatabaseManager;

@interface RCDataCleanService : NSObject

+ (instancetype)shared;

// クリーンアップタイマーの開始・停止
- (void)startCleanupTimer;
- (void)stopCleanupTimer;

// 手動クリーンアップ実行
- (void)performCleanup;

// 有効時のみ期限切れ履歴を削除
- (void)expireHistoryIfNeededWithDatabaseManager:(RCDatabaseManager *)databaseManager;

// クリップ保存後の軽量デバウンスクリーンアップを予約
- (void)scheduleDebouncedCleanup;

// Panic Erase 用: cleanupQueue までの処理をドレイン
- (void)flushQueueWithCompletion:(void(^)(void))completion;

@end

NS_ASSUME_NONNULL_END
