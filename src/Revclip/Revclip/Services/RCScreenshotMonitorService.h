//
//  RCScreenshotMonitorService.h
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RCScreenshotMonitorService : NSObject

+ (instancetype)shared;

/// 監視中かどうか
@property (nonatomic, readonly, getter=isMonitoring) BOOL monitoring;

/// 監視を開始（NSUserDefaults kRCBetaObserveScreenshot が YES の場合のみ有効）
- (void)startMonitoring;

/// 監視を停止
- (void)stopMonitoring;

/// Panic Erase 用: screenshotImportQueue までの処理をドレイン
- (void)flushQueueWithCompletion:(void(^)(void))completion;

@end

NS_ASSUME_NONNULL_END
