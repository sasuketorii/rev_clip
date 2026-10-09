//
//  RCMoveToApplicationsService.h
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Current project: AGPL-3.0-only; legacy portions: MIT. See THIRD_PARTY_NOTICES.md.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RCMoveToApplicationsService : NSObject

+ (instancetype)shared;

/// アプリが /Applications に存在するかチェックし、必要なら移動を提案
/// applicationDidFinishLaunching: からメインスレッドで一度だけ呼ぶ（それ以外のスレッドでは何もせず NO）
/// 戻り値は「再起動の引き継ぎを開始した」場合のみ YES。YES のとき呼び出し側は何も初期化せず
/// 直ちに戻る（このプロセスは終了に向かう）。それ以外の経路（早期return、移動の辞退、
/// 移動前の失敗）は NO で、通常どおり起動を続ける。
- (BOOL)checkAndMoveIfNeeded;

/// YES for build products (all comparisons case-insensitive):
///  - any path component equal to DerivedData,
///  - the consecutive components Library/Developer/Xcode,
///  - <build|build-demo>/<Debug|Release|Demo>/<bundle>,
///  - Build/Products/<Debug|Release|Demo>/<bundle>.
/// These never offer the move and never auto-register a login item.
+ (BOOL)isBuildProductBundlePath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
