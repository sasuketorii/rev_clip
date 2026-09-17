//
//  RCClipboardService.h
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Current project: AGPL-3.0-only; legacy portions: MIT. See THIRD_PARTY_NOTICES.md.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, RCOCRCommitResult) {
    RCOCRCommitResultHistoryStored,
    RCOCRCommitResultHistorySkipped,
    RCOCRCommitResultHistoryFailed,
    RCOCRCommitResultClipboardChanged,
    RCOCRCommitResultClipboardWriteFailed,
    RCOCRCommitResultCancelled,
};

// Why no ticket was issued. Each reason has its own wording; an unknown source is
// still refused, because its exclusion setting cannot be evaluated.
typedef NS_ENUM(NSInteger, RCOCRRefusal) {
    RCOCRRefusalNone = 0,
    RCOCRRefusalUnknownSource,
    RCOCRRefusalExcludedSource,
    RCOCRRefusalStopped,
};

// One-shot, in-memory admission ticket; no pasteboard payload is read.
@interface RCOCRCommitContext : NSObject
@property(nonatomic, readonly) NSUInteger monitoringGeneration;
@end

@interface RCClipboardService : NSObject

+ (instancetype)shared;

// 監視の開始・停止
- (void)startMonitoring;
- (void)stopMonitoring;
@property (atomic, readonly) BOOL isMonitoring;
// Advances on every start and stop. A caller that recorded it before deferred
// work can detect stop, or stop+restart, that happened in between.
@property (atomic, readonly) NSUInteger monitoringGeneration;

- (nullable RCOCRCommitContext *)beginOCRFromApplication:(NSString *)bundleIdentifier
                                         saveToHistory:(BOOL)saveToHistory;
- (nullable RCOCRCommitContext *)beginOCRFromApplication:(NSString *)bundleIdentifier
                                         saveToHistory:(BOOL)saveToHistory
                                               refusal:(nullable RCOCRRefusal *)refusal;
- (void)cancelOCRContext:(RCOCRCommitContext *)context;
- (void)disableHistoryForOCRContext:(RCOCRCommitContext *)context;
// Main only. Copy and admission are synchronous; completion is always on main,
// after accepted persistence. The caller must invalidate its own UI generation.
- (void)commitRecognizedText:(NSString *)text context:(RCOCRCommitContext *)context
                 completion:(void (^)(RCOCRCommitResult result))completion;

// Call on main immediately after a synchronous internal pasteboard write.
// Only that generation is excluded; subsequent external copies remain eligible.
- (void)recordInternalPasteboardChangeCount:(NSInteger)changeCount;

// Main-thread history-selection context after a successful restore. Updates an
// existing row only when reorder-after-pasting is enabled; shares capture's
// acquisition/persistence ordering. Stop rejects new admissions; accepted use
// survives stop and completes before clear/quit drain. Never captures payload.
- (void)recordHistoryUseWithDataHash:(NSString *)dataHash;

// 手動での最新クリップ取得
- (void)captureCurrentClipboard;

// Drain earlier acquisition AND persistence work (used by clear/termination).
- (void)flushQueueWithCompletion:(void(^)(void))completion;

// Menu-open preflight. Observes the current pasteboard generation through the
// same serial acquisition path as the timer (no forced re-read: an unchanged or
// internal generation is neither re-captured nor re-ordered), then completes
// after every earlier acquisition and persistence has finished. The completion
// runs on a background queue and always fires, including while monitoring is
// stopped or capture is denied. Never blocks the caller.
- (void)observePendingClipboardChangeWithCompletion:(void(^)(void))completion;

@end

// 通知名
extern NSString * const RCClipboardDidChangeNotification;
extern NSString * const RCClipboardLifecycleDidStopNotification;

NS_ASSUME_NONNULL_END
