//
//  RCHotKeyContractProbe.h
//  RevclipTests
//
//  Copyright (c) 2024-2026 Revclip. Current project: AGPL-3.0-only; legacy portions: MIT. See THIRD_PARTY_NOTICES.md.
//

#import "RCHotKeyService.h"

NS_ASSUME_NONNULL_BEGIN

@interface RCHotKeyService (ContractTesting)
- (void)installHotKeyEventHandlerIfNeeded;
- (OSStatus)rc_registerEventHotKey:(RCKeyCombo)combo carbonID:(UInt32)carbonID ref:(EventHotKeyRef _Nullable * _Nonnull)outRef;
- (OSStatus)rc_unregisterEventHotKey:(EventHotKeyRef)ref;
- (NSArray<NSDictionary *> *)rc_systemSymbolicHotKeys;
- (NSArray<NSData *> *)rc_cleanShotShortcutData;
- (NSDictionary<NSString *, NSValue *> *)rc_activeFolderKeyCombos;
- (BOOL)rc_panicInProgress;
- (UInt16)rc_menuPreferencesKeyCode;
- (BOOL)rc_startMenuPreferencesCapture;
- (BOOL)rc_menuTrackingContextActive;
- (void)rc_stopMenuPreferencesCapture;
- (CGEventRef)captureMenuPreferencesEvent:(CGEventRef)event type:(CGEventType)type;
- (void)postNotificationForCarbonHotKeyID:(UInt32)carbonID eventTime:(EventTime)eventTime;
@end

// A fake OS: no Carbon call is made, so the user's real shortcuts are never touched.
// NSUserDefaults.standard is the in-memory test domain in this host.
@interface RCHotKeyContractProbe : RCHotKeyService
@property (nonatomic, strong) NSMutableArray<NSString *> *calls;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *liveCarbonIDs; // "keyCode:modifiers" -> carbon id
@property (nonatomic, strong) NSMutableSet<NSString *> *refused;
@property (nonatomic, strong) NSArray<NSDictionary *> *systemHotKeys;
@property (nonatomic, strong) NSDictionary<NSString *, NSValue *> *folders;
@property (nonatomic, strong) NSArray<NSData *> *externalShortcutData;
@property BOOL panic;
@property NSUInteger menuCaptureStarts;
@property NSUInteger menuCaptureStops;
@property BOOL refuseMenuCapture;
@property BOOL outsideMenuTracking;
@property UInt16 menuPreferencesCode;
@property uintptr_t nextRef;
@end

NS_ASSUME_NONNULL_END
