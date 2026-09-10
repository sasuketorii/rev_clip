//
//  RCPrivacyService.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import "RCPrivacyService.h"

NSString * const RCClipboardAccessStateDidChangeNotification = @"RCClipboardAccessStateDidChangeNotification";

static NSString * const kRCPrivacyServiceErrorDomain = @"com.revclip.privacy";

typedef NS_ENUM(NSInteger, RCPrivacyServiceErrorCode) {
    RCPrivacyServiceErrorCodeAPIUnavailable = 1,
    RCPrivacyServiceErrorCodeDetectionUnavailable = 2,
};

@interface RCPrivacyService ()

@property (nonatomic, assign) RCClipboardAccessState cachedClipboardAccessState;
@property (nonatomic, assign) BOOL didPresentClipboardAccessGuidance;

- (RCClipboardAccessState)accessStateByMappingPasteboardAccessBehavior:(NSInteger)behavior
                                                 privacyAPIAvailable:(BOOL)privacyAPIAvailable;
- (BOOL)shouldCaptureClipboardContentsForAccessState:(RCClipboardAccessState)state;
- (void)handleApplicationDidBecomeActive:(NSNotification *)notification;

@end

@implementation RCPrivacyService

+ (instancetype)shared {
    static RCPrivacyService *sharedService = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedService = [[self alloc] init];
    });
    return sharedService;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _cachedClipboardAccessState = RCClipboardAccessStateUnknown;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleApplicationDidBecomeActive:)
                                                     name:NSApplicationDidBecomeActiveNotification
                                                   object:nil];
        [self refreshClipboardAccessState];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Public

// G3-010: getter から通知ロジックを分離。
// clipboardAccessState は純粋な getter として副作用を持たない。
// 状態変更の通知が必要な場合は refreshClipboardAccessState を呼ぶこと。
- (RCClipboardAccessState)clipboardAccessState {
    return [self resolvedClipboardAccessState];
}

- (void)refreshClipboardAccessState {
    RCClipboardAccessState state = [self resolvedClipboardAccessState];
    [self postClipboardAccessStateDidChangeIfNeeded:state];
}

- (BOOL)canAccessClipboard {
    // G3-009: Granted の場合のみ true を返す。
    // Unknown の場合はまだ確定していないため、安全側に倒して false とする。
    // ただし macOS 15 以前（プライバシー API が存在しない環境）では
    // resolvedClipboardAccessState が Granted を返すため常に true になる。
    RCClipboardAccessState state = [self clipboardAccessState];
    return (state == RCClipboardAccessStateGranted);
}

- (BOOL)shouldCaptureClipboardContents {
    return [self shouldCaptureClipboardContentsForAccessState:[self clipboardAccessState]];
}

- (BOOL)shouldCaptureClipboardContentsForAccessState:(RCClipboardAccessState)state {
    switch (state) {
        case RCClipboardAccessStateGranted:
        case RCClipboardAccessStateNotDetermined:
            return YES;
        case RCClipboardAccessStateDenied:
        case RCClipboardAccessStateUnknown:
            return NO;
    }
    return NO;
}

- (void)presentClipboardAccessGuidanceIfNeeded {
    if ([self clipboardAccessState] != RCClipboardAccessStateDenied) {
        return;
    }

    BOOL shouldPresent = NO;
    @synchronized (self) {
        if (!self.didPresentClipboardAccessGuidance) {
            self.didPresentClipboardAccessGuidance = YES;
            shouldPresent = YES;
        }
    }
    if (!shouldPresent) {
        return;
    }

    [self showClipboardAccessGuidance];
}

- (BOOL)isClipboardPrivacyAPIAvailable {
    if (![self isMacOS154OrLater]) {
        return NO;
    }

    __block BOOL isAvailable = NO;
    dispatch_block_t resolveBlock = ^{
        if (@available(macOS 15.4, *)) {
            NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
            isAvailable = [pasteboard respondsToSelector:@selector(accessBehavior)]
                && [pasteboard respondsToSelector:@selector(detectPatternsForPatterns:completionHandler:)];
        }
    };

    if ([NSThread isMainThread]) {
        resolveBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), resolveBlock);
    }

    return isAvailable;
}

- (void)detectClipboardPatternsWithCompletion:(void (^)(NSSet<NSString *> * _Nullable patterns, NSError * _Nullable error))completion {
    if (completion == nil) {
        return;
    }

    if (![self isClipboardPrivacyAPIAvailable]) {
        completion(nil, [self apiUnavailableError]);
        return;
    }

    dispatch_block_t detectBlock = ^{
        if (@available(macOS 15.4, *)) {
            NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
            if (![pasteboard respondsToSelector:@selector(detectPatternsForPatterns:completionHandler:)]) {
                completion(nil, [self detectionUnavailableError]);
                return;
            }

            NSSet<NSPasteboardDetectionPattern> *patterns = [self supportedDetectionPatterns];
            if (patterns.count == 0) {
                completion([NSSet set], nil);
                return;
            }

            [pasteboard detectPatternsForPatterns:patterns
                                completionHandler:^(NSSet<NSPasteboardDetectionPattern> * _Nullable detectedPatterns,
                                                    NSError * _Nullable error) {
                completion((NSSet<NSString *> *)detectedPatterns, error);
            }];
            return;
        }

        completion(nil, [self apiUnavailableError]);
    };

    if ([NSThread isMainThread]) {
        detectBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), detectBlock);
    }
}

- (void)showClipboardAccessGuidance {
    dispatch_block_t showAlert = ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText = NSLocalizedString(@"Revclip needs clipboard access", nil);
        alert.informativeText = NSLocalizedString(@"macOS requires explicit permission for clipboard access. Please allow Revclip to access the clipboard in System Settings.", nil);
        [alert addButtonWithTitle:NSLocalizedString(@"Open System Settings", nil)];
        [alert addButtonWithTitle:NSLocalizedString(@"Later", nil)];

        NSModalResponse response = [alert runModal];
        if (response != NSAlertFirstButtonReturn) {
            return;
        }

        NSWorkspace *workspace = [NSWorkspace sharedWorkspace];

        // G3-015: macOS 16+ では新形式のシステム設定 URL を優先して使用
        if (@available(macOS 16, *)) {
            NSURL *macOS16ClipboardURL = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard"];
            if (macOS16ClipboardURL != nil && [workspace openURL:macOS16ClipboardURL]) {
                return;
            }
        }

        NSURL *clipboardSettingsURL = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Clipboard"];
        if (clipboardSettingsURL != nil && [workspace openURL:clipboardSettingsURL]) {
            return;
        }

        NSURL *privacySettingsURL = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security"];
        if (privacySettingsURL != nil) {
            [workspace openURL:privacySettingsURL];
        }
    };

    if ([NSThread isMainThread]) {
        showAlert();
    } else {
        dispatch_async(dispatch_get_main_queue(), showAlert);
    }
}

#pragma mark - Private

- (BOOL)isMacOS154OrLater {
    NSOperatingSystemVersion minimumVersion = (NSOperatingSystemVersion){.majorVersion = 15, .minorVersion = 4, .patchVersion = 0};
    return [[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:minimumVersion];
}

- (RCClipboardAccessState)accessStateByMappingPasteboardAccessBehavior:(NSInteger)behavior
                                                 privacyAPIAvailable:(BOOL)privacyAPIAvailable {
    if (!privacyAPIAvailable) {
        return RCClipboardAccessStateGranted;
    }

    switch ((NSPasteboardAccessBehavior)behavior) {
        case NSPasteboardAccessBehaviorDefault:
        case NSPasteboardAccessBehaviorAsk:
            return RCClipboardAccessStateNotDetermined;
        case NSPasteboardAccessBehaviorAlwaysAllow:
            return RCClipboardAccessStateGranted;
        case NSPasteboardAccessBehaviorAlwaysDeny:
            return RCClipboardAccessStateDenied;
        default:
            return RCClipboardAccessStateUnknown;
    }
}

- (RCClipboardAccessState)resolvedClipboardAccessState {
    if (![self isMacOS154OrLater]) {
        return [self accessStateByMappingPasteboardAccessBehavior:0 privacyAPIAvailable:NO];
    }

    __block RCClipboardAccessState state = RCClipboardAccessStateUnknown;
    dispatch_block_t resolveBlock = ^{
        if (@available(macOS 15.4, *)) {
            NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
            if (![pasteboard respondsToSelector:@selector(accessBehavior)]) {
                state = [self accessStateByMappingPasteboardAccessBehavior:0 privacyAPIAvailable:NO];
                return;
            }

            state = [self accessStateByMappingPasteboardAccessBehavior:(NSInteger)pasteboard.accessBehavior
                                                privacyAPIAvailable:YES];
        }
    };

    if ([NSThread isMainThread]) {
        resolveBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), resolveBlock);
    }

    return state;
}

- (NSSet<NSPasteboardDetectionPattern> *)supportedDetectionPatterns API_AVAILABLE(macos(15.4)) {
    NSMutableSet<NSPasteboardDetectionPattern> *patterns = [NSMutableSet set];

    if (NSPasteboardDetectionPatternProbableWebURL != nil) {
        [patterns addObject:NSPasteboardDetectionPatternProbableWebURL];
    }
    if (NSPasteboardDetectionPatternProbableWebSearch != nil) {
        [patterns addObject:NSPasteboardDetectionPatternProbableWebSearch];
    }
    if (NSPasteboardDetectionPatternNumber != nil) {
        [patterns addObject:NSPasteboardDetectionPatternNumber];
    }
    if (NSPasteboardDetectionPatternLink != nil) {
        [patterns addObject:NSPasteboardDetectionPatternLink];
    }
    if (NSPasteboardDetectionPatternPhoneNumber != nil) {
        [patterns addObject:NSPasteboardDetectionPatternPhoneNumber];
    }
    if (NSPasteboardDetectionPatternEmailAddress != nil) {
        [patterns addObject:NSPasteboardDetectionPatternEmailAddress];
    }
    if (NSPasteboardDetectionPatternPostalAddress != nil) {
        [patterns addObject:NSPasteboardDetectionPatternPostalAddress];
    }
    if (NSPasteboardDetectionPatternCalendarEvent != nil) {
        [patterns addObject:NSPasteboardDetectionPatternCalendarEvent];
    }
    if (NSPasteboardDetectionPatternShipmentTrackingNumber != nil) {
        [patterns addObject:NSPasteboardDetectionPatternShipmentTrackingNumber];
    }
    if (NSPasteboardDetectionPatternFlightNumber != nil) {
        [patterns addObject:NSPasteboardDetectionPatternFlightNumber];
    }
    if (NSPasteboardDetectionPatternMoneyAmount != nil) {
        [patterns addObject:NSPasteboardDetectionPatternMoneyAmount];
    }

    return [patterns copy];
}

- (void)postClipboardAccessStateDidChangeIfNeeded:(RCClipboardAccessState)newState {
    RCClipboardAccessState oldState = RCClipboardAccessStateUnknown;
    BOOL hasChange = NO;

    @synchronized (self) {
        oldState = self.cachedClipboardAccessState;
        if (oldState != newState) {
            self.cachedClipboardAccessState = newState;
            hasChange = YES;
        }
    }

    if (!hasChange) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:RCClipboardAccessStateDidChangeNotification
                                                            object:self
                                                          userInfo:@{
                                                              @"state": @(newState),
                                                              @"previousState": @(oldState),
                                                          }];
    });
}

- (NSError *)apiUnavailableError {
    return [NSError errorWithDomain:kRCPrivacyServiceErrorDomain
                               code:RCPrivacyServiceErrorCodeAPIUnavailable
                           userInfo:@{
                               NSLocalizedDescriptionKey: @"Clipboard privacy API is not available on this macOS version.",
                           }];
}

- (NSError *)detectionUnavailableError {
    return [NSError errorWithDomain:kRCPrivacyServiceErrorDomain
                               code:RCPrivacyServiceErrorCodeDetectionUnavailable
                           userInfo:@{
                               NSLocalizedDescriptionKey: @"Pattern detection is not available for this pasteboard.",
                           }];
}

- (void)handleApplicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    [self refreshClipboardAccessState];
}

@end
