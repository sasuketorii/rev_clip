//
//  RCHotKeyRecorderView.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
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

- (void)rc_commonInit;
- (BOOL)rc_shouldWarnForModifiers:(UInt32)modifiers;
- (void)rc_showUnsupportedOptionWarning;
- (NSString *)rc_displayText;
- (NSString *)rc_stringFromKeyCombo:(RCKeyCombo)keyCombo;
- (NSString *)rc_symbolStringFromModifiers:(NSEventModifierFlags)modifiers;
- (NSString *)rc_stringForKeyCode:(UInt16)keyCode modifiers:(NSEventModifierFlags)modifiers;
- (NSString *)rc_translatedStringForKeyCode:(UInt16)keyCode modifiers:(NSEventModifierFlags)modifiers;
- (void)processKeyEvent:(NSEvent *)event;

@end

@implementation RCHotKeyRecorderView

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

    self.isRecording = YES;
    self.recordingModifierFlags = 0;
    [self setNeedsDisplay:YES];
}

- (void)stopRecording {
    if (!self.isRecording) {
        return;
    }

    self.isRecording = NO;
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

    [self processKeyEvent:event];
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (self.isRecording) {
        [self processKeyEvent:event];
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
    if (@available(macOS 15.0, *)) {
        BOOL hasOption = (modifiers & optionKey) != 0;
        BOOL hasCommand = (modifiers & cmdKey) != 0;
        BOOL hasControl = (modifiers & controlKey) != 0;

        return hasOption && !hasCommand && !hasControl;
    }

    return NO;
}

- (void)rc_showUnsupportedOptionWarning {
    NSWindow *window = self.window;
    if (window == nil) {
        return;
    }
    if (window.attachedSheet != nil) {
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = NSLocalizedString(@"This shortcut may not work", nil);
    alert.informativeText = NSLocalizedString(@"On macOS 15 (Sequoia) and later, Option-only or Option+Shift-only modifier combinations are not supported due to system restrictions.\nPlease use a combination that includes Command or Control.", nil);
    [alert addButtonWithTitle:NSLocalizedString(@"OK", nil)];
    [alert beginSheetModalForWindow:window completionHandler:nil];
}

- (NSString *)rc_displayText {
    if (self.isRecording) {
        NSString *modifierText = [self rc_symbolStringFromModifiers:self.recordingModifierFlags];
        return (modifierText.length > 0) ? modifierText : NSLocalizedString(@"Type shortcut", nil);
    }

    if (RCIsValidKeyCombo(self.keyCombo)) {
        return [self rc_stringFromKeyCombo:self.keyCombo];
    }

    return NSLocalizedString(@"Click to record", nil);
}

- (NSString *)rc_stringFromKeyCombo:(RCKeyCombo)keyCombo {
    NSEventModifierFlags cocoaModifiers = [RCHotKeyService cocoaModifiersFromCarbonModifiers:keyCombo.modifiers];
    NSString *modifierText = [self rc_symbolStringFromModifiers:cocoaModifiers];
    NSString *keyText = [self rc_stringForKeyCode:(UInt16)keyCombo.keyCode modifiers:cocoaModifiers];

    if (keyText.length == 0) {
        keyText = [NSString stringWithFormat:@"%u", keyCombo.keyCode];
    }

    return [modifierText stringByAppendingString:keyText];
}

- (NSString *)rc_symbolStringFromModifiers:(NSEventModifierFlags)modifiers {
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

- (NSString *)rc_stringForKeyCode:(UInt16)keyCode modifiers:(NSEventModifierFlags)modifiers {
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

- (NSString *)rc_translatedStringForKeyCode:(UInt16)keyCode modifiers:(NSEventModifierFlags)modifiers {
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
    NSEventModifierFlags displayModifiers = modifiers & (NSEventModifierFlagShift | NSEventModifierFlagOption);
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
