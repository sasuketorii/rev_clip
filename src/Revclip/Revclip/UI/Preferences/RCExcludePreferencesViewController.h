//
//  RCExcludePreferencesViewController.h
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface RCExcludePreferencesViewController : NSViewController

/// Tracks the previously active application so "Add Current App" can exclude
/// the last non-Revclip app that was in the foreground.
@property (nonatomic, strong, nullable) NSRunningApplication *previousActiveApplication;

@end

NS_ASSUME_NONNULL_END
