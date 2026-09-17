//
//  RCMenuManager.h
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Current project: AGPL-3.0-only; legacy portions: MIT. See THIRD_PARTY_NOTICES.md.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class RCClipItem;

@interface RCMenuManager : NSObject

+ (instancetype)shared;

// ステータスバーアイテムのセットアップ
- (void)setupStatusItem;

// メニューの再構築
- (void)rebuildMenu;

// Panic Erase 用: サムネイルキャッシュを即時破棄
- (void)clearThumbnailCache;

// The main hotkey's menu at the pointer. Also the entry for opening Revclip from
// Applications: a request after Clear, Panic or quit, a repeat, or one made while a
// menu already tracks is dropped here.
- (void)popUpStatusMenuFromHotKey;

// Main thread only. Runs block once no Revclip menu is tracking. An open menu is
// closed without its fade, and the block runs after menuDidClose: has unwound the
// tracking run loop. Requests made while one is pending are coalesced, so a single
// key press cannot start a command and immediately toggle it off.
- (void)performAfterMenuTrackingEnds:(dispatch_block_t)block;

// Services entry (NSServices, NSMessage "insertFromRevclip"). Takes no input and returns
// text: it shows the history and template menu and writes the picked text to the
// service pasteboard, for the requesting application to insert. It never writes the
// general pasteboard and never sends a paste keystroke. Nothing is returned for a
// cancel, a non-text item, a stop (Clear, Panic, quit) or a time-out.
- (void)insertFromRevclip:(NSPasteboard *)pasteboard userData:(nullable NSString *)userData error:(NSString * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
