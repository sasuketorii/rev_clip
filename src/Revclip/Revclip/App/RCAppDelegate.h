//
//  RCAppDelegate.h
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Current project: AGPL-3.0-only; legacy portions: MIT. See THIRD_PARTY_NOTICES.md.
//

#import <Cocoa/Cocoa.h>

@interface RCAppDelegate : NSObject <NSApplicationDelegate>

- (IBAction)showPreferencesWindow:(id)sender;
- (IBAction)showPreferences:(id)sender;
- (IBAction)showSnippetEditor:(id)sender;
- (IBAction)importSnippets:(id)sender;
- (IBAction)exportSnippets:(id)sender;

// YES only for an open-application event with no launch property: the user opened
// Revclip (Finder, Launchpad, Spotlight, Dock). A login item launch, a Services launch,
// any other event and a missing event are not.
+ (BOOL)launchEventIsUserOpen:(nullable NSAppleEventDescriptor *)event;
// YES when Revclip relaunched itself at most five minutes before now.
+ (BOOL)selfRelaunchStamp:(NSTimeInterval)stamp coversLaunchAt:(NSTimeInterval)now;

// YES only for a launch macOS started to answer a Services request.
+ (BOOL)launchEventIndicatesService:(nullable NSAppleEventDescriptor *)event;

@end
