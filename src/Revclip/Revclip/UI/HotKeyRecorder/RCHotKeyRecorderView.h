//
//  RCHotKeyRecorderView.h
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Current project: AGPL-3.0-only; legacy portions: MIT. See THIRD_PARTY_NOTICES.md.
//

#import <Cocoa/Cocoa.h>

#import "RCHotKeyService.h"

NS_ASSUME_NONNULL_BEGIN

@class RCHotKeyRecorderView;

@protocol RCHotKeyRecorderViewDelegate <NSObject>

- (void)hotKeyRecorderView:(RCHotKeyRecorderView *)recorderView didRecordKeyCombo:(RCKeyCombo)keyCombo;
- (void)hotKeyRecorderViewDidClearKeyCombo:(RCHotKeyRecorderView *)recorderView;

@end

IB_DESIGNABLE
@interface RCHotKeyRecorderView : NSView

@property (nonatomic, weak) IBOutlet id<RCHotKeyRecorderViewDelegate> delegate;
@property (nonatomic, assign) RCKeyCombo keyCombo;
@property (nonatomic, readonly) BOOL isRecording;
@property (nonatomic, weak, nullable) NSTextField *warningLabel;
- (void)showAssignmentResult:(RCHotKeyAssignmentResult *)result;

+ (NSString *)displayStringForKeyCombo:(RCKeyCombo)combo;
+ (NSString *)keyEquivalentForKeyCombo:(RCKeyCombo)combo;
+ (NSString *)displayStringForKeyEquivalent:(NSString *)key modifiers:(NSEventModifierFlags)modifiers;

// Shared wording for a refused shortcut, used by every recorder page. Names only what
// Revclip can know: its own feature, an enabled macOS shortcut, or an OS refusal.
+ (NSString *)localizedNameForSlot:(NSString *)slot;
+ (NSString *)messageForAssignmentResult:(RCHotKeyAssignmentResult *)result;

- (void)startRecording;
- (void)stopRecording;
- (void)clearKeyCombo;

@end

NS_ASSUME_NONNULL_END
