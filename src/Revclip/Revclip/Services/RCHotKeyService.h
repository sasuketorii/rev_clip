//
//  RCHotKeyService.h
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Current project: AGPL-3.0-only; legacy portions: MIT. See THIRD_PARTY_NOTICES.md.
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

// Command-Shift-2 (kVK_ANSI_2). The single definition of the faster OCR default.
NS_INLINE RCKeyCombo RCDefaultOCRKeyCombo(void) {
    return RCMakeKeyCombo(19, cmdKey | shiftKey);
}

// Assignable shortcut slots. Snippet folders take part in duplicate checks as
// "folder:<identifier>" but have no assignment entry.
extern NSString * const RCHotKeySlotMain;
extern NSString * const RCHotKeySlotHistory;
extern NSString * const RCHotKeySlotSnippet;
extern NSString * const RCHotKeySlotClearHistory;
extern NSString * const RCHotKeySlotOCR;
extern NSString * const RCHotKeySlotFolderPrefix;

typedef NS_ENUM(NSInteger, RCHotKeyAssignmentKind) {
    RCHotKeyAssignmentKindSet = 0,
    RCHotKeyAssignmentKindClear,
    RCHotKeyAssignmentKindDefault,
    // Keeps the stored combination and re-evaluates only its registration, for a
    // request that switches the owning feature on or off.
    RCHotKeyAssignmentKindKeep,
};

typedef NS_ENUM(NSInteger, RCHotKeyAssignmentStatus) {
    RCHotKeyAssignmentStatusOK = 0,
    // Unknown slot, repeated slot, or a combination the recorder would not accept.
    RCHotKeyAssignmentStatusInvalid,
    // Another Revclip feature already uses the combination; conflictingSlot names it.
    RCHotKeyAssignmentStatusInternalConflict,
    // An enabled macOS keyboard shortcut uses it (CopySymbolicHotKeys; no name is available).
    RCHotKeyAssignmentStatusSystemReserved,
    // The OS refused the registration. This is not a detector of other apps' shortcuts:
    // hot keys are non-exclusive, so another app using the same keys does not fail here.
    RCHotKeyAssignmentStatusRegistrationFailed,
    // Panic Erase holds the write barrier; nothing is registered or stored.
    RCHotKeyAssignmentStatusUnavailable,
    // A supported external application has a matching saved assignment.
    RCHotKeyAssignmentStatusExternalConflict,
    RCHotKeyAssignmentStatusStandardReserved,
};

@interface RCHotKeyAssignment : NSObject
@property (nonatomic, readonly, copy) NSString *slot;
@property (nonatomic, readonly) RCHotKeyAssignmentKind kind;
@property (nonatomic, readonly) RCKeyCombo combo;
+ (instancetype)assignmentSettingSlot:(NSString *)slot combo:(RCKeyCombo)combo;
+ (instancetype)assignmentClearingSlot:(NSString *)slot;
+ (instancetype)assignmentRestoringDefaultForSlot:(NSString *)slot;
+ (instancetype)assignmentKeepingSlot:(NSString *)slot;
@end

@interface RCHotKeyAssignmentResult : NSObject
@property (nonatomic, readonly) RCHotKeyAssignmentStatus status;
@property (nonatomic, readonly, copy, nullable) NSString *failedSlot;
@property (nonatomic, readonly, copy, nullable) NSString *conflictingSlot;
@property (nonatomic, readonly, copy, nullable) NSString *conflictingApplication;
@property (nonatomic, readonly) OSStatus osStatus;
@property (nonatomic, readonly) BOOL succeeded;
@end

@interface RCHotKeyService : NSObject

+ (instancetype)shared;
// Main-thread scoped capture: registrations stay intact; only action dispatch is
// suspended while a live recorder owns this weak reference.
@property (nonatomic, weak, nullable) id shortcutRecordingOwner;

// Scoped Cmd+, routing while a Revclip menu is tracking. Never persisted.
- (void)beginMenuPreferencesShortcutForOwner:(id)owner action:(dispatch_block_t)action;
- (void)endMenuPreferencesShortcutForOwner:(id)owner;

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

- (void)reloadOCRHotKey;

// 全ホットキー解除
- (void)unregisterAllHotKeys;

// UserDefaultsからKeyComboを読み込み・登録
- (void)loadAndRegisterHotKeysFromDefaults;

// The one contract for the preferences UI and the CLI. The whole batch is checked
// against its own final state (so two slots may swap), only combinations nobody in
// Revclip currently holds are registered with the OS first, and nothing already
// registered or stored changes unless every step succeeded. Main thread is implied.
- (RCHotKeyAssignmentResult *)applyAssignments:(NSArray<RCHotKeyAssignment *> *)assignments;
// Two-step form for callers with other fallible work in the same request (the CLI):
// prepare validates and registers only the new combinations and changes nothing else;
// the returned transaction is then committed (cannot fail) or discarded (releases only
// what prepare registered). transaction is nil exactly when the result did not succeed.
// ocrEnabledAfterCommit is the faster OCR switch as the same request will leave it
// (nil: unchanged). Registration is planned for that state, not the present one.
- (RCHotKeyAssignmentResult *)prepareAssignments:(NSArray<RCHotKeyAssignment *> *)assignments
                           ocrEnabledAfterCommit:(nullable NSNumber *)ocrEnabledAfterCommit
                                     transaction:(id _Nullable * _Nonnull)transaction;
- (void)commitPreparedAssignments:(id)transaction;
- (void)discardPreparedAssignments:(id)transaction;
// Validation only; never registers, stores, or contacts the OS registration API.
- (RCHotKeyAssignmentResult *)validateAssignments:(NSArray<RCHotKeyAssignment *> *)assignments;
// Stored value, or the slot's default when nothing is stored. Invalid when cleared.
- (RCKeyCombo)configuredKeyComboForSlot:(NSString *)slot;
+ (NSArray<NSString *> *)assignableSlots;
+ (nullable NSString *)defaultsKeyForSlot:(NSString *)slot;
+ (RCKeyCombo)defaultKeyComboForSlot:(NSString *)slot;
// At least one modifier; on macOS 15 and later Option needs Command or Control.
+ (BOOL)isAssignableKeyCombo:(RCKeyCombo)combo;

// KeyCombo ↔ UserDefaults変換
+ (RCKeyCombo)keyComboFromUserDefaults:(NSString *)key;
+ (void)saveKeyCombo:(RCKeyCombo)combo toUserDefaults:(NSString *)key;

// Shared layout-aware base character for display and standard-command checks.
+ (NSString *)baseCharacterForKeyCode:(UInt16)keyCode;

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
extern NSString * const RCHotKeyOCRTriggeredNotification;
// NSNumber (double): GetEventTime of the Carbon hot key event, seconds since startup.
extern NSString * const RCHotKeyEventTimestampUserInfoKey;
extern NSString * const RCHotKeyRegistrationDidFailNotification;
extern NSString * const RCHotKeyRegistrationFailureIdentifierUserInfoKey;
extern NSString * const RCHotKeyRegistrationFailureKeyCodeUserInfoKey;
extern NSString * const RCHotKeyRegistrationFailureModifiersUserInfoKey;
extern NSString * const RCHotKeyRegistrationFailureStatusUserInfoKey;
extern NSString * const RCHotKeyRegistrationFailureFolderIdentifierUserInfoKey;
// Present when the hot key was not registered because another Revclip slot uses it.
extern NSString * const RCHotKeyRegistrationFailureConflictingSlotUserInfoKey;

NS_ASSUME_NONNULL_END
