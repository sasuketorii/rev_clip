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

@end

NS_ASSUME_NONNULL_END
