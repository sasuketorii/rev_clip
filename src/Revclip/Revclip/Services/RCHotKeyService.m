//
//  RCHotKeyService.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Current project: AGPL-3.0-only; legacy portions: MIT. See THIRD_PARTY_NOTICES.md.
//

#import "RCHotKeyService.h"

#import <stdint.h>
#import <stdlib.h>

#import "RCConstants.h"
#import "RCDatabaseManager.h"
#import "RCPanicEraseService.h"

NSString * const RCHotKeyMainTriggeredNotification = @"RCHotKeyMainTriggeredNotification";
NSString * const RCHotKeyHistoryTriggeredNotification = @"RCHotKeyHistoryTriggeredNotification";
NSString * const RCHotKeySnippetTriggeredNotification = @"RCHotKeySnippetTriggeredNotification";
NSString * const RCHotKeyClearHistoryTriggeredNotification = @"RCHotKeyClearHistoryTriggeredNotification";
NSString * const RCHotKeySnippetFolderTriggeredNotification = @"RCHotKeySnippetFolderTriggeredNotification";
NSString * const RCHotKeyFolderIdentifierUserInfoKey = @"folderIdentifier";
NSString * const RCHotKeyRegistrationDidFailNotification = @"RCHotKeyRegistrationDidFailNotification";
NSString * const RCHotKeyRegistrationFailureIdentifierUserInfoKey = @"identifier";
NSString * const RCHotKeyRegistrationFailureKeyCodeUserInfoKey = @"keyCode";
NSString * const RCHotKeyRegistrationFailureModifiersUserInfoKey = @"modifiers";
NSString * const RCHotKeyRegistrationFailureStatusUserInfoKey = @"status";
NSString * const RCHotKeyRegistrationFailureFolderIdentifierUserInfoKey = @"folderIdentifier";
NSString * const RCHotKeyRegistrationFailureConflictingSlotUserInfoKey = @"conflictingSlot";
NSString * const RCHotKeyOCRTriggeredNotification = @"RCHotKeyOCRTriggeredNotification";
NSString * const RCHotKeyEventTimestampUserInfoKey = @"eventTimestamp";

NSString * const RCHotKeySlotMain = @"main";
NSString * const RCHotKeySlotHistory = @"history";
NSString * const RCHotKeySlotSnippet = @"snippet";
NSString * const RCHotKeySlotClearHistory = @"clear_history";
NSString * const RCHotKeySlotOCR = @"ocr";
NSString * const RCHotKeySlotFolderPrefix = @"folder:";

static OSType const kRCHotKeySignature = 'RCHK';

static UInt32 const kRCHotKeyIdentifierOCR = 5;

static UInt32 const kRCHotKeyIdentifierMain = 1;
static UInt32 const kRCHotKeyIdentifierHistory = 2;
static UInt32 const kRCHotKeyIdentifierSnippet = 3;
static UInt32 const kRCHotKeyIdentifierClearHistory = 4;
static UInt32 const kRCHotKeyIdentifierSnippetFolderBase = 100;
// Fixed slots register under a unique OS identifier per registration, so a live
// registration can change owner without an OS call. Far above the folder range.
static UInt32 const kRCHotKeyIdentifierDynamicBase = 0x40000000;

static UInt32 const kRCKeyCodeV = 9;
static UInt32 const kRCKeyCodeB = 11;

static BOOL RCReadUInt32FromObject(id object, UInt32 *outValue) {
    if (outValue == NULL) {
        return NO;
    }

    if ([object isKindOfClass:[NSNumber class]]) {
        NSNumber *number = (NSNumber *)object;
        if (number.unsignedLongLongValue > UINT32_MAX) {
            return NO;
        }
        *outValue = (UInt32)number.unsignedIntValue;
        return YES;
    }

    if ([object isKindOfClass:[NSString class]]) {
        NSString *string = (NSString *)object;
        const char *cString = string.UTF8String;
        if (cString == NULL || *cString == '\0') {
            return NO;
        }
        char *endptr = NULL;
        unsigned long long value = strtoull(cString, &endptr, 10);
        if (endptr == cString || (endptr != NULL && *endptr != '\0')) {
            return NO;
        }
        if (value > UINT32_MAX) {
            return NO;
        }
        *outValue = (UInt32)value;
        return YES;
    }

    return NO;
}

static BOOL RCIsExplicitlyUnsetKeyComboObject(id object) {
    if (![object isKindOfClass:[NSDictionary class]]) {
        return NO;
    }

    NSDictionary *dictionary = (NSDictionary *)object;
    UInt32 keyCode = 0;
    UInt32 modifiers = 0;
    if (!RCReadUInt32FromObject(dictionary[@"keyCode"], &keyCode)) {
        return NO;
    }
    if (!RCReadUInt32FromObject(dictionary[@"modifiers"], &modifiers)) {
        return NO;
    }

    return RCIsUnsetKeyCombo(RCMakeKeyCombo(keyCode, modifiers));
}

static RCKeyCombo RCKeyComboFromDictionaryObject(id object) {
    if (![object isKindOfClass:[NSDictionary class]]) {
        return RCInvalidKeyCombo();
    }

    NSDictionary *dictionary = (NSDictionary *)object;
    UInt32 keyCode = 0;
    UInt32 modifiers = 0;
    if (!RCReadUInt32FromObject(dictionary[@"keyCode"], &keyCode)) {
        return RCInvalidKeyCombo();
    }
    if (!RCReadUInt32FromObject(dictionary[@"modifiers"], &modifiers)) {
        return RCInvalidKeyCombo();
    }

    RCKeyCombo combo = RCMakeKeyCombo(keyCode, modifiers);
    if (!RCIsValidKeyCombo(combo)) {
        return RCInvalidKeyCombo();
    }

    return combo;
}

static NSString *RCStringFromKeyCombo(RCKeyCombo combo) {
    return [NSString stringWithFormat:@"%u:%u", (unsigned int)combo.keyCode, (unsigned int)combo.modifiers];
}

static OSStatus RCHotKeyEventHandler(EventHandlerCallRef nextHandler, EventRef event, void *userData);

static UInt32 RCHotKeySlotIdentifier(NSString *slot) {
    if ([slot isEqualToString:RCHotKeySlotMain]) return kRCHotKeyIdentifierMain;
    if ([slot isEqualToString:RCHotKeySlotHistory]) return kRCHotKeyIdentifierHistory;
    if ([slot isEqualToString:RCHotKeySlotSnippet]) return kRCHotKeyIdentifierSnippet;
    if ([slot isEqualToString:RCHotKeySlotClearHistory]) return kRCHotKeyIdentifierClearHistory;
    if ([slot isEqualToString:RCHotKeySlotOCR]) return kRCHotKeyIdentifierOCR;
    return 0;
}

@interface RCHotKeyAssignment ()
@property (nonatomic, readwrite, copy) NSString *slot;
@property (nonatomic, readwrite) RCHotKeyAssignmentKind kind;
@property (nonatomic, readwrite) RCKeyCombo combo;
@end
@implementation RCHotKeyAssignment
+ (instancetype)assignmentWithSlot:(NSString *)slot kind:(RCHotKeyAssignmentKind)kind combo:(RCKeyCombo)combo {
    RCHotKeyAssignment *assignment = [self new];
    assignment.slot = slot ?: @""; assignment.kind = kind; assignment.combo = combo;
    return assignment;
}
+ (instancetype)assignmentSettingSlot:(NSString *)slot combo:(RCKeyCombo)combo {
    return [self assignmentWithSlot:slot kind:RCHotKeyAssignmentKindSet combo:combo];
}
+ (instancetype)assignmentClearingSlot:(NSString *)slot {
    return [self assignmentWithSlot:slot kind:RCHotKeyAssignmentKindClear combo:RCInvalidKeyCombo()];
}
+ (instancetype)assignmentRestoringDefaultForSlot:(NSString *)slot {
    return [self assignmentWithSlot:slot kind:RCHotKeyAssignmentKindDefault combo:RCInvalidKeyCombo()];
}
+ (instancetype)assignmentKeepingSlot:(NSString *)slot {
    return [self assignmentWithSlot:slot kind:RCHotKeyAssignmentKindKeep combo:RCInvalidKeyCombo()];
}
@end

@interface RCHotKeyAssignmentResult ()
@property (nonatomic, readwrite) RCHotKeyAssignmentStatus status;
@property (nonatomic, readwrite, copy, nullable) NSString *failedSlot;
@property (nonatomic, readwrite, copy, nullable) NSString *conflictingSlot;
@property (nonatomic, readwrite) OSStatus osStatus;
@end
@implementation RCHotKeyAssignmentResult
+ (instancetype)resultWithStatus:(RCHotKeyAssignmentStatus)status failedSlot:(NSString *)failedSlot
                 conflictingSlot:(NSString *)conflictingSlot osStatus:(OSStatus)osStatus {
    RCHotKeyAssignmentResult *result = [self new];
    result.status = status; result.failedSlot = failedSlot; result.conflictingSlot = conflictingSlot; result.osStatus = osStatus;
    return result;
}
- (BOOL)succeeded { return self.status == RCHotKeyAssignmentStatusOK; }
@end

// Validated plan plus the registrations prepare made. Nothing in it is live until commit.
@interface RCHotKeyTransaction : NSObject
@property (nonatomic, copy) NSArray<RCHotKeyAssignment *> *assignments;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *targets;       // slot -> RCKeyCombo
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *preparedRefs;  // slot -> EventHotKeyRef
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *preparedCarbonIDs;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *transfers;    // slot -> slot holding the live registration
@property (nonatomic, strong, nullable) NSNumber *ocrEnabledAfterCommit;
@property (nonatomic) BOOL finished;
@end
@implementation RCHotKeyTransaction
@end

static NSValue *RCValueFromKeyCombo(RCKeyCombo combo) { return [NSValue valueWithBytes:&combo objCType:@encode(RCKeyCombo)]; }
static RCKeyCombo RCKeyComboFromValue(NSValue *value) {
    RCKeyCombo combo = RCInvalidKeyCombo();
    if (value != nil) { [value getValue:&combo size:sizeof(combo)]; }
    return combo;
}

@interface RCHotKeyService () {
    EventHandlerRef _hotKeyEventHandlerRef;
    EventHotKeyRef _ocrHotKeyRef;
    EventHotKeyRef _mainHotKeyRef;
    EventHotKeyRef _historyHotKeyRef;
    EventHotKeyRef _snippetHotKeyRef;
    EventHotKeyRef _clearHistoryHotKeyRef;
    NSMutableDictionary<NSString *, NSValue *> *_snippetFolderHotKeyRefs;
    NSMutableDictionary<NSString *, NSNumber *> *_snippetFolderHotKeyIdentifiers;
    NSMutableDictionary<NSNumber *, NSString *> *_snippetFolderIdentifiersByHotKeyID;
    // Main-thread-owned bookkeeping for the fixed slots (identifiers 1...5).
    NSMutableDictionary<NSNumber *, NSNumber *> *_slotIdentifierByCarbonID;
    NSMutableDictionary<NSValue *, NSNumber *> *_carbonIDByHotKeyRef;
    NSMutableDictionary<NSNumber *, NSString *> *_registeredComboBySlotIdentifier;
    UInt32 _nextCarbonID;
    // Set while commit stores its result, so a defaults observer cannot re-register.
    BOOL _committingAssignments;
    EventTime _recordingSuppressionEndedAt;
}

- (void)installHotKeyEventHandlerIfNeeded;
- (BOOL)registerHotKeyWithCombo:(RCKeyCombo)combo
                     identifier:(UInt32)identifier
                       storeRef:(EventHotKeyRef *)hotKeyRef;
- (void)unregisterHotKeyRef:(EventHotKeyRef *)hotKeyRef;
- (BOOL)registerSnippetFolderHotKeyWithoutPersisting:(RCKeyCombo)combo
                                  forFolderIdentifier:(NSString *)identifier;
- (void)unregisterSnippetFolderHotKeyWithoutPersisting:(NSString *)identifier;
- (void)unregisterAllSnippetFolderHotKeys;
- (BOOL)nextAvailableSnippetFolderHotKeyIdentifier:(UInt32 *)outIdentifier;
- (NSDictionary<NSString *, NSDictionary *> *)folderHotKeyCombosFromDefaults;
- (void)persistSnippetFolderHotKeyCombo:(RCKeyCombo)combo forFolderIdentifier:(NSString *)identifier;
- (void)removePersistedSnippetFolderHotKeyForIdentifier:(NSString *)identifier;
- (void)postRegistrationFailureNotificationWithIdentifier:(UInt32)identifier
                                                     combo:(RCKeyCombo)combo
                                                    status:(OSStatus)status
                                          folderIdentifier:(nullable NSString *)folderIdentifier;
- (BOOL)isDuplicateHotKeyCombo:(RCKeyCombo)combo
                        context:(NSString *)context
                       registry:(NSDictionary<NSString *, NSString *> *)registry;
- (void)recordHotKeyCombo:(RCKeyCombo)combo
                  context:(NSString *)context
                 registry:(NSMutableDictionary<NSString *, NSString *> *)registry;
- (void)postNotificationForHotKeyIdentifier:(UInt32)identifier;
- (void)postNotificationForCarbonHotKeyID:(UInt32)carbonID eventTime:(EventTime)eventTime;
- (void)performOnMainThreadSync:(dispatch_block_t)block;

@end

@implementation RCHotKeyService

+ (instancetype)shared {
    static RCHotKeyService *sharedService = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedService = [[self alloc] init];
    });
    return sharedService;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _hotKeyEventHandlerRef = NULL;
        _mainHotKeyRef = NULL;
        _historyHotKeyRef = NULL;
        _snippetHotKeyRef = NULL;
        _clearHistoryHotKeyRef = NULL;
        _snippetFolderHotKeyRefs = [[NSMutableDictionary alloc] init];
        _snippetFolderHotKeyIdentifiers = [[NSMutableDictionary alloc] init];
        _snippetFolderIdentifiersByHotKeyID = [[NSMutableDictionary alloc] init];
        _slotIdentifierByCarbonID = [[NSMutableDictionary alloc] init];
        _carbonIDByHotKeyRef = [[NSMutableDictionary alloc] init];
        _registeredComboBySlotIdentifier = [[NSMutableDictionary alloc] init];
        _nextCarbonID = kRCHotKeyIdentifierDynamicBase;
        [self installHotKeyEventHandlerIfNeeded];
    }
    return self;
}

- (void)dealloc {
    [self unregisterAllHotKeys];
    if (_hotKeyEventHandlerRef != NULL) {
        RemoveEventHandler(_hotKeyEventHandlerRef);
        _hotKeyEventHandlerRef = NULL;
    }
}

#pragma mark - Public

- (BOOL)registerMainHotKey:(RCKeyCombo)combo {
    __block BOOL success = NO;
    [self performOnMainThreadSync:^{
        success = [self registerHotKeyWithCombo:combo
                                      identifier:kRCHotKeyIdentifierMain
                                        storeRef:&_mainHotKeyRef];
    }];
    return success;
}

- (BOOL)registerHistoryHotKey:(RCKeyCombo)combo {
    __block BOOL success = NO;
    [self performOnMainThreadSync:^{
        success = [self registerHotKeyWithCombo:combo
                                      identifier:kRCHotKeyIdentifierHistory
                                        storeRef:&_historyHotKeyRef];
    }];
    return success;
}

- (BOOL)registerSnippetHotKey:(RCKeyCombo)combo {
    __block BOOL success = NO;
    [self performOnMainThreadSync:^{
        success = [self registerHotKeyWithCombo:combo
                                      identifier:kRCHotKeyIdentifierSnippet
                                        storeRef:&_snippetHotKeyRef];
    }];
    return success;
}

- (BOOL)registerClearHistoryHotKey:(RCKeyCombo)combo {
    __block BOOL success = NO;
    [self performOnMainThreadSync:^{
        success = [self registerHotKeyWithCombo:combo
                                      identifier:kRCHotKeyIdentifierClearHistory
                                        storeRef:&_clearHistoryHotKeyRef];
    }];
    return success;
}

- (BOOL)registerSnippetFolderHotKey:(RCKeyCombo)combo forFolderIdentifier:(NSString *)identifier {
    if (identifier.length == 0) {
        return NO;
    }

    __block BOOL success = NO;
    [self performOnMainThreadSync:^{
        if (!RCIsValidKeyCombo(combo)) {
            [self unregisterSnippetFolderHotKeyWithoutPersisting:identifier];
            [self persistSnippetFolderHotKeyCombo:combo forFolderIdentifier:identifier];
            success = YES;
            return;
        }

        success = [self registerSnippetFolderHotKeyWithoutPersisting:combo forFolderIdentifier:identifier];
        if (success) {
            [self persistSnippetFolderHotKeyCombo:combo forFolderIdentifier:identifier];
        }
    }];
    return success;
}

- (void)unregisterSnippetFolderHotKey:(NSString *)identifier {
    if (identifier.length == 0) {
        return;
    }

    [self performOnMainThreadSync:^{
        [self unregisterSnippetFolderHotKeyWithoutPersisting:identifier];
        [self removePersistedSnippetFolderHotKeyForIdentifier:identifier];
    }];
}

- (void)reloadFolderHotKeys {
    [self performOnMainThreadSync:^{
        [self unregisterAllSnippetFolderHotKeys];

        NSDictionary<NSString *, NSDictionary *> *storedCombos = [self folderHotKeyCombosFromDefaults];
        if (storedCombos.count == 0) {
            return;
        }

        NSArray<NSDictionary *> *folders = [[RCDatabaseManager shared] fetchAllSnippetFolders];
        for (NSDictionary *folder in folders) {
            NSString *identifier = [folder[@"identifier"] isKindOfClass:[NSString class]]
                                 ? folder[@"identifier"] : @"";
            if (identifier.length == 0) {
                continue;
            }

            id enabledValue = folder[@"enabled"];
            BOOL isEnabled = YES;
            if ([enabledValue respondsToSelector:@selector(boolValue)]) {
                isEnabled = [enabledValue boolValue];
            }
            if (!isEnabled) {
                continue;
            }

            RCKeyCombo combo = RCKeyComboFromDictionaryObject(storedCombos[identifier]);
            if (!RCIsValidKeyCombo(combo)) {
                continue;
            }

            [self registerSnippetFolderHotKeyWithoutPersisting:combo forFolderIdentifier:identifier];
        }
    }];
}

- (void)unregisterAllHotKeys {
    [self performOnMainThreadSync:^{
        [self unregisterHotKeyRef:&_ocrHotKeyRef];
        [self unregisterHotKeyRef:&_mainHotKeyRef];
        [self unregisterHotKeyRef:&_historyHotKeyRef];
        [self unregisterHotKeyRef:&_snippetHotKeyRef];
        [self unregisterHotKeyRef:&_clearHistoryHotKeyRef];
        [self unregisterAllSnippetFolderHotKeys];
    }];
}

- (void)reloadOCRHotKey {
    [self performOnMainThreadSync:^{
        if (_committingAssignments) return;
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        BOOL registers = ![self rc_panicInProgress] && [self rc_slotRegistersHotKey:RCHotKeySlotOCR];
        RCKeyCombo configured = [self configuredKeyComboForSlot:RCHotKeySlotOCR];
        // Already exactly as configured (for example just committed): leave the live
        // registration alone instead of releasing and re-requesting it.
        if (registers && _ocrHotKeyRef != NULL && RCIsValidKeyCombo(configured) &&
            [_registeredComboBySlotIdentifier[@(kRCHotKeyIdentifierOCR)] isEqualToString:RCStringFromKeyCombo(configured)]) return;
        [self unregisterHotKeyRef:&_ocrHotKeyRef];
        if (!registers) return;
        id value = [defaults objectForKey:kRCOCRKeyComboKey];
        if (value == nil) {
            [RCHotKeyService saveKeyCombo:RCDefaultOCRKeyCombo() toUserDefaults:kRCOCRKeyComboKey];
            value = [defaults objectForKey:kRCOCRKeyComboKey];
        }
        if (RCIsExplicitlyUnsetKeyComboObject(value)) return;
        RCKeyCombo combo = RCKeyComboFromDictionaryObject(value);
        if (!RCIsValidKeyCombo(combo)) return;
        // Same registry as every other slot: a combination another Revclip feature is
        // configured to use is reported by name instead of as an anonymous OS failure.
        NSString *conflict = [self rc_slotConfiguredWithKeyCombo:combo excludingSlot:RCHotKeySlotOCR];
        if (conflict != nil) {
            [self rc_postInternalConflictForSlotIdentifier:kRCHotKeyIdentifierOCR combo:combo conflictingSlot:conflict];
            return;
        }
        [self registerHotKeyWithCombo:combo identifier:kRCHotKeyIdentifierOCR storeRef:&_ocrHotKeyRef];
    }];
}

- (void)loadAndRegisterHotKeysFromDefaults {
    [self performOnMainThreadSync:^{
        [self unregisterHotKeyRef:&_ocrHotKeyRef];
        [self unregisterHotKeyRef:&_mainHotKeyRef];
        [self unregisterHotKeyRef:&_historyHotKeyRef];
        [self unregisterHotKeyRef:&_snippetHotKeyRef];
        [self unregisterHotKeyRef:&_clearHistoryHotKeyRef];
        [self unregisterAllSnippetFolderHotKeys];

        NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
        NSMutableDictionary<NSString *, NSString *> *registeredCombos = [NSMutableDictionary dictionary];

        id mainRawValue = [userDefaults objectForKey:kRCHotKeyMainKeyCombo];
        BOOL mainComboExplicitlyUnset = RCIsExplicitlyUnsetKeyComboObject(mainRawValue);
        RCKeyCombo mainCombo = RCKeyComboFromDictionaryObject(mainRawValue);
        if (!mainComboExplicitlyUnset && !RCIsValidKeyCombo(mainCombo)) {
            mainCombo = RCMakeKeyCombo(kRCKeyCodeV, cmdKey | shiftKey);
            [RCHotKeyService saveKeyCombo:mainCombo toUserDefaults:kRCHotKeyMainKeyCombo];
        }
        if (RCIsValidKeyCombo(mainCombo)
            && ![self isDuplicateHotKeyCombo:mainCombo context:@"main hot key" registry:registeredCombos]
            && [self registerMainHotKey:mainCombo]) {
            [self recordHotKeyCombo:mainCombo context:@"main hot key" registry:registeredCombos];
        }

        id historyRawValue = [userDefaults objectForKey:kRCHotKeyHistoryKeyCombo];
        BOOL historyComboExplicitlyUnset = RCIsExplicitlyUnsetKeyComboObject(historyRawValue);
        RCKeyCombo historyCombo = RCKeyComboFromDictionaryObject(historyRawValue);
        if (!historyComboExplicitlyUnset && !RCIsValidKeyCombo(historyCombo)) {
            historyCombo = RCMakeKeyCombo(kRCKeyCodeV, cmdKey | controlKey);
            [RCHotKeyService saveKeyCombo:historyCombo toUserDefaults:kRCHotKeyHistoryKeyCombo];
        }
        if (RCIsValidKeyCombo(historyCombo)
            && ![self isDuplicateHotKeyCombo:historyCombo context:@"history hot key" registry:registeredCombos]
            && [self registerHistoryHotKey:historyCombo]) {
            [self recordHotKeyCombo:historyCombo context:@"history hot key" registry:registeredCombos];
        }

        id snippetRawValue = [userDefaults objectForKey:kRCHotKeySnippetKeyCombo];
        BOOL snippetComboExplicitlyUnset = RCIsExplicitlyUnsetKeyComboObject(snippetRawValue);
        RCKeyCombo snippetCombo = RCKeyComboFromDictionaryObject(snippetRawValue);
        if (!snippetComboExplicitlyUnset && !RCIsValidKeyCombo(snippetCombo)) {
            snippetCombo = RCMakeKeyCombo(kRCKeyCodeB, cmdKey | shiftKey);
            [RCHotKeyService saveKeyCombo:snippetCombo toUserDefaults:kRCHotKeySnippetKeyCombo];
        }
        if (RCIsValidKeyCombo(snippetCombo)
            && ![self isDuplicateHotKeyCombo:snippetCombo context:@"snippet hot key" registry:registeredCombos]
            && [self registerSnippetHotKey:snippetCombo]) {
            [self recordHotKeyCombo:snippetCombo context:@"snippet hot key" registry:registeredCombos];
        }

        RCKeyCombo clearHistoryCombo = RCKeyComboFromDictionaryObject([userDefaults objectForKey:kRCClearHistoryKeyCombo]);
        if (RCIsValidKeyCombo(clearHistoryCombo)) {
            if (![self isDuplicateHotKeyCombo:clearHistoryCombo context:@"clear history hot key" registry:registeredCombos]
                && [self registerClearHistoryHotKey:clearHistoryCombo]) {
                [self recordHotKeyCombo:clearHistoryCombo context:@"clear history hot key" registry:registeredCombos];
            }
        } else {
            [self unregisterHotKeyRef:&_clearHistoryHotKeyRef];
        }

        [self reloadOCRHotKey];
        if (_ocrHotKeyRef != NULL) {
            [self recordHotKeyCombo:[self configuredKeyComboForSlot:RCHotKeySlotOCR] context:@"ocr hot key" registry:registeredCombos];
        }
        [self unregisterAllSnippetFolderHotKeys];
        NSDictionary<NSString *, NSDictionary *> *storedCombos = [self folderHotKeyCombosFromDefaults];
        if (storedCombos.count == 0) {
            return;
        }

        NSArray<NSDictionary *> *folders = [[RCDatabaseManager shared] fetchAllSnippetFolders];
        for (NSDictionary *folder in folders) {
            NSString *identifier = [folder[@"identifier"] isKindOfClass:[NSString class]]
                                 ? folder[@"identifier"] : @"";
            if (identifier.length == 0) {
                continue;
            }

            id enabledValue = folder[@"enabled"];
            BOOL isEnabled = YES;
            if ([enabledValue respondsToSelector:@selector(boolValue)]) {
                isEnabled = [enabledValue boolValue];
            }
            if (!isEnabled) {
                continue;
            }

            RCKeyCombo combo = RCKeyComboFromDictionaryObject(storedCombos[identifier]);
            if (!RCIsValidKeyCombo(combo)) {
                continue;
            }

            NSString *context = [NSString stringWithFormat:@"snippet folder hot key (%@)", identifier];
            if ([self isDuplicateHotKeyCombo:combo context:context registry:registeredCombos]) {
                continue;
            }

            if ([self registerSnippetFolderHotKeyWithoutPersisting:combo forFolderIdentifier:identifier]) {
                [self recordHotKeyCombo:combo context:context registry:registeredCombos];
            }
        }
    }];
}

#pragma mark - Assignment contract

+ (NSArray<NSString *> *)assignableSlots {
    return @[RCHotKeySlotMain, RCHotKeySlotHistory, RCHotKeySlotSnippet, RCHotKeySlotClearHistory, RCHotKeySlotOCR];
}

+ (NSString *)defaultsKeyForSlot:(NSString *)slot {
    switch (RCHotKeySlotIdentifier(slot)) {
        case kRCHotKeyIdentifierMain: return kRCHotKeyMainKeyCombo;
        case kRCHotKeyIdentifierHistory: return kRCHotKeyHistoryKeyCombo;
        case kRCHotKeyIdentifierSnippet: return kRCHotKeySnippetKeyCombo;
        case kRCHotKeyIdentifierClearHistory: return kRCClearHistoryKeyCombo;
        case kRCHotKeyIdentifierOCR: return kRCOCRKeyComboKey;
        default: return nil;
    }
}

+ (RCKeyCombo)defaultKeyComboForSlot:(NSString *)slot {
    switch (RCHotKeySlotIdentifier(slot)) {
        case kRCHotKeyIdentifierMain: return RCMakeKeyCombo(kRCKeyCodeV, cmdKey | shiftKey);
        case kRCHotKeyIdentifierHistory: return RCMakeKeyCombo(kRCKeyCodeV, cmdKey | controlKey);
        case kRCHotKeyIdentifierSnippet: return RCMakeKeyCombo(kRCKeyCodeB, cmdKey | shiftKey);
        case kRCHotKeyIdentifierOCR: return RCDefaultOCRKeyCombo();
        default: return RCInvalidKeyCombo();
    }
}

+ (BOOL)isAssignableKeyCombo:(RCKeyCombo)combo {
    UInt32 allowed = cmdKey | shiftKey | optionKey | controlKey;
    if (!RCIsValidKeyCombo(combo) || combo.keyCode > 0x7F) { return NO; }
    if (combo.modifiers == 0 || (combo.modifiers & ~allowed) != 0) { return NO; }
    if (@available(macOS 15.0, *)) {
        // macOS 15 no longer delivers Option-only hot keys to applications.
        if ((combo.modifiers & optionKey) && !(combo.modifiers & (cmdKey | controlKey))) { return NO; }
    }
    return YES;
}

- (RCKeyCombo)configuredKeyComboForSlot:(NSString *)slot {
    NSString *key = [RCHotKeyService defaultsKeyForSlot:slot];
    if (key.length == 0) { return RCInvalidKeyCombo(); }
    id raw = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    if (RCIsExplicitlyUnsetKeyComboObject(raw)) { return RCInvalidKeyCombo(); }
    RCKeyCombo combo = RCKeyComboFromDictionaryObject(raw);
    return RCIsValidKeyCombo(combo) ? combo : [RCHotKeyService defaultKeyComboForSlot:slot];
}

// Registration follows the configuration except where a feature switch owns it.
- (BOOL)rc_slotRegistersHotKey:(NSString *)slot {
    return [self rc_slotRegistersHotKey:slot ocrEnabled:nil];
}

- (BOOL)rc_slotRegistersHotKey:(NSString *)slot ocrEnabled:(NSNumber *)ocrEnabled {
    if (![slot isEqualToString:RCHotKeySlotOCR]) { return YES; }
    if (ocrEnabled != nil) { return ocrEnabled.boolValue; }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults objectForKey:kRCOCREnabledKey] == nil || [defaults boolForKey:kRCOCREnabledKey];
}

- (EventHotKeyRef *)rc_refPointerForSlot:(NSString *)slot {
    switch (RCHotKeySlotIdentifier(slot)) {
        case kRCHotKeyIdentifierMain: return &_mainHotKeyRef;
        case kRCHotKeyIdentifierHistory: return &_historyHotKeyRef;
        case kRCHotKeyIdentifierSnippet: return &_snippetHotKeyRef;
        case kRCHotKeyIdentifierClearHistory: return &_clearHistoryHotKeyRef;
        case kRCHotKeyIdentifierOCR: return &_ocrHotKeyRef;
        default: return NULL;
    }
}

// Enabled snippet folders with a stored combination. Reads the database only when a
// folder combination exists at all, which is rare: there is no folder recorder UI.
- (NSDictionary<NSString *, NSValue *> *)rc_activeFolderKeyCombos {
    NSDictionary<NSString *, NSDictionary *> *stored = [self folderHotKeyCombosFromDefaults];
    if (stored.count == 0) { return @{}; }
    NSMutableDictionary<NSString *, NSValue *> *combos = [NSMutableDictionary dictionary];
    for (NSDictionary *folder in [[RCDatabaseManager shared] fetchAllSnippetFolders]) {
        NSString *identifier = [folder[@"identifier"] isKindOfClass:NSString.class] ? folder[@"identifier"] : @"";
        id enabled = folder[@"enabled"];
        if (identifier.length == 0 || ([enabled respondsToSelector:@selector(boolValue)] && ![enabled boolValue])) { continue; }
        RCKeyCombo combo = RCKeyComboFromDictionaryObject(stored[identifier]);
        if (RCIsValidKeyCombo(combo)) { combos[identifier] = RCValueFromKeyCombo(combo); }
    }
    return combos;
}

- (BOOL)rc_isEnabledSystemHotKey:(RCKeyCombo)combo {
    UInt32 mask = cmdKey | shiftKey | optionKey | controlKey;
    for (NSDictionary *entry in [self rc_systemSymbolicHotKeys]) {
        if (![entry isKindOfClass:NSDictionary.class]) { continue; }
        id enabled = entry[(__bridge NSString *)kHISymbolicHotKeyEnabled];
        id code = entry[(__bridge NSString *)kHISymbolicHotKeyCode];
        id modifiers = entry[(__bridge NSString *)kHISymbolicHotKeyModifiers];
        if (![enabled respondsToSelector:@selector(boolValue)] || ![enabled boolValue]) { continue; }
        if (![code isKindOfClass:NSNumber.class] || ![modifiers isKindOfClass:NSNumber.class]) { continue; }
        if ([code unsignedIntValue] == combo.keyCode && ([modifiers unsignedIntValue] & mask) == (combo.modifiers & mask)) { return YES; }
    }
    return NO;
}

- (RCHotKeyAssignmentResult *)rc_planAssignments:(NSArray<RCHotKeyAssignment *> *)assignments
                                         targets:(NSMutableDictionary<NSString *, NSValue *> *)targets
                                      ocrEnabled:(NSNumber *)ocrEnabled {
    RCHotKeyAssignmentResult *(^fail)(RCHotKeyAssignmentStatus, NSString *, NSString *) =
    ^(RCHotKeyAssignmentStatus status, NSString *slot, NSString *conflict) {
        return [RCHotKeyAssignmentResult resultWithStatus:status failedSlot:slot conflictingSlot:conflict osStatus:noErr];
    };
    if (assignments.count == 0) { return fail(RCHotKeyAssignmentStatusInvalid, nil, nil); }
    if ([self rc_panicInProgress]) { return fail(RCHotKeyAssignmentStatusUnavailable, assignments.firstObject.slot, nil); }

    // The batch is judged against its own outcome, so two slots may trade places.
    NSMutableDictionary<NSString *, NSValue *> *finals = [NSMutableDictionary dictionary];
    for (NSString *slot in [RCHotKeyService assignableSlots]) {
        finals[slot] = RCValueFromKeyCombo([self configuredKeyComboForSlot:slot]);
    }
    for (RCHotKeyAssignment *assignment in assignments) {
        NSString *slot = assignment.slot;
        if (RCHotKeySlotIdentifier(slot) == 0 || targets[slot] != nil) { return fail(RCHotKeyAssignmentStatusInvalid, slot, nil); }
        RCKeyCombo target = RCInvalidKeyCombo();
        if (assignment.kind == RCHotKeyAssignmentKindSet) {
            if (![RCHotKeyService isAssignableKeyCombo:assignment.combo]) { return fail(RCHotKeyAssignmentStatusInvalid, slot, nil); }
            target = assignment.combo;
        } else if (assignment.kind == RCHotKeyAssignmentKindDefault) {
            target = [RCHotKeyService defaultKeyComboForSlot:slot];
        } else if (assignment.kind == RCHotKeyAssignmentKindKeep) {
            target = [self configuredKeyComboForSlot:slot];
        }
        targets[slot] = RCValueFromKeyCombo(target);
        finals[slot] = targets[slot];
    }

    NSDictionary<NSString *, NSValue *> *folders = nil;
    for (RCHotKeyAssignment *assignment in assignments) {
        NSString *slot = assignment.slot;
        RCKeyCombo target = RCKeyComboFromValue(targets[slot]);
        if (!RCIsValidKeyCombo(target)) { continue; }
        // Switching a feature off, like clearing, must always be possible: it is the way
        // out of a duplicate stored by an older version. Keeping a value is only checked
        // when it is about to be registered; a newly chosen value is always checked.
        if (assignment.kind == RCHotKeyAssignmentKindKeep && ![self rc_slotRegistersHotKey:slot ocrEnabled:ocrEnabled]) { continue; }
        NSString *targetKey = RCStringFromKeyCombo(target);
        for (NSString *other in [RCHotKeyService assignableSlots]) {
            if ([other isEqualToString:slot]) { continue; }
            RCKeyCombo otherCombo = RCKeyComboFromValue(finals[other]);
            if (RCIsValidKeyCombo(otherCombo) && [RCStringFromKeyCombo(otherCombo) isEqualToString:targetKey]) {
                return fail(RCHotKeyAssignmentStatusInternalConflict, slot, other);
            }
        }
        if (folders == nil) { folders = [self rc_activeFolderKeyCombos]; }
        for (NSString *identifier in folders) {
            if ([RCStringFromKeyCombo(RCKeyComboFromValue(folders[identifier])) isEqualToString:targetKey]) {
                return fail(RCHotKeyAssignmentStatusInternalConflict, slot, [RCHotKeySlotFolderPrefix stringByAppendingString:identifier]);
            }
        }
    }

    for (RCHotKeyAssignment *assignment in assignments) {
        if (assignment.kind == RCHotKeyAssignmentKindClear || assignment.kind == RCHotKeyAssignmentKindKeep) { continue; }
        RCKeyCombo target = RCKeyComboFromValue(targets[assignment.slot]);
        if (!RCIsValidKeyCombo(target)) { continue; }
        RCKeyCombo current = [self configuredKeyComboForSlot:assignment.slot];
        BOOL unchanged = RCIsValidKeyCombo(current) && [RCStringFromKeyCombo(current) isEqualToString:RCStringFromKeyCombo(target)];
        // Re-saving the value already in use is never blocked after the fact.
        if (!unchanged && [self rc_isEnabledSystemHotKey:target]) {
            return fail(RCHotKeyAssignmentStatusSystemReserved, assignment.slot, nil);
        }
    }
    return fail(RCHotKeyAssignmentStatusOK, nil, nil);
}

- (RCHotKeyAssignmentResult *)validateAssignments:(NSArray<RCHotKeyAssignment *> *)assignments {
    __block RCHotKeyAssignmentResult *result = nil;
    [self performOnMainThreadSync:^{
        result = [self rc_planAssignments:assignments targets:[NSMutableDictionary dictionary] ocrEnabled:nil];
    }];
    return result;
}

- (RCHotKeyAssignmentResult *)prepareAssignments:(NSArray<RCHotKeyAssignment *> *)assignments
                                     transaction:(id _Nullable * _Nonnull)outTransaction {
    return [self prepareAssignments:assignments ocrEnabledAfterCommit:nil transaction:outTransaction];
}

- (RCHotKeyAssignmentResult *)prepareAssignments:(NSArray<RCHotKeyAssignment *> *)assignments
                           ocrEnabledAfterCommit:(NSNumber *)ocrEnabledAfterCommit
                                     transaction:(id _Nullable * _Nonnull)outTransaction {
    __block RCHotKeyAssignmentResult *result = nil;
    __block RCHotKeyTransaction *transaction = nil;
    [self performOnMainThreadSync:^{
        NSMutableDictionary<NSString *, NSValue *> *targets = [NSMutableDictionary dictionary];
        result = [self rc_planAssignments:assignments targets:targets ocrEnabled:ocrEnabledAfterCommit];
        if (!result.succeeded) { return; }

        NSMutableDictionary<NSString *, NSString *> *holders = [NSMutableDictionary dictionary];
        for (NSString *slot in [RCHotKeyService assignableSlots]) {
            NSString *held = _registeredComboBySlotIdentifier[@(RCHotKeySlotIdentifier(slot))];
            if (held != nil) { holders[held] = slot; }
        }
        RCHotKeyTransaction *plan = [RCHotKeyTransaction new];
        plan.assignments = assignments; plan.targets = targets;
        plan.preparedRefs = [NSMutableDictionary dictionary]; plan.preparedCarbonIDs = [NSMutableDictionary dictionary];
        plan.transfers = [NSMutableDictionary dictionary];
        plan.ocrEnabledAfterCommit = ocrEnabledAfterCommit;
        [self installHotKeyEventHandlerIfNeeded];
        for (RCHotKeyAssignment *assignment in assignments) {
            NSString *slot = assignment.slot;
            RCKeyCombo target = RCKeyComboFromValue(targets[slot]);
            if (!RCIsValidKeyCombo(target) || ![self rc_slotRegistersHotKey:slot ocrEnabled:ocrEnabledAfterCommit]) { continue; }
            NSString *targetKey = RCStringFromKeyCombo(target);
            NSString *holder = holders[targetKey];
            if ([holder isEqualToString:slot]) { continue; }
            // A combination another Revclip slot holds cannot be registered twice by
            // one application, and need not be: its registration changes owner on commit.
            if (holder != nil) { plan.transfers[slot] = holder; continue; }
            UInt32 carbonID = _nextCarbonID++;
            EventHotKeyRef ref = NULL;
            OSStatus status = [self rc_registerEventHotKey:target carbonID:carbonID ref:&ref];
            if (status != noErr || ref == NULL) {
                [self rc_releasePreparedRegistrations:plan];
                result = [RCHotKeyAssignmentResult resultWithStatus:RCHotKeyAssignmentStatusRegistrationFailed
                                                         failedSlot:slot conflictingSlot:nil osStatus:status];
                return;
            }
            plan.preparedRefs[slot] = [NSValue valueWithPointer:ref];
            plan.preparedCarbonIDs[slot] = @(carbonID);
        }
        transaction = plan;
    }];
    *outTransaction = transaction;
    return result;
}

- (void)rc_releasePreparedRegistrations:(RCHotKeyTransaction *)transaction {
    for (NSString *slot in transaction.preparedRefs) {
        EventHotKeyRef ref = (EventHotKeyRef)[transaction.preparedRefs[slot] pointerValue];
        if (ref != NULL) { [self rc_unregisterEventHotKey:ref]; }
    }
    [transaction.preparedRefs removeAllObjects];
    [transaction.preparedCarbonIDs removeAllObjects];
}

- (void)discardPreparedAssignments:(id)object {
    [self performOnMainThreadSync:^{
        RCHotKeyTransaction *transaction = [object isKindOfClass:RCHotKeyTransaction.class] ? object : nil;
        if (transaction == nil || transaction.finished) { return; }
        transaction.finished = YES;
        [self rc_releasePreparedRegistrations:transaction];
    }];
}

// No OS registration happens here, so nothing in it can fail half way.
- (void)commitPreparedAssignments:(id)object {
    [self performOnMainThreadSync:^{
        RCHotKeyTransaction *transaction = [object isKindOfClass:RCHotKeyTransaction.class] ? object : nil;
        if (transaction == nil || transaction.finished) { return; }
        transaction.finished = YES;

        NSMutableDictionary<NSString *, NSValue *> *oldRefs = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSString *> *oldKeys = [NSMutableDictionary dictionary];
        for (RCHotKeyAssignment *assignment in transaction.assignments) {
            NSString *slot = assignment.slot;
            EventHotKeyRef *pointer = [self rc_refPointerForSlot:slot];
            NSNumber *slotIdentifier = @(RCHotKeySlotIdentifier(slot));
            if (pointer != NULL && *pointer != NULL) { oldRefs[slot] = [NSValue valueWithPointer:*pointer]; *pointer = NULL; }
            if (_registeredComboBySlotIdentifier[slotIdentifier] != nil) { oldKeys[slot] = _registeredComboBySlotIdentifier[slotIdentifier]; }
            [_registeredComboBySlotIdentifier removeObjectForKey:slotIdentifier];
        }
        NSMutableSet<NSString *> *reused = [NSMutableSet set];
        for (RCHotKeyAssignment *assignment in transaction.assignments) {
            NSString *slot = assignment.slot;
            EventHotKeyRef *pointer = [self rc_refPointerForSlot:slot];
            RCKeyCombo target = RCKeyComboFromValue(transaction.targets[slot]);
            if (pointer == NULL || !RCIsValidKeyCombo(target) ||
                ![self rc_slotRegistersHotKey:slot ocrEnabled:transaction.ocrEnabledAfterCommit]) { continue; }
            NSString *donor = transaction.transfers[slot];
            NSString *source = donor ?: ([oldKeys[slot] isEqualToString:RCStringFromKeyCombo(target)] ? slot : nil);
            if (source != nil && oldRefs[source] != nil) {
                EventHotKeyRef ref = (EventHotKeyRef)[oldRefs[source] pointerValue];
                NSNumber *carbonID = _carbonIDByHotKeyRef[[NSValue valueWithPointer:ref]];
                if (carbonID != nil) { _slotIdentifierByCarbonID[carbonID] = @(RCHotKeySlotIdentifier(slot)); }
                _registeredComboBySlotIdentifier[@(RCHotKeySlotIdentifier(slot))] = RCStringFromKeyCombo(target);
                *pointer = ref;
                [reused addObject:source];
            } else if (transaction.preparedRefs[slot] != nil) {
                EventHotKeyRef ref = (EventHotKeyRef)[transaction.preparedRefs[slot] pointerValue];
                *pointer = ref;
                [self rc_recordRegistration:ref carbonID:[transaction.preparedCarbonIDs[slot] unsignedIntValue]
                             slotIdentifier:RCHotKeySlotIdentifier(slot) combo:target];
            }
        }
        for (NSString *slot in oldRefs) {
            if ([reused containsObject:slot]) { continue; }
            EventHotKeyRef ref = (EventHotKeyRef)[oldRefs[slot] pointerValue];
            OSStatus status = [self rc_unregisterEventHotKey:ref];
            if (status != noErr) { NSLog(@"[RCHotKeyService] Failed to unregister hot key (status: %d).", (int)status); }
            // rc_forgetRegistration would also drop the slot's new combination record.
            NSValue *key = [NSValue valueWithPointer:ref];
            NSNumber *carbonID = _carbonIDByHotKeyRef[key];
            if (carbonID != nil) { [_slotIdentifierByCarbonID removeObjectForKey:carbonID]; }
            [_carbonIDByHotKeyRef removeObjectForKey:key];
        }

        // Registrations are final before anything is stored: an observer of these
        // writes sees the finished state and must not rebuild it.
        _committingAssignments = YES;
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        for (RCHotKeyAssignment *assignment in transaction.assignments) {
            if (assignment.kind == RCHotKeyAssignmentKindKeep) { continue; }
            NSString *key = [RCHotKeyService defaultsKeyForSlot:assignment.slot];
            RCKeyCombo target = RCKeyComboFromValue(transaction.targets[assignment.slot]);
            if (RCIsValidKeyCombo(target)) { [RCHotKeyService saveKeyCombo:target toUserDefaults:key]; }
            else if (assignment.kind == RCHotKeyAssignmentKindClear) { [defaults setObject:@{@"keyCode": @0, @"modifiers": @0} forKey:key]; }
            else { [defaults removeObjectForKey:key]; }
        }
        _committingAssignments = NO;
    }];
}

- (RCHotKeyAssignmentResult *)applyAssignments:(NSArray<RCHotKeyAssignment *> *)assignments {
    id transaction = nil;
    RCHotKeyAssignmentResult *result = [self prepareAssignments:assignments transaction:&transaction];
    if (result.succeeded) { [self commitPreparedAssignments:transaction]; }
    return result;
}

+ (RCKeyCombo)keyComboFromUserDefaults:(NSString *)key {
    if (key.length == 0) {
        return RCInvalidKeyCombo();
    }

    id rawValue = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return RCKeyComboFromDictionaryObject(rawValue);
}

+ (void)saveKeyCombo:(RCKeyCombo)combo toUserDefaults:(NSString *)key {
    if (key.length == 0) {
        return;
    }

    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    if (!RCIsValidKeyCombo(combo)) {
        [userDefaults removeObjectForKey:key];
        return;
    }

    NSDictionary *dictionary = @{
        @"keyCode": @(combo.keyCode),
        @"modifiers": @(combo.modifiers),
    };
    [userDefaults setObject:dictionary forKey:key];
}

+ (UInt32)carbonModifiersFromCocoaModifiers:(NSEventModifierFlags)cocoaModifiers {
    UInt32 carbonModifiers = 0;

    if ((cocoaModifiers & NSEventModifierFlagCommand) != 0) {
        carbonModifiers |= cmdKey;
    }
    if ((cocoaModifiers & NSEventModifierFlagShift) != 0) {
        carbonModifiers |= shiftKey;
    }
    if ((cocoaModifiers & NSEventModifierFlagOption) != 0) {
        carbonModifiers |= optionKey;
    }
    if ((cocoaModifiers & NSEventModifierFlagControl) != 0) {
        carbonModifiers |= controlKey;
    }

    return carbonModifiers;
}

+ (NSEventModifierFlags)cocoaModifiersFromCarbonModifiers:(UInt32)carbonModifiers {
    NSEventModifierFlags cocoaModifiers = 0;

    if ((carbonModifiers & cmdKey) != 0) {
        cocoaModifiers |= NSEventModifierFlagCommand;
    }
    if ((carbonModifiers & shiftKey) != 0) {
        cocoaModifiers |= NSEventModifierFlagShift;
    }
    if ((carbonModifiers & optionKey) != 0) {
        cocoaModifiers |= NSEventModifierFlagOption;
    }
    if ((carbonModifiers & controlKey) != 0) {
        cocoaModifiers |= NSEventModifierFlagControl;
    }

    return cocoaModifiers;
}

#pragma mark - Private

- (void)installHotKeyEventHandlerIfNeeded {
    if (_hotKeyEventHandlerRef != NULL) {
        return;
    }

    EventTypeSpec eventType;
    eventType.eventClass = kEventClassKeyboard;
    eventType.eventKind = kEventHotKeyPressed;

    OSStatus status = InstallEventHandler(GetApplicationEventTarget(),
                                          RCHotKeyEventHandler,
                                          1,
                                          &eventType,
                                          (__bridge void *)self,
                                          &_hotKeyEventHandlerRef);
    if (status != noErr) {
        NSLog(@"[RCHotKeyService] Failed to install hot key event handler (status: %d).", (int)status);
    }
}

- (BOOL)registerHotKeyWithCombo:(RCKeyCombo)combo
                     identifier:(UInt32)identifier
                       storeRef:(EventHotKeyRef *)hotKeyRef {
    if (hotKeyRef == NULL) {
        return NO;
    }

    [self installHotKeyEventHandlerIfNeeded];
    [self unregisterHotKeyRef:hotKeyRef];

    if (!RCIsValidKeyCombo(combo)) {
        return YES;
    }

    UInt32 carbonID = _nextCarbonID++;
    EventHotKeyRef registeredRef = NULL;
    OSStatus status = [self rc_registerEventHotKey:combo carbonID:carbonID ref:&registeredRef];
    if (status != noErr) {
        NSLog(@"[RCHotKeyService] Failed to register hot key (id: %u, status: %d).",
              (unsigned int)identifier,
              (int)status);
        [self postRegistrationFailureNotificationWithIdentifier:identifier
                                                          combo:combo
                                                         status:status
                                               folderIdentifier:nil];
        return NO;
    }

    *hotKeyRef = registeredRef;
    [self rc_recordRegistration:registeredRef carbonID:carbonID slotIdentifier:identifier combo:combo];
    return YES;
}

// Fixed slots take precedence over snippet folders, at start-up and everywhere else.
- (nullable NSString *)rc_slotConfiguredWithKeyCombo:(RCKeyCombo)combo excludingSlot:(nullable NSString *)excluded {
    NSString *key = RCStringFromKeyCombo(combo);
    for (NSString *slot in [RCHotKeyService assignableSlots]) {
        if ([slot isEqualToString:excluded]) { continue; }
        RCKeyCombo other = [self configuredKeyComboForSlot:slot];
        if (RCIsValidKeyCombo(other) && [RCStringFromKeyCombo(other) isEqualToString:key]) { return slot; }
    }
    return nil;
}

- (void)rc_postInternalConflictForSlotIdentifier:(UInt32)identifier combo:(RCKeyCombo)combo conflictingSlot:(NSString *)conflictingSlot {
    NSLog(@"[RCHotKeyService] Hot key (id: %u) not registered: already used by %@.", (unsigned int)identifier, conflictingSlot);
    NSDictionary *userInfo = @{
        RCHotKeyRegistrationFailureIdentifierUserInfoKey: @(identifier),
        RCHotKeyRegistrationFailureKeyCodeUserInfoKey: @(combo.keyCode),
        RCHotKeyRegistrationFailureModifiersUserInfoKey: @(combo.modifiers),
        RCHotKeyRegistrationFailureStatusUserInfoKey: @(eventHotKeyExistsErr),
        RCHotKeyRegistrationFailureConflictingSlotUserInfoKey: conflictingSlot,
    };
    dispatch_block_t post = ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:RCHotKeyRegistrationDidFailNotification object:self userInfo:userInfo];
    };
    if ([NSThread isMainThread]) { post(); } else { dispatch_async(dispatch_get_main_queue(), post); }
}

#pragma mark - OS seams

// The only RegisterEventHotKey call. inOptions stays 0: hot keys are non-exclusive,
// so Revclip never takes another application's shortcut away.
- (OSStatus)rc_registerEventHotKey:(RCKeyCombo)combo carbonID:(UInt32)carbonID ref:(EventHotKeyRef *)outRef {
    EventHotKeyID hotKeyID;
    hotKeyID.signature = kRCHotKeySignature;
    hotKeyID.id = carbonID;
    return RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID, GetApplicationEventTarget(), 0, outRef);
}

- (OSStatus)rc_unregisterEventHotKey:(EventHotKeyRef)ref {
    return UnregisterEventHotKey(ref);
}

// Enabled system-wide shortcuts from Keyboard settings. Queried only while a shortcut
// is being assigned; the API reports key code, modifiers and state, never a name.
- (NSArray<NSDictionary *> *)rc_systemSymbolicHotKeys {
    CFArrayRef hotKeys = NULL;
    if (CopySymbolicHotKeys(&hotKeys) != noErr || hotKeys == NULL) { return @[]; }
    return CFBridgingRelease(hotKeys);
}

- (BOOL)rc_panicInProgress { return [RCPanicEraseService shared].isPanicInProgress; }

- (void)rc_recordRegistration:(EventHotKeyRef)ref carbonID:(UInt32)carbonID slotIdentifier:(UInt32)slotIdentifier combo:(RCKeyCombo)combo {
    if (ref == NULL) { return; }
    _carbonIDByHotKeyRef[[NSValue valueWithPointer:ref]] = @(carbonID);
    _slotIdentifierByCarbonID[@(carbonID)] = @(slotIdentifier);
    _registeredComboBySlotIdentifier[@(slotIdentifier)] = RCStringFromKeyCombo(combo);
}

- (void)rc_forgetRegistration:(EventHotKeyRef)ref {
    if (ref == NULL) { return; }
    NSValue *key = [NSValue valueWithPointer:ref];
    NSNumber *carbonID = _carbonIDByHotKeyRef[key];
    if (carbonID == nil) { return; }
    NSNumber *slotIdentifier = _slotIdentifierByCarbonID[carbonID];
    if (slotIdentifier != nil) { [_registeredComboBySlotIdentifier removeObjectForKey:slotIdentifier]; }
    [_slotIdentifierByCarbonID removeObjectForKey:carbonID];
    [_carbonIDByHotKeyRef removeObjectForKey:key];
}

- (void)unregisterHotKeyRef:(EventHotKeyRef *)hotKeyRef {
    if (hotKeyRef == NULL || *hotKeyRef == NULL) {
        return;
    }

    OSStatus status = [self rc_unregisterEventHotKey:*hotKeyRef];
    if (status != noErr) {
        NSLog(@"[RCHotKeyService] Failed to unregister hot key (status: %d).", (int)status);
    }
    [self rc_forgetRegistration:*hotKeyRef];
    *hotKeyRef = NULL;
}

- (BOOL)registerSnippetFolderHotKeyWithoutPersisting:(RCKeyCombo)combo
                                  forFolderIdentifier:(NSString *)identifier {
    if (identifier.length == 0) {
        return NO;
    }

    [self installHotKeyEventHandlerIfNeeded];
    [self unregisterSnippetFolderHotKeyWithoutPersisting:identifier];

    if (!RCIsValidKeyCombo(combo)) {
        return YES;
    }

    // Covers start-up, reloadFolderHotKeys and the public folder entry alike.
    NSString *conflict = [self rc_slotConfiguredWithKeyCombo:combo excludingSlot:nil];
    if (conflict != nil) {
        NSLog(@"[RCHotKeyService] Snippet folder hot key for '%@' not registered: already used by %@.", identifier, conflict);
        return NO;
    }

    UInt32 hotKeyIdentifier = 0;
    if (![self nextAvailableSnippetFolderHotKeyIdentifier:&hotKeyIdentifier]) {
        NSLog(@"[RCHotKeyService] Cannot register snippet folder hot key for '%@': no available identifier.", identifier);
        return NO;
    }

    EventHotKeyRef registeredRef = NULL;
    OSStatus status = [self rc_registerEventHotKey:combo carbonID:hotKeyIdentifier ref:&registeredRef];
    if (status != noErr) {
        NSLog(@"[RCHotKeyService] Failed to register snippet folder hot key (folder: %@, id: %u, status: %d).",
              identifier,
              (unsigned int)hotKeyIdentifier,
              (int)status);
        [self postRegistrationFailureNotificationWithIdentifier:hotKeyIdentifier
                                                          combo:combo
                                                         status:status
                                               folderIdentifier:identifier];
        return NO;
    }

    NSNumber *hotKeyNumber = @(hotKeyIdentifier);
    _snippetFolderHotKeyRefs[identifier] = [NSValue valueWithPointer:registeredRef];
    _snippetFolderHotKeyIdentifiers[identifier] = hotKeyNumber;
    _snippetFolderIdentifiersByHotKeyID[hotKeyNumber] = identifier;
    return YES;
}

- (void)unregisterSnippetFolderHotKeyWithoutPersisting:(NSString *)identifier {
    if (identifier.length == 0) {
        return;
    }

    NSValue *hotKeyRefValue = _snippetFolderHotKeyRefs[identifier];
    EventHotKeyRef hotKeyRef = (EventHotKeyRef)[hotKeyRefValue pointerValue];
    if (hotKeyRef != NULL) {
        OSStatus status = [self rc_unregisterEventHotKey:hotKeyRef];
        if (status != noErr) {
            NSLog(@"[RCHotKeyService] Failed to unregister snippet folder hot key (folder: %@, status: %d).",
                  identifier,
                  (int)status);
        }
    }

    NSNumber *hotKeyNumber = _snippetFolderHotKeyIdentifiers[identifier];
    if (hotKeyNumber != nil) {
        [_snippetFolderIdentifiersByHotKeyID removeObjectForKey:hotKeyNumber];
    }
    [_snippetFolderHotKeyIdentifiers removeObjectForKey:identifier];
    [_snippetFolderHotKeyRefs removeObjectForKey:identifier];
}

- (void)unregisterAllSnippetFolderHotKeys {
    NSArray<NSString *> *folderIdentifiers = [_snippetFolderHotKeyRefs.allKeys copy];
    for (NSString *identifier in folderIdentifiers) {
        [self unregisterSnippetFolderHotKeyWithoutPersisting:identifier];
    }
}

- (BOOL)nextAvailableSnippetFolderHotKeyIdentifier:(UInt32 *)outIdentifier {
    if (outIdentifier == NULL) {
        return NO;
    }

    UInt32 candidate = kRCHotKeyIdentifierSnippetFolderBase;
    while (_snippetFolderIdentifiersByHotKeyID[@(candidate)] != nil) {
        if (candidate == UINT32_MAX) {
            NSLog(@"[RCHotKeyService] Snippet folder hot key identifier space exhausted.");
            return NO;
        }
        candidate++;
    }

    *outIdentifier = candidate;
    return YES;
}

- (NSDictionary<NSString *, NSDictionary *> *)folderHotKeyCombosFromDefaults {
    id rawValue = [[NSUserDefaults standardUserDefaults] objectForKey:kRCFolderKeyCombos];
    if (![rawValue isKindOfClass:[NSDictionary class]]) {
        return @{};
    }

    NSDictionary *dictionary = (NSDictionary *)rawValue;
    NSMutableDictionary<NSString *, NSDictionary *> *validated = [NSMutableDictionary dictionary];
    for (id key in dictionary) {
        if (![key isKindOfClass:[NSString class]]) {
            continue;
        }
        id comboDictionary = dictionary[key];
        if (![comboDictionary isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        validated[(NSString *)key] = (NSDictionary *)comboDictionary;
    }
    return [validated copy];
}

- (void)persistSnippetFolderHotKeyCombo:(RCKeyCombo)combo forFolderIdentifier:(NSString *)identifier {
    if (identifier.length == 0) {
        return;
    }

    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary<NSString *, NSDictionary *> *mutableCombos = [[self folderHotKeyCombosFromDefaults] mutableCopy];
    if (mutableCombos == nil) {
        mutableCombos = [NSMutableDictionary dictionary];
    }

    if (RCIsValidKeyCombo(combo)) {
        mutableCombos[identifier] = @{
            @"keyCode": @(combo.keyCode),
            @"modifiers": @(combo.modifiers),
        };
    } else {
        [mutableCombos removeObjectForKey:identifier];
    }

    if (mutableCombos.count == 0) {
        [userDefaults removeObjectForKey:kRCFolderKeyCombos];
        return;
    }

    [userDefaults setObject:[mutableCombos copy] forKey:kRCFolderKeyCombos];
}

- (void)removePersistedSnippetFolderHotKeyForIdentifier:(NSString *)identifier {
    if (identifier.length == 0) {
        return;
    }

    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary<NSString *, NSDictionary *> *mutableCombos = [[self folderHotKeyCombosFromDefaults] mutableCopy];
    [mutableCombos removeObjectForKey:identifier];

    if (mutableCombos.count == 0) {
        [userDefaults removeObjectForKey:kRCFolderKeyCombos];
        return;
    }

    [userDefaults setObject:[mutableCombos copy] forKey:kRCFolderKeyCombos];
}

- (void)postRegistrationFailureNotificationWithIdentifier:(UInt32)identifier
                                                     combo:(RCKeyCombo)combo
                                                    status:(OSStatus)status
                                          folderIdentifier:(nullable NSString *)folderIdentifier {
    NSMutableDictionary<NSString *, id> *userInfo = [NSMutableDictionary dictionary];
    userInfo[RCHotKeyRegistrationFailureIdentifierUserInfoKey] = @(identifier);
    userInfo[RCHotKeyRegistrationFailureKeyCodeUserInfoKey] = @(combo.keyCode);
    userInfo[RCHotKeyRegistrationFailureModifiersUserInfoKey] = @(combo.modifiers);
    userInfo[RCHotKeyRegistrationFailureStatusUserInfoKey] = @(status);
    if (folderIdentifier.length > 0) {
        userInfo[RCHotKeyRegistrationFailureFolderIdentifierUserInfoKey] = folderIdentifier;
    }

    dispatch_block_t postBlock = ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:RCHotKeyRegistrationDidFailNotification
                                                            object:self
                                                          userInfo:[userInfo copy]];
    };

    if ([NSThread isMainThread]) {
        postBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), postBlock);
    }
}

- (BOOL)isDuplicateHotKeyCombo:(RCKeyCombo)combo
                        context:(NSString *)context
                       registry:(NSDictionary<NSString *, NSString *> *)registry {
    if (!RCIsValidKeyCombo(combo) || registry.count == 0) {
        return NO;
    }

    NSString *comboKey = RCStringFromKeyCombo(combo);
    NSString *existingContext = registry[comboKey];
    if (existingContext.length == 0) {
        return NO;
    }

    NSLog(@"[RCHotKeyService] Duplicate hot key combo skipped for %@. Already used by %@.",
          context.length > 0 ? context : @"unknown context",
          existingContext);
    return YES;
}

- (void)recordHotKeyCombo:(RCKeyCombo)combo
                  context:(NSString *)context
                 registry:(NSMutableDictionary<NSString *, NSString *> *)registry {
    if (!RCIsValidKeyCombo(combo) || registry == nil) {
        return;
    }
    registry[RCStringFromKeyCombo(combo)] = context.length > 0 ? context : @"unknown context";
}

// The OS reports the identifier of one registration; the slot that owns it now decides
// what happens. Folder registrations keep their own identifiers and map.
- (void)postNotificationForCarbonHotKeyID:(UInt32)carbonID eventTime:(EventTime)eventTime {
    __block NSNumber *slotIdentifier = nil;
    [self performOnMainThreadSync:^{ slotIdentifier = _slotIdentifierByCarbonID[@(carbonID)]; }];
    [self postNotificationForHotKeyIdentifier:slotIdentifier != nil ? slotIdentifier.unsignedIntValue : carbonID
                                    eventTime:eventTime];
}

- (void)postNotificationForHotKeyIdentifier:(UInt32)identifier {
    [self postNotificationForHotKeyIdentifier:identifier eventTime:0];
}

- (void)setShortcutRecordingOwner:(id)owner {
    if (_shortcutRecordingOwner != nil && owner == nil) _recordingSuppressionEndedAt = GetCurrentEventTime();
    _shortcutRecordingOwner = owner;
}
- (void)postNotificationForHotKeyIdentifier:(UInt32)identifier eventTime:(EventTime)eventTime {
    NSString *notificationName = nil;
    NSDictionary *userInfo = nil;

    switch (identifier) {
        case kRCHotKeyIdentifierOCR:
            notificationName = RCHotKeyOCRTriggeredNotification;
            // Lets the receiver recognise one physical key press that also reached it as a
            // menu key equivalent. Absent when the OS supplied no time.
            if (eventTime > 0) { userInfo = @{ RCHotKeyEventTimestampUserInfoKey: @(eventTime) }; }
            break;
        case kRCHotKeyIdentifierMain:
            notificationName = RCHotKeyMainTriggeredNotification;
            break;
        case kRCHotKeyIdentifierHistory:
            notificationName = RCHotKeyHistoryTriggeredNotification;
            break;
        case kRCHotKeyIdentifierSnippet:
            notificationName = RCHotKeySnippetTriggeredNotification;
            break;
        case kRCHotKeyIdentifierClearHistory:
            notificationName = RCHotKeyClearHistoryTriggeredNotification;
            break;
        default:
        {
            __block NSString *folderIdentifier = nil;
            [self performOnMainThreadSync:^{
                folderIdentifier = _snippetFolderIdentifiersByHotKeyID[@(identifier)];
            }];
            if (folderIdentifier.length > 0) {
                notificationName = RCHotKeySnippetFolderTriggeredNotification;
                userInfo = @{ RCHotKeyFolderIdentifierUserInfoKey: folderIdentifier };
            }
            break;
        }
    }

    if (notificationName.length == 0) {
        return;
    }

    dispatch_block_t postBlock = ^{
        if (self.shortcutRecordingOwner != nil || (eventTime > 0 && eventTime <= _recordingSuppressionEndedAt)) return;
        [[NSNotificationCenter defaultCenter] postNotificationName:notificationName
                                                            object:self
                                                          userInfo:userInfo];
    };

    if ([NSThread isMainThread]) {
        postBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), postBlock);
    }
}

- (void)performOnMainThreadSync:(dispatch_block_t)block {
    if (block == nil) {
        return;
    }

    if ([NSThread isMainThread]) {
        block();
        return;
    }

    dispatch_sync(dispatch_get_main_queue(), block);
}

@end

static OSStatus RCHotKeyEventHandler(EventHandlerCallRef nextHandler, EventRef event, void *userData) {
    (void)nextHandler;

    if (event == NULL || userData == NULL) {
        return eventNotHandledErr;
    }

    EventHotKeyID hotKeyID;
    OSStatus status = GetEventParameter(event,
                                        kEventParamDirectObject,
                                        typeEventHotKeyID,
                                        NULL,
                                        sizeof(EventHotKeyID),
                                        NULL,
                                        &hotKeyID);
    if (status != noErr) {
        return status;
    }

    if (hotKeyID.signature != kRCHotKeySignature) {
        return eventNotHandledErr;
    }

    RCHotKeyService *service = (__bridge RCHotKeyService *)userData;
    [service postNotificationForCarbonHotKeyID:hotKeyID.id eventTime:GetEventTime(event)];
    return noErr;
}
