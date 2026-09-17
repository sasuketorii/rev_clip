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
- (NSDictionary<NSString *, NSValue *> *)rc_activeFolderKeyCombos;
- (BOOL)rc_panicInProgress;
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
@property BOOL panic;
@property uintptr_t nextRef;
@end

NS_ASSUME_NONNULL_END
