//
//  RCHotKeyRecorderView.h
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
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

- (void)startRecording;
- (void)stopRecording;
- (void)clearKeyCombo;

@end

NS_ASSUME_NONNULL_END
