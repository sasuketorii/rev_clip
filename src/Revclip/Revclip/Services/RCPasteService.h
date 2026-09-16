//
//  RCPasteService.h
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Current project: AGPL-3.0-only; legacy portions: MIT. See THIRD_PARTY_NOTICES.md.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class RCClipData;
@class RCClipboardService;

@interface RCPasteService : NSObject

+ (instancetype)shared;

// RCClipDataをペーストボードに設定してアクティブアプリに貼り付け
- (void)pasteClipData:(RCClipData *)clipData;
- (void)pasteClipData:(RCClipData *)clipData
      toApplication:(nullable NSRunningApplication *)application;

// History selection only: successful clipboard restoration counts as use even
// with automatic paste disabled or a later key-event cancellation. Templates
// must use the overload without historyDataHash.
- (void)pasteClipData:(RCClipData *)clipData
       toApplication:(nullable NSRunningApplication *)application
     historyDataHash:(nullable NSString *)historyDataHash;

// プレーンテキストとしてペースト
- (void)pastePlainText:(NSString *)text;
- (void)pastePlainText:(NSString *)text
       toApplication:(nullable NSRunningApplication *)application;

// Cmd+Vキーイベントを送信
- (void)sendPasteKeyStroke;

// Overridable process/IO boundaries. Production calls and scheduled callbacks
// run on main; tests replace all of these with in-memory fakes.
- (NSPasteboard *)pasteboard;
- (RCClipboardService *)clipboardService;
- (nullable NSRunningApplication *)frontmostApplication;
- (nullable id)focusedElementForApplication:(NSRunningApplication *)application;
- (BOOL)activateApplication:(NSRunningApplication *)application;
- (NSTimeInterval)pasteClock;
- (void)scheduleAfterDelay:(NSTimeInterval)delay block:(dispatch_block_t)block;

@end

NS_ASSUME_NONNULL_END
