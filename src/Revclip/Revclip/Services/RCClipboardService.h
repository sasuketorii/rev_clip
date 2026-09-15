//
//  RCClipboardService.h
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface RCClipboardService : NSObject

+ (instancetype)shared;

// 監視の開始・停止
- (void)startMonitoring;
- (void)stopMonitoring;
@property (atomic, readonly) BOOL isMonitoring;

// Call on main immediately after a synchronous internal pasteboard write.
// Only that generation is excluded; subsequent external copies remain eligible.
- (void)recordInternalPasteboardChangeCount:(NSInteger)changeCount;

// 手動での最新クリップ取得
- (void)captureCurrentClipboard;

// Drain earlier acquisition AND persistence work (used by clear/termination).
- (void)flushQueueWithCompletion:(void(^)(void))completion;

@end

// 通知名
extern NSString * const RCClipboardDidChangeNotification;

NS_ASSUME_NONNULL_END
