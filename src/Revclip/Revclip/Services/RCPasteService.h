//
//  RCPasteService.h
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class RCClipData;

@interface RCPasteService : NSObject

+ (instancetype)shared;

// RCClipDataをペーストボードに設定してアクティブアプリに貼り付け
- (void)pasteClipData:(RCClipData *)clipData;
- (void)pasteClipData:(RCClipData *)clipData
      toApplication:(nullable NSRunningApplication *)application;

// プレーンテキストとしてペースト
- (void)pastePlainText:(NSString *)text;
- (void)pastePlainText:(NSString *)text
       toApplication:(nullable NSRunningApplication *)application;

// Cmd+Vキーイベントを送信
- (void)sendPasteKeyStroke;

@end

NS_ASSUME_NONNULL_END
