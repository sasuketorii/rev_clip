//
//  RCPreferencesWindowController.h
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface RCPreferencesWindowController : NSWindowController

+ (instancetype)shared;
- (void)showWindow:(nullable id)sender;
- (void)showTab:(NSString *)tabIdentifier;

@end

// Tab identifiers
extern NSString * const RCPreferencesTabGeneral;
extern NSString * const RCPreferencesTabMenu;
extern NSString * const RCPreferencesTabType;
extern NSString * const RCPreferencesTabExclude;
extern NSString * const RCPreferencesTabShortcuts;
extern NSString * const RCPreferencesTabUpdates;
extern NSString * const RCPreferencesTabBeta;
extern NSString * const RCPreferencesTabPanic;

NS_ASSUME_NONNULL_END
