//
//  RCGeneralPreferencesViewController.h
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Current project: AGPL-3.0-only; legacy portions: MIT. See THIRD_PARTY_NOTICES.md.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface RCGeneralPreferencesViewController : NSViewController

@property (nonatomic, weak) IBOutlet NSSwitch *autoExpiryEnabledButton;
@property (nonatomic, weak) IBOutlet NSTextField *autoExpiryValueTextField;
@property (nonatomic, weak) IBOutlet NSStepper *autoExpiryValueStepper;
@property (nonatomic, weak) IBOutlet NSPopUpButton *autoExpiryUnitPopUpButton;

- (IBAction)autoExpiryEnabledChanged:(id)sender;
- (IBAction)autoExpiryValueTextFieldChanged:(id)sender;
- (IBAction)autoExpiryValueStepperChanged:(id)sender;
- (IBAction)autoExpiryUnitChanged:(id)sender;

@end

NS_ASSUME_NONNULL_END
