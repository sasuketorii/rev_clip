//
//  RCHotKeyService.h
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

// KeyCombo構造体
typedef struct {
    UInt32 keyCode;
    UInt32 modifiers;  // Carbon修飾キーフラグ
} RCKeyCombo;

NS_INLINE RCKeyCombo RCMakeKeyCombo(UInt32 keyCode, UInt32 modifiers) {
    RCKeyCombo combo;
    combo.keyCode = keyCode;
    combo.modifiers = modifiers;
    return combo;
}

NS_INLINE RCKeyCombo RCInvalidKeyCombo(void) {
    return RCMakeKeyCombo(UINT32_MAX, 0);
}

NS_INLINE BOOL RCIsUnsetKeyCombo(RCKeyCombo combo) {
    return combo.keyCode == 0 && combo.modifiers == 0;
}

NS_INLINE BOOL RCIsValidKeyCombo(RCKeyCombo combo) {
    return combo.keyCode != UINT32_MAX && !RCIsUnsetKeyCombo(combo);
}

@interface RCHotKeyService : NSObject

+ (instancetype)shared;

// メインホットキー登録（メニュー表示）
- (BOOL)registerMainHotKey:(RCKeyCombo)combo;
// 履歴ホットキー登録（履歴メニュー表示）
- (BOOL)registerHistoryHotKey:(RCKeyCombo)combo;
// スニペットホットキー登録（スニペットメニュー表示）
- (BOOL)registerSnippetHotKey:(RCKeyCombo)combo;
// 履歴クリアホットキー登録
- (BOOL)registerClearHistoryHotKey:(RCKeyCombo)combo;
// フォルダ個別ホットキー登録
- (BOOL)registerSnippetFolderHotKey:(RCKeyCombo)combo forFolderIdentifier:(NSString *)identifier;
// フォルダ個別ホットキー解除
- (void)unregisterSnippetFolderHotKey:(NSString *)identifier;
// 全フォルダホットキーの再読み込み
- (void)reloadFolderHotKeys;

// 全ホットキー解除
- (void)unregisterAllHotKeys;

// UserDefaultsからKeyComboを読み込み・登録
- (void)loadAndRegisterHotKeysFromDefaults;

// KeyCombo ↔ UserDefaults変換
+ (RCKeyCombo)keyComboFromUserDefaults:(NSString *)key;
+ (void)saveKeyCombo:(RCKeyCombo)combo toUserDefaults:(NSString *)key;

// Cocoa修飾キー ↔ Carbon修飾キー変換
+ (UInt32)carbonModifiersFromCocoaModifiers:(NSEventModifierFlags)cocoaModifiers;
+ (NSEventModifierFlags)cocoaModifiersFromCarbonModifiers:(UInt32)carbonModifiers;

@end

extern NSString * const RCHotKeyMainTriggeredNotification;
extern NSString * const RCHotKeyHistoryTriggeredNotification;
extern NSString * const RCHotKeySnippetTriggeredNotification;
extern NSString * const RCHotKeyClearHistoryTriggeredNotification;
extern NSString * const RCHotKeySnippetFolderTriggeredNotification;
extern NSString * const RCHotKeyFolderIdentifierUserInfoKey;
extern NSString * const RCHotKeyRegistrationDidFailNotification;
extern NSString * const RCHotKeyRegistrationFailureIdentifierUserInfoKey;
extern NSString * const RCHotKeyRegistrationFailureKeyCodeUserInfoKey;
extern NSString * const RCHotKeyRegistrationFailureModifiersUserInfoKey;
extern NSString * const RCHotKeyRegistrationFailureStatusUserInfoKey;
extern NSString * const RCHotKeyRegistrationFailureFolderIdentifierUserInfoKey;

NS_ASSUME_NONNULL_END
