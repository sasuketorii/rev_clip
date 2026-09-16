//
//  RCPasteService.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Current project: AGPL-3.0-only; legacy portions: MIT. See THIRD_PARTY_NOTICES.md.
//

#import "RCPasteService.h"
#import <ApplicationServices/ApplicationServices.h>
#import "RCAccessibilityService.h"
#import "RCClipboardService.h"
#import "RCClipData.h"
#import "RCConstants.h"

static NSTimeInterval const kRCPasteMenuCloseDelay = 0.05;
static NSTimeInterval const kRCPasteActivationPollInterval = 0.01;
static NSTimeInterval const kRCPasteActivationTimeout = 0.5;

@interface RCPasteService ()
@property NSUInteger pasteGeneration;
@property NSTimeInterval requestDeadline;
@property NSInteger expectedPasteboardChangeCount;
@property pid_t initialFrontPID;
@property(strong) NSPasteboard *pendingPasteboard;
@property(strong) NSRunningApplication *pendingTarget;
@property(strong) id expectedFocusedElement;
- (BOOL)isPressedModifier:(NSInteger)flag;
- (BOOL)boolPreferenceForKey:(NSString *)key defaultValue:(BOOL)defaultValue;
- (NSInteger)integerPreferenceForKey:(NSString *)key defaultValue:(NSInteger)defaultValue;
@end

@implementation RCPasteService
+ (instancetype)shared {
    static RCPasteService *sharedService = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedService = [[self alloc] init];
    });
    return sharedService;
}

- (NSPasteboard *)pasteboard { return NSPasteboard.generalPasteboard; }
- (RCClipboardService *)clipboardService { return RCClipboardService.shared; }
- (NSRunningApplication *)frontmostApplication { return NSWorkspace.sharedWorkspace.frontmostApplication; }
- (NSTimeInterval)pasteClock { return NSProcessInfo.processInfo.systemUptime; }
- (void)scheduleAfterDelay:(NSTimeInterval)delay block:(dispatch_block_t)block {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}
- (BOOL)activateApplication:(NSRunningApplication *)application { return [application activateWithOptions:0]; }
- (id)focusedElementForApplication:(NSRunningApplication *)application {
    if (!application || application.terminated || application.processIdentifier <= 0) return nil;
    AXUIElementRef app = AXUIElementCreateApplication(application.processIdentifier);
    if (!app) return nil;
    AXUIElementSetMessagingTimeout(app, 0.05f);
    CFTypeRef focused = NULL;
    AXError error = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute, &focused);
    CFRelease(app);
    if (error != kAXErrorSuccess || !focused) { if (focused) CFRelease(focused); return nil; }
    return CFBridgingRelease(focused);
}
- (BOOL)isUsableTarget:(NSRunningApplication *)target {
    return target && !target.terminated && target.processIdentifier > 0 &&
        target.processIdentifier != NSProcessInfo.processInfo.processIdentifier &&
        ![target.bundleIdentifier isEqualToString:NSBundle.mainBundle.bundleIdentifier];
}
- (NSRunningApplication *)pasteTargetResolvingApplication:(NSRunningApplication *)application {
    NSRunningApplication *target = application ?: [self frontmostApplication];
    return [self isUsableTarget:target] ? target : nil;
}
- (void)finishGeneration:(NSUInteger)generation {
    if (generation != self.pasteGeneration) return;
    ++self.pasteGeneration;
    self.pendingPasteboard = nil;
    self.pendingTarget = nil;
    self.expectedFocusedElement = nil;
}

// One main-thread write and one resulting count; there is no time-window skip.
// A failed write may still clear the board, so register its changed count too.
- (void)performWrite:(BOOL (^ _Nullable)(NSPasteboard *))writer toApplication:(NSRunningApplication *)application {
    [self performWrite:writer toApplication:application historyDataHash:nil];
}
- (void)performWrite:(BOOL (^ _Nullable)(NSPasteboard *))writer
       toApplication:(NSRunningApplication *)application historyDataHash:(NSString *)historyDataHash {
    // One deadline covers preparation, the menu-close delay and activation.
    // Synchronous OS calls cannot be interrupted; recheck when they return.
    NSTimeInterval deadline = [self pasteClock] + kRCPasteMenuCloseDelay + kRCPasteActivationTimeout;
    NSUInteger generation = ++self.pasteGeneration;
    self.requestDeadline = deadline;
    self.pendingTarget = nil; self.pendingPasteboard = nil; self.expectedFocusedElement = nil;
    BOOL send = !writer || [self boolPreferenceForKey:kRCPrefInputPasteCommandKey defaultValue:YES];
    NSRunningApplication *front = send ? [self frontmostApplication] : nil;
    NSRunningApplication *target = send ? [self pasteTargetResolvingApplication:application ?: front] : nil;
    // A stale menu target must not steal focus from a different external app.
    BOOL allowedFront = front && (front.processIdentifier == target.processIdentifier ||
        front.processIdentifier == NSProcessInfo.processInfo.processIdentifier);
    id focus = target && allowedFront && [self pasteClock] < deadline
        ? [self focusedElementForApplication:target] : nil;
    BOOL preparedBeforeDeadline = [self pasteClock] < deadline;
    NSPasteboard *board = [self pasteboard];
    NSInteger before = board.changeCount;
    BOOL wrote = writer ? writer(board) : YES;
    NSInteger count = board.changeCount;
    if (writer && (wrote || count != before)) [[self clipboardService] recordInternalPasteboardChangeCount:count];
    // Use belongs to a successful restoration, not to eventual Cmd+V delivery.
    if (writer && wrote && historyDataHash.length)
        [[self clipboardService] recordHistoryUseWithDataHash:historyDataHash];
    if (!wrote || !send || !target || !allowedFront || !preparedBeforeDeadline || [self pasteClock] >= deadline) return;
    self.pendingPasteboard = board;
    self.expectedPasteboardChangeCount = count;
    self.pendingTarget = target;
    self.expectedFocusedElement = focus;
    self.initialFrontPID = front.processIdentifier;
    [self scheduleAfterDelay:kRCPasteMenuCloseDelay block:^{
        if (![self pendingGenerationIsValid:generation target:target]) { [self finishGeneration:generation]; return; }
        if ([self pasteClock] >= deadline) { [self finishGeneration:generation]; return; }
        if (!target.active && ![self activateApplication:target]) { [self finishGeneration:generation]; return; }
        [self sendPasteKeyStrokeWhenApplicationIsReady:target timeoutAt:deadline pasteGeneration:generation];
    }];
}
- (void)pasteClipData:(RCClipData *)clipData { [self pasteClipData:clipData toApplication:nil]; }
- (void)pasteClipData:(RCClipData *)clipData toApplication:(NSRunningApplication *)application {
    [self pasteClipData:clipData toApplication:application historyDataHash:nil];
}
- (void)pasteClipData:(RCClipData *)clipData toApplication:(NSRunningApplication *)application
     historyDataHash:(NSString *)historyDataHash {
    if (!clipData) return;
    NSString *selectedHash = [historyDataHash copy];
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self pasteClipData:clipData toApplication:application historyDataHash:selectedHash];
        });
        return;
    }
    BOOL plain = [self boolPreferenceForKey:kRCBetaPastePlainText defaultValue:YES] && clipData.stringValue.length &&
        [self isPressedModifier:[self integerPreferenceForKey:kRCBetaPastePlainTextModifier defaultValue:0]];
    [self performWrite:^BOOL(NSPasteboard *board) {
        if (!plain) return [clipData writeToPasteboard:board];
        [board clearContents];
        return [board setString:clipData.stringValue forType:NSPasteboardTypeString];
    } toApplication:application historyDataHash:selectedHash];
}
- (void)pastePlainText:(NSString *)text { [self pastePlainText:text toApplication:nil]; }
- (void)pastePlainText:(NSString *)text toApplication:(NSRunningApplication *)application {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self pastePlainText:text toApplication:application]; }); return;
    }
    [self performWrite:^BOOL(NSPasteboard *board) {
        [board clearContents];
        return [board setString:text ?: @"" forType:NSPasteboardTypeString];
    } toApplication:application];
}
- (BOOL)pendingGenerationIsValid:(NSUInteger)generation target:(NSRunningApplication *)target {
    if (generation != self.pasteGeneration || [self pasteClock] >= self.requestDeadline || self.pendingTarget != target || ![self isUsableTarget:target] ||
        !self.pendingPasteboard || self.pendingPasteboard.changeCount != self.expectedPasteboardChangeCount) return NO;
    NSRunningApplication *front = [self frontmostApplication];
    if (!front || front.terminated || (front.processIdentifier != target.processIdentifier && front.processIdentifier != self.initialFrontPID)) return NO;
    if ([self pasteClock] >= self.requestDeadline) return NO;
    id focus = [self focusedElementForApplication:target];
    if ([self pasteClock] >= self.requestDeadline) return NO;
    // Some applications do not expose an AX focused element. Preserve their
    // existing app-level paste support; compare element identity when available.
    BOOL focusMatches = !self.expectedFocusedElement || (focus &&
        CFEqual((__bridge CFTypeRef)focus, (__bridge CFTypeRef)self.expectedFocusedElement));
    front = [self frontmostApplication];
    return focusMatches && generation == self.pasteGeneration &&
        self.pendingPasteboard.changeCount == self.expectedPasteboardChangeCount &&
        front && !front.terminated && (front.processIdentifier == target.processIdentifier ||
                                      front.processIdentifier == self.initialFrontPID) &&
        [self pasteClock] < self.requestDeadline;
}
- (void)sendPasteKeyStrokeWhenApplicationIsReady:(NSRunningApplication *)application
                                    timeoutAt:(CFAbsoluteTime)timeoutAt pasteGeneration:(NSUInteger)generation {
    if ([self pasteClock] >= timeoutAt || ![self pendingGenerationIsValid:generation target:application]) { [self finishGeneration:generation]; return; }
    if (application.active && [self frontmostApplication].processIdentifier == application.processIdentifier) {
        // AX and workspace queries can take time; check the board again after them.
        if (self.pendingPasteboard.changeCount == self.expectedPasteboardChangeCount && generation == self.pasteGeneration
            && [self pasteClock] < self.requestDeadline)
            [self sendPasteKeyStroke];
        [self finishGeneration:generation];
        return;
    }
    if ([self pasteClock] >= timeoutAt) { [self finishGeneration:generation]; return; }
    [self scheduleAfterDelay:kRCPasteActivationPollInterval block:^{
        [self sendPasteKeyStrokeWhenApplicationIsReady:application timeoutAt:timeoutAt pasteGeneration:generation];
    }];
}
- (void)sendPasteKeyStroke {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self sendPasteKeyStroke];
        });
        return;
    }

    // A direct call uses the same bounded target/count checks, without writing
    // or registering an internal clipboard change. The ready callback has a
    // pending target and proceeds to event creation exactly once.
    if (!self.pendingTarget) {
        [self performWrite:nil toApplication:nil];
        return;
    }

    if (![[RCAccessibilityService shared] isAccessibilityEnabled]) {
        NSLog(@"[RCPasteService] Accessibility permission is required to send paste keystroke.");
        return;
    }

    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (source == NULL) {
        NSLog(@"[RCPasteService] Failed to create CGEvent source.");
        return;
    }

    CGEventRef keyDown = CGEventCreateKeyboardEvent(source, (CGKeyCode)9, true);
    CGEventRef keyUp = CGEventCreateKeyboardEvent(source, (CGKeyCode)9, false);

    // G3-005: 両方のイベント作成が成功した場合のみ post する。
    // 片方だけ post するとキー入力が不完全になる。
    NSRunningApplication *target = self.pendingTarget;
    if (keyDown != NULL && keyUp != NULL
        && [self pendingGenerationIsValid:self.pasteGeneration target:target]
        && target.active
        && [self frontmostApplication].processIdentifier == target.processIdentifier
        && self.pendingPasteboard.changeCount == self.expectedPasteboardChangeCount) {
        CGEventSetFlags(keyDown, kCGEventFlagMaskCommand);
        CGEventSetFlags(keyUp, kCGEventFlagMaskCommand);
        if ([self pasteClock] < self.requestDeadline) {
            CGEventPost(kCGAnnotatedSessionEventTap, keyDown);
            CGEventPost(kCGAnnotatedSessionEventTap, keyUp);
        }
    } else if (keyDown == NULL || keyUp == NULL) {
        NSLog(@"[RCPasteService] Failed to create keyboard events for paste keystroke.");
    }

    if (keyDown != NULL) {
        CFRelease(keyDown);
    }
    if (keyUp != NULL) {
        CFRelease(keyUp);
    }

    CFRelease(source);
}

#pragma mark - Private

- (BOOL)isPressedModifier:(NSInteger)flag {
    NSEventModifierFlags flags = [NSEvent modifierFlags] & NSEventModifierFlagDeviceIndependentFlagsMask;
    switch (flag) {
        case 0:
            return (flags & NSEventModifierFlagCommand) != 0;
        case 1:
            return (flags & NSEventModifierFlagShift) != 0;
        case 2:
            return (flags & NSEventModifierFlagControl) != 0;
        case 3:
            return (flags & NSEventModifierFlagOption) != 0;
        default:
            return NO;
    }
}

- (BOOL)boolPreferenceForKey:(NSString *)key defaultValue:(BOOL)defaultValue {
    id rawValue = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    if ([rawValue isKindOfClass:[NSNumber class]]) {
        return [rawValue boolValue];
    }
    if ([rawValue isKindOfClass:[NSString class]]) {
        return [(NSString *)rawValue boolValue];
    }
    return defaultValue;
}

- (NSInteger)integerPreferenceForKey:(NSString *)key defaultValue:(NSInteger)defaultValue {
    id rawValue = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    if ([rawValue isKindOfClass:[NSNumber class]]) {
        return [rawValue integerValue];
    }
    if ([rawValue isKindOfClass:[NSString class]]) {
        return [(NSString *)rawValue integerValue];
    }
    return defaultValue;
}

@end
