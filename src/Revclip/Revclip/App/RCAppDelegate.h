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

@end
