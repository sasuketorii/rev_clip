#import "RCLocalization.h"
//
//  RCHotKeyRecorderView.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Current project: AGPL-3.0-only; legacy portions: MIT. See THIRD_PARTY_NOTICES.md.
//

#import "RCHotKeyRecorderView.h"

#import <Carbon/Carbon.h>

static CGFloat const kRCHotKeyRecorderCornerRadius = 6.0;
static CGFloat const kRCHotKeyRecorderBorderWidth = 1.0;
static CGFloat const kRCHotKeyRecorderHorizontalPadding = 12.0;
static CGFloat const kRCHotKeyRecorderFontSize = 13.0;

static BOOL RCEqualKeyCombo(RCKeyCombo left, RCKeyCombo right) {
    return left.keyCode == right.keyCode && left.modifiers == right.modifiers;
}

static NSEventModifierFlags RCRecorderRelevantModifiers(NSEventModifierFlags modifierFlags) {
    NSEventModifierFlags relevant = modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    return relevant & (NSEventModifierFlagCommand
                       | NSEventModifierFlagShift
                       | NSEventModifierFlagControl
                       | NSEventModifierFlagOption);
}

@interface RCHotKeyRecorderView ()

@property (nonatomic, assign, readwrite) BOOL isRecording;
@property (nonatomic, assign) NSEventModifierFlags recordingModifierFlags;
@property (nonatomic, assign) CFMachPortRef recordingTap;
@property (nonatomic, assign) CFRunLoopSourceRef recordingSource;
@property (nonatomic, strong) NSEvent *pendingKeyEvent;
@property (nonatomic, strong) NSMutableIndexSet *consumedKeys;
@property (nonatomic) NSUInteger recordingGeneration;
@property (nonatomic, strong) NSTimer *recordingTimeout;
@property (nonatomic, strong) id outsideClickMonitor;
@property (nonatomic, weak) NSWindow *recordingWindow;
- (void)deferCaptureStop;
- (BOOL)recordingContextIsActive;
- (CGEventRef)captureEvent:(CGEventRef)event type:(CGEventType)type;
- (BOOL)beginEventCapture;
- (void)endEventCapture;
- (void)recordingContextEnded:(NSNotification *)notification;

- (void)rc_commonInit;
- (BOOL)rc_shouldWarnForModifiers:(UInt32)modifiers;
- (void)rc_showUnsupportedOptionWarning;
- (NSString *)rc_displayText;
+ (NSString *)rc_stringFromKeyCombo:(RCKeyCombo)keyCombo;
+ (NSString *)rc_symbolStringFromModifiers:(NSEventModifierFlags)modifiers;
+ (NSString *)rc_stringForKeyCode:(UInt16)keyCode modifiers:(NSEventModifierFlags)modifiers;
+ (NSString *)rc_translatedStringForKeyCode:(UInt16)keyCode modifiers:(NSEventModifierFlags)modifiers;
- (void)processKeyEvent:(NSEvent *)event;

@end

static __weak RCHotKeyRecorderView *RCActiveRecorder;

static CGEventRef RCRecorderTap(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
    return [(__bridge RCHotKeyRecorderView *)context captureEvent:event type:type];
}

@implementation RCHotKeyRecorderView

- (BOOL)beginEventCapture {
    // Session head intercepts key presses before registered hotkeys and AppKit
    // key equivalents. No key event is persisted or observed outside recording.
    if (!AXIsProcessTrusted() || IsSecureEventInputEnabled()) return NO;
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) | CGEventMaskBit(kCGEventFlagsChanged);
    self.recordingTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
        kCGEventTapOptionDefault, mask, RCRecorderTap, (__bridge void *)self);
    if (!self.recordingTap) return NO;
    self.recordingSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, self.recordingTap, 0);
    if (!self.recordingSource) { [self endEventCapture]; return NO; }
    CFRunLoopAddSource(CFRunLoopGetMain(), self.recordingSource, kCFRunLoopCommonModes);
    return YES;
}
- (void)endEventCapture {
    [self.recordingTimeout invalidate]; self.recordingTimeout = nil;
    if (self.outsideClickMonitor) { [NSEvent removeMonitor:self.outsideClickMonitor]; self.outsideClickMonitor = nil; }
    if (self.recordingTap) CFMachPortInvalidate(self.recordingTap);
    if (self.recordingSource) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), self.recordingSource, kCFRunLoopCommonModes);
        CFRelease(self.recordingSource); self.recordingSource = NULL;
    }
    if (self.recordingTap) { CFRelease(self.recordingTap); self.recordingTap = NULL; }
    self.pendingKeyEvent = nil;
    [self.consumedKeys removeAllIndexes];
}
- (BOOL)recordingContextIsActive {
    return NSApp.isActive && self.window.isKeyWindow && self.window.firstResponder == self;
}
- (void)deferCaptureStop {
    if (self.recordingTap) CGEventTapEnable(self.recordingTap, false);
    NSUInteger generation = self.recordingGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (weakSelf.recordingGeneration == generation) [weakSelf stopRecording];
    });
}
- (CGEventRef)captureEvent:(CGEventRef)event type:(CGEventType)type {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        [self deferCaptureStop]; // Destroy outside the callback.
        return event;
    }
    if (!self.isRecording || ![self recordingContextIsActive]) {
        [self deferCaptureStop]; return event;
    }
    if (type == kCGEventFlagsChanged) {
        [self flagsChanged:[NSEvent eventWithCGEvent:event]];
        return event; // Keep modifier state balanced for the rest of the system.
    }
    NSUInteger keyCode = (UInt16)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    if (type == kCGEventKeyDown) {
        // Ignore pre-capture repeats without owning their eventual keyUp.
        if (CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) && ![self.consumedKeys containsIndex:keyCode]) return NULL;
        [self.consumedKeys addIndex:keyCode];
        if (!self.pendingKeyEvent && !CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat))
            self.pendingKeyEvent = [NSEvent eventWithCGEvent:event];
        return NULL;
    }
    if (type == kCGEventKeyUp) {
        if (![self.consumedKeys containsIndex:keyCode]) return event;
        [self.consumedKeys removeIndex:keyCode];
        NSEvent *press = self.pendingKeyEvent;
        if (press && self.consumedKeys.count == 0) {
            self.pendingKeyEvent = nil;
            // Both down and up are consumed before registration changes. Validation
            // and UI work run outside the tap callback so it cannot time out.
            NSUInteger generation = self.recordingGeneration;
            __weak typeof(self) weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (weakSelf.isRecording && weakSelf.recordingGeneration == generation) [weakSelf processKeyEvent:press];
            });
        }
        return NULL;
    }
    return event;
}
- (void)recordingContextEnded:(NSNotification *)notification { [self stopRecording]; }
- (void)viewWillMoveToWindow:(NSWindow *)newWindow {
    if (self.window != newWindow) { [self stopRecording]; self.warningLabel.stringValue = @""; }
    [super viewWillMoveToWindow:newWindow];
}
- (void)dealloc { [self endEventCapture]; [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)showAssignmentResult:(RCHotKeyAssignmentResult *)result {
    NSString *message = [RCHotKeyRecorderView messageForAssignmentResult:result];
    if (message.length && result.failedSlot.length)
        message = [NSString stringWithFormat:@"%@: %@", [RCHotKeyRecorderView localizedNameForSlot:result.failedSlot], message];
    [self showWarningMessage:message];
}
- (void)showWarningMessage:(NSString *)message {
    self.warningLabel.textColor = NSColor.systemYellowColor;
    self.warningLabel.stringValue = message;
    if (self.warningLabel.stringValue.length) {
        [self.warningLabel.superview layoutSubtreeIfNeeded];
        [self.warningLabel scrollRectToVisible:self.warningLabel.bounds];
        NSAccessibilityPostNotificationWithUserInfo(self.warningLabel, NSAccessibilityAnnouncementRequestedNotification,
            @{NSAccessibilityAnnouncementKey:self.warningLabel.stringValue, NSAccessibilityPriorityKey:@(NSAccessibilityPriorityHigh)});
    }
}


- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self rc_commonInit];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self rc_commonInit];
    }
    return self;
}

- (void)prepareForInterfaceBuilder {
    [super prepareForInterfaceBuilder];
    [self setNeedsDisplay:YES];
}

- (NSSize)intrinsicContentSize {
    return NSMakeSize(180.0, 30.0);
}

- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityRole { return NSAccessibilityButtonRole; }
- (id)accessibilityValue { return [self rc_displayText]; }
- (BOOL)accessibilityPerformPress { [self startRecording]; return self.isRecording; }

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)becomeFirstResponder {
    BOOL didBecome = [super becomeFirstResponder];
    if (didBecome) {
        [self setNeedsDisplay:YES];
    }
    return didBecome;
}

- (BOOL)resignFirstResponder {
    BOOL didResign = [super resignFirstResponder];
    if (didResign) {
        [self stopRecording];
        [self setNeedsDisplay:YES];
    }
    return didResign;
}

- (void)setKeyCombo:(RCKeyCombo)keyCombo {
    if (RCEqualKeyCombo(_keyCombo, keyCombo)) {
        return;
    }

    self.warningLabel.stringValue = @"";
    _keyCombo = keyCombo;
    [self setNeedsDisplay:YES];
}

- (void)startRecording {
    if (self.isRecording) {
        return;
    }

    if (self.window == nil || ![self.window makeFirstResponder:self]) {
        return;
    }

    [RCActiveRecorder stopRecording];
    self.consumedKeys = [NSMutableIndexSet indexSet];
    self.warningLabel.stringValue = @"";
    if (![self beginEventCapture]) {
        [self showWarningMessage:RCLocalizedString(@"Shortcut recording is unavailable. Check Accessibility access and try again.", nil)];
        return;
    }
    self.isRecording = YES;
    self.recordingGeneration++;
    RCActiveRecorder = self;
    RCHotKeyService.shared.shortcutRecordingOwner = self;
    self.recordingWindow = self.window;
    __weak typeof(self) weakSelf = self;
    self.recordingTimeout = [NSTimer timerWithTimeInterval:30 repeats:NO block:^(NSTimer *timer) { [weakSelf stopRecording]; }];
    [NSRunLoop.mainRunLoop addTimer:self.recordingTimeout forMode:NSRunLoopCommonModes];
    self.outsideClickMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown handler:^NSEvent *(NSEvent *event) {
        RCHotKeyRecorderView *recorder = weakSelf;
        if (event.window != recorder.window || !NSPointInRect([recorder convertPoint:event.locationInWindow fromView:nil], recorder.bounds)) [recorder stopRecording];
        return event;
    }];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(recordingContextEnded:)
        name:NSWindowDidResignKeyNotification object:self.window];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(recordingContextEnded:)
        name:NSWindowWillCloseNotification object:self.window];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(recordingContextEnded:)
        name:NSApplicationDidResignActiveNotification object:nil];
    self.recordingModifierFlags = 0;
    [self setNeedsDisplay:YES];
}

- (void)stopRecording {
    if (!self.isRecording) {
        return;
    }

    self.isRecording = NO;
    self.recordingGeneration++;
    if (RCActiveRecorder == self) RCActiveRecorder = nil;
    [self endEventCapture];
    if (RCHotKeyService.shared.shortcutRecordingOwner == self) RCHotKeyService.shared.shortcutRecordingOwner = nil;
    [NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowDidResignKeyNotification object:self.recordingWindow];
    [NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowWillCloseNotification object:self.recordingWindow];
    [NSNotificationCenter.defaultCenter removeObserver:self name:NSApplicationDidResignActiveNotification object:nil];
    self.recordingWindow = nil;
    self.recordingModifierFlags = 0;
    [self setNeedsDisplay:YES];
}

- (void)clearKeyCombo {
    self.keyCombo = RCInvalidKeyCombo();
    [self stopRecording];
    [self.delegate hotKeyRecorderViewDidClearKeyCombo:self];
}

- (void)mouseDown:(NSEvent *)event {
    (void)event;
    [self startRecording];
}

- (void)keyDown:(NSEvent *)event {
    if (!self.isRecording) {
        [super keyDown:event];
        return;
    }

    [self rejectUncapturedInput];
}

- (void)rejectUncapturedInput {
    // A real recording completes only after the tap consumes keyUp. AppKit input
    // during recording means capture was bypassed (for example Secure Input).
    [self stopRecording];
    [self showWarningMessage:RCLocalizedString(@"Shortcut recording is unavailable. Check Accessibility access and try again.", nil)];
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (self.isRecording) {
        [self rejectUncapturedInput];
        return YES;
    }

    return [super performKeyEquivalent:event];
}

- (void)processKeyEvent:(NSEvent *)event {
    if (event == nil) {
        return;
    }

    UInt16 keyCode = (UInt16)event.keyCode;
    NSEventModifierFlags cocoaModifiers = RCRecorderRelevantModifiers(event.modifierFlags);

    if (keyCode == kVK_Escape) {
        [self stopRecording];
        return;
    }

    BOOL isDeleteKey = (keyCode == kVK_Delete || keyCode == kVK_ForwardDelete);
    if (isDeleteKey && cocoaModifiers == 0) {
        [self clearKeyCombo];
        return;
    }

    UInt32 carbonModifiers = [RCHotKeyService carbonModifiersFromCocoaModifiers:cocoaModifiers];

    if (carbonModifiers == 0) {
        NSBeep();
        return;
    }

    if ([self rc_shouldWarnForModifiers:carbonModifiers]) {
        [self rc_showUnsupportedOptionWarning];
        return;
    }

    RCKeyCombo newCombo = RCMakeKeyCombo((UInt32)keyCode, carbonModifiers);
    self.keyCombo = newCombo;
    [self stopRecording];
    [self.delegate hotKeyRecorderView:self didRecordKeyCombo:newCombo];
}

- (void)flagsChanged:(NSEvent *)event {
    if (!self.isRecording) {
        [super flagsChanged:event];
        return;
    }

    self.recordingModifierFlags = RCRecorderRelevantModifiers(event.modifierFlags);
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    NSRect bounds = NSInsetRect(self.bounds, kRCHotKeyRecorderBorderWidth / 2.0, kRCHotKeyRecorderBorderWidth / 2.0);
    if (!NSIntersectsRect(bounds, dirtyRect) || NSIsEmptyRect(bounds)) {
        return;
    }

    BOOL isFocused = self.window.firstResponder == self;

    NSColor *backgroundColor = [NSColor textBackgroundColor];
    NSColor *borderColor = [NSColor separatorColor];
    if (self.isRecording) {
        backgroundColor = [[NSColor controlAccentColor] colorWithAlphaComponent:0.12];
        borderColor = [NSColor controlAccentColor];
    } else if (isFocused) {
        borderColor = [NSColor keyboardFocusIndicatorColor];
    }

    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:bounds
                                                         xRadius:kRCHotKeyRecorderCornerRadius
                                                         yRadius:kRCHotKeyRecorderCornerRadius];
    [backgroundColor setFill];
    [path fill];

    [borderColor setStroke];
    path.lineWidth = kRCHotKeyRecorderBorderWidth;
    [path stroke];

    NSString *displayText = [self rc_displayText];
    BOOL isPlaceholder = (!self.isRecording && !RCIsValidKeyCombo(self.keyCombo));

    NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
    paragraphStyle.alignment = NSTextAlignmentCenter;
    paragraphStyle.lineBreakMode = NSLineBreakByTruncatingTail;

    NSDictionary<NSAttributedStringKey, id> *attributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:kRCHotKeyRecorderFontSize
                                               weight:(self.isRecording ? NSFontWeightSemibold : NSFontWeightRegular)],
        NSForegroundColorAttributeName: (isPlaceholder ? [NSColor secondaryLabelColor] : [NSColor labelColor]),
        NSParagraphStyleAttributeName: paragraphStyle,
    };

    NSRect textRect = NSInsetRect(self.bounds, kRCHotKeyRecorderHorizontalPadding, 0.0);
    NSSize textSize = [displayText sizeWithAttributes:attributes];
    textRect.origin.y = floor(NSMidY(self.bounds) - (textSize.height / 2.0));
    textRect.size.height = ceil(textSize.height);
    [displayText drawInRect:textRect withAttributes:attributes];
}

#pragma mark - Private

- (void)rc_commonInit {
    _keyCombo = RCInvalidKeyCombo();
    _isRecording = NO;
    _recordingModifierFlags = 0;

    self.wantsLayer = YES;
}

- (BOOL)rc_shouldWarnForModifiers:(UInt32)modifiers {
    // One rule for the recorder, the preferences and the CLI (RCHotKeyService).
    // The key code is irrelevant to it; modifier-less input is rejected before this.
    return modifiers != 0 && ![RCHotKeyService isAssignableKeyCombo:RCMakeKeyCombo(kVK_ANSI_S, modifiers)];
}

- (void)rc_showUnsupportedOptionWarning {
    [self stopRecording];
    [self showWarningMessage:RCLocalizedString(@"On macOS 15 (Sequoia) and later, Option-only or Option+Shift-only modifier combinations are not supported due to system restrictions.\nPlease use a combination that includes Command or Control.", nil)];
}

- (NSString *)rc_displayText {
    if (self.isRecording) {
        NSString *modifierText = [RCHotKeyRecorderView rc_symbolStringFromModifiers:self.recordingModifierFlags];
        return (modifierText.length > 0) ? modifierText : RCLocalizedString(@"Type shortcut", nil);
    }

    if (RCIsValidKeyCombo(self.keyCombo)) {
        return [RCHotKeyRecorderView displayStringForKeyCombo:self.keyCombo];
    }

    return RCLocalizedString(@"Click to record", nil);
}

+ (NSString *)displayStringForKeyCombo:(RCKeyCombo)combo {
    return RCIsValidKeyCombo(combo) ? [self rc_stringFromKeyCombo:combo] : @"";
}

+ (NSString *)keyEquivalentForKeyCombo:(RCKeyCombo)combo {
    if (!RCIsValidKeyCombo(combo)) return @"";
    switch (combo.keyCode) {
        case kVK_Return: return @"\r";
        case kVK_Tab: return @"\t";
        case kVK_Space: return @" ";
        case kVK_Delete: return @"\b";
        case kVK_Escape: return @"\033";
        case kVK_LeftArrow: return [NSString stringWithFormat:@"%C", (unichar)NSLeftArrowFunctionKey];
        case kVK_RightArrow: return [NSString stringWithFormat:@"%C", (unichar)NSRightArrowFunctionKey];
        case kVK_UpArrow: return [NSString stringWithFormat:@"%C", (unichar)NSUpArrowFunctionKey];
        case kVK_DownArrow: return [NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey];
        case kVK_Home: return [NSString stringWithFormat:@"%C", (unichar)NSHomeFunctionKey];
        case kVK_End: return [NSString stringWithFormat:@"%C", (unichar)NSEndFunctionKey];
        case kVK_PageUp: return [NSString stringWithFormat:@"%C", (unichar)NSPageUpFunctionKey];
        case kVK_PageDown: return [NSString stringWithFormat:@"%C", (unichar)NSPageDownFunctionKey];
        case kVK_ForwardDelete: return [NSString stringWithFormat:@"%C", (unichar)NSDeleteFunctionKey];
        case kVK_Help: return [NSString stringWithFormat:@"%C", (unichar)NSHelpFunctionKey];
        case kVK_F1: return [NSString stringWithFormat:@"%C", (unichar)NSF1FunctionKey];
        case kVK_F2: return [NSString stringWithFormat:@"%C", (unichar)NSF2FunctionKey];
        case kVK_F3: return [NSString stringWithFormat:@"%C", (unichar)NSF3FunctionKey];
        case kVK_F4: return [NSString stringWithFormat:@"%C", (unichar)NSF4FunctionKey];
        case kVK_F5: return [NSString stringWithFormat:@"%C", (unichar)NSF5FunctionKey];
        case kVK_F6: return [NSString stringWithFormat:@"%C", (unichar)NSF6FunctionKey];
        case kVK_F7: return [NSString stringWithFormat:@"%C", (unichar)NSF7FunctionKey];
        case kVK_F8: return [NSString stringWithFormat:@"%C", (unichar)NSF8FunctionKey];
        case kVK_F9: return [NSString stringWithFormat:@"%C", (unichar)NSF9FunctionKey];
        case kVK_F10: return [NSString stringWithFormat:@"%C", (unichar)NSF10FunctionKey];
        case kVK_F11: return [NSString stringWithFormat:@"%C", (unichar)NSF11FunctionKey];
        case kVK_F12: return [NSString stringWithFormat:@"%C", (unichar)NSF12FunctionKey];
        case kVK_F13: return [NSString stringWithFormat:@"%C", (unichar)NSF13FunctionKey];
        case kVK_F14: return [NSString stringWithFormat:@"%C", (unichar)NSF14FunctionKey];
        case kVK_F15: return [NSString stringWithFormat:@"%C", (unichar)NSF15FunctionKey];
        case kVK_F16: return [NSString stringWithFormat:@"%C", (unichar)NSF16FunctionKey];
        case kVK_F17: return [NSString stringWithFormat:@"%C", (unichar)NSF17FunctionKey];
        case kVK_F18: return [NSString stringWithFormat:@"%C", (unichar)NSF18FunctionKey];
        case kVK_F19: return [NSString stringWithFormat:@"%C", (unichar)NSF19FunctionKey];
        case kVK_F20: return [NSString stringWithFormat:@"%C", (unichar)NSF20FunctionKey];
        default: return [[self rc_translatedStringForKeyCode:(UInt16)combo.keyCode modifiers:0] lowercaseString];
    }
}

+ (NSString *)localizedNameForSlot:(NSString *)slot {
    if ([slot hasPrefix:RCHotKeySlotFolderPrefix]) { return RCLocalizedString(@"Shortcut Slot Folder", nil); }
    NSDictionary<NSString *, NSString *> *keys = @{
        RCHotKeySlotMain: @"Shortcut Slot Main", RCHotKeySlotHistory: @"Shortcut Slot History",
        RCHotKeySlotSnippet: @"Shortcut Slot Snippet", RCHotKeySlotClearHistory: @"Shortcut Slot Clear History",
        RCHotKeySlotOCR: @"Shortcut Slot OCR",
    };
    NSString *key = slot.length > 0 ? keys[slot] : nil;
    return key != nil ? RCLocalizedString(key, nil) : (slot ?: @"");
}

+ (NSString *)messageForAssignmentResult:(RCHotKeyAssignmentResult *)result {
    switch (result.status) {
        case RCHotKeyAssignmentStatusOK: return @"";
        case RCHotKeyAssignmentStatusInternalConflict:
            return [NSString stringWithFormat:RCLocalizedString(@"Shortcut Conflict Internal", nil),
                    [self localizedNameForSlot:result.conflictingSlot]];
        case RCHotKeyAssignmentStatusSystemReserved: return RCLocalizedString(@"Shortcut Conflict System", nil);
        case RCHotKeyAssignmentStatusRegistrationFailed:
            // An OS refusal. Another application using the same keys does not cause it and
            // cannot be detected, so the wording never points at other applications.
            return [NSString stringWithFormat:RCLocalizedString(@"Shortcut Registration Failed", nil), (int)result.osStatus];
        case RCHotKeyAssignmentStatusUnavailable: return RCLocalizedString(@"Shortcut Unavailable", nil);
        case RCHotKeyAssignmentStatusInvalid: return RCLocalizedString(@"Shortcut Invalid", nil);
    }
    return RCLocalizedString(@"Shortcut Invalid", nil);
}

+ (NSString *)displayStringForKeyEquivalent:(NSString *)key modifiers:(NSEventModifierFlags)modifiers {
    if (key.length == 0) return @"";
    NSString *label = key.uppercaseString;
    unichar character = [key characterAtIndex:0];
    if (character >= NSF1FunctionKey && character <= NSF20FunctionKey) {
        label = [NSString stringWithFormat:@"F%u", character - NSF1FunctionKey + 1];
    } else {
        NSDictionary *symbols = @{@(NSLeftArrowFunctionKey):@"←", @(NSRightArrowFunctionKey):@"→",
            @(NSUpArrowFunctionKey):@"↑", @(NSDownArrowFunctionKey):@"↓", @(NSHomeFunctionKey):@"↖",
            @(NSEndFunctionKey):@"↘", @(NSPageUpFunctionKey):@"⇞", @(NSPageDownFunctionKey):@"⇟",
            @(NSDeleteFunctionKey):@"⌦", @13:@"↩", @9:@"⇥", @8:@"⌫", @27:@"⎋", @32:@"Space"};
        label = symbols[@(character)] ?: label;
    }
    return [[self rc_symbolStringFromModifiers:modifiers] stringByAppendingString:label];
}

+ (NSString *)rc_stringFromKeyCombo:(RCKeyCombo)keyCombo {
    NSEventModifierFlags cocoaModifiers = [RCHotKeyService cocoaModifiersFromCarbonModifiers:keyCombo.modifiers];
    NSString *modifierText = [self rc_symbolStringFromModifiers:cocoaModifiers];
    NSString *keyText = [self rc_stringForKeyCode:(UInt16)keyCombo.keyCode modifiers:cocoaModifiers];

    if (keyText.length == 0) {
        keyText = [NSString stringWithFormat:@"%u", keyCombo.keyCode];
    }

    return [modifierText stringByAppendingString:keyText];
}

+ (NSString *)rc_symbolStringFromModifiers:(NSEventModifierFlags)modifiers {
    NSMutableString *result = [NSMutableString string];

    if ((modifiers & NSEventModifierFlagControl) != 0) {
        [result appendString:@"⌃"];
    }
    if ((modifiers & NSEventModifierFlagOption) != 0) {
        [result appendString:@"⌥"];
    }
    if ((modifiers & NSEventModifierFlagShift) != 0) {
        [result appendString:@"⇧"];
    }
    if ((modifiers & NSEventModifierFlagCommand) != 0) {
        [result appendString:@"⌘"];
    }

    return [result copy];
}

+ (NSString *)rc_stringForKeyCode:(UInt16)keyCode modifiers:(NSEventModifierFlags)modifiers {
    switch (keyCode) {
        case kVK_Return: return @"↩";
        case kVK_Tab: return @"⇥";
        case kVK_Space: return @"Space";
        case kVK_Delete: return @"⌫";
        case kVK_ForwardDelete: return @"⌦";
        case kVK_Escape: return @"⎋";
        case kVK_LeftArrow: return @"←";
        case kVK_RightArrow: return @"→";
        case kVK_DownArrow: return @"↓";
        case kVK_UpArrow: return @"↑";
        case kVK_Home: return @"↖";
        case kVK_End: return @"↘";
        case kVK_PageUp: return @"⇞";
        case kVK_PageDown: return @"⇟";
        case kVK_Help: return @"Help";
        case kVK_ANSI_KeypadEnter: return @"⌤";
        case kVK_ANSI_KeypadClear: return @"⌧";
        case kVK_ANSI_KeypadDecimal: return @".";
        case kVK_ANSI_KeypadMultiply: return @"*";
        case kVK_ANSI_KeypadPlus: return @"+";
        case kVK_ANSI_KeypadDivide: return @"/";
        case kVK_ANSI_KeypadMinus: return @"-";
        case kVK_ANSI_KeypadEquals: return @"=";
        case kVK_ANSI_Keypad0: return @"0";
        case kVK_ANSI_Keypad1: return @"1";
        case kVK_ANSI_Keypad2: return @"2";
        case kVK_ANSI_Keypad3: return @"3";
        case kVK_ANSI_Keypad4: return @"4";
        case kVK_ANSI_Keypad5: return @"5";
        case kVK_ANSI_Keypad6: return @"6";
        case kVK_ANSI_Keypad7: return @"7";
        case kVK_ANSI_Keypad8: return @"8";
        case kVK_ANSI_Keypad9: return @"9";
        case kVK_F1: return @"F1";
        case kVK_F2: return @"F2";
        case kVK_F3: return @"F3";
        case kVK_F4: return @"F4";
        case kVK_F5: return @"F5";
        case kVK_F6: return @"F6";
        case kVK_F7: return @"F7";
        case kVK_F8: return @"F8";
        case kVK_F9: return @"F9";
        case kVK_F10: return @"F10";
        case kVK_F11: return @"F11";
        case kVK_F12: return @"F12";
        case kVK_F13: return @"F13";
        case kVK_F14: return @"F14";
        case kVK_F15: return @"F15";
        case kVK_F16: return @"F16";
        case kVK_F17: return @"F17";
        case kVK_F18: return @"F18";
        case kVK_F19: return @"F19";
        case kVK_F20: return @"F20";
        default:
            break;
    }

    return [self rc_translatedStringForKeyCode:keyCode modifiers:modifiers];
}

+ (NSString *)rc_translatedStringForKeyCode:(UInt16)keyCode modifiers:(NSEventModifierFlags)modifiers {
    TISInputSourceRef inputSource = TISCopyCurrentKeyboardLayoutInputSource();
    CFDataRef layoutData = NULL;
    if (inputSource != NULL) {
        layoutData = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData);
    }
    if (layoutData == NULL || CFDataGetLength(layoutData) == 0) {
        if (inputSource != NULL) {
            CFRelease(inputSource);
        }
        inputSource = TISCopyCurrentASCIICapableKeyboardLayoutInputSource();
        if (inputSource != NULL) {
            layoutData = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData);
        }
    }
    if (layoutData == NULL || CFDataGetLength(layoutData) == 0) {
        if (inputSource != NULL) {
            CFRelease(inputSource);
        }
        return @"";
    }

    const UCKeyboardLayout *keyboardLayout = (const UCKeyboardLayout *)CFDataGetBytePtr(layoutData);
    if (keyboardLayout == NULL) {
        if (inputSource != NULL) {
            CFRelease(inputSource);
        }
        return @"";
    }

    UInt32 deadKeyState = 0;
    UniChar characters[8];
    UniCharCount length = 0;
    // Modifier glyphs are already shown separately; translate the base key.
    NSEventModifierFlags displayModifiers = 0;
    UInt32 carbonModifiers = [RCHotKeyService carbonModifiersFromCocoaModifiers:displayModifiers];
    UInt32 modifierKeyState = (carbonModifiers >> 8) & 0xFF;

    OSStatus status = UCKeyTranslate(keyboardLayout,
                                     keyCode,
                                     kUCKeyActionDisplay,
                                     modifierKeyState,
                                     LMGetKbdType(),
                                     kUCKeyTranslateNoDeadKeysBit,
                                     &deadKeyState,
                                     (UniCharCount)(sizeof(characters) / sizeof(characters[0])),
                                     &length,
                                     characters);

    if (length > 0 && characters[0] < 0x0020) {
        deadKeyState = 0;
        length = 0;
        status = UCKeyTranslate(keyboardLayout,
                                keyCode,
                                kUCKeyActionDisplay,
                                0,
                                LMGetKbdType(),
                                kUCKeyTranslateNoDeadKeysBit,
                                &deadKeyState,
                                (UniCharCount)(sizeof(characters) / sizeof(characters[0])),
                                &length,
                                characters);
    }

    if (inputSource != NULL) {
        CFRelease(inputSource);
    }

    if (status != noErr || length == 0) {
        return @"";
    }

    NSString *translated = [[NSString alloc] initWithCharacters:characters length:(NSUInteger)length];
    translated = [translated stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (translated.length == 0) {
        return @"";
    }

    return translated.localizedUppercaseString;
}

@end
