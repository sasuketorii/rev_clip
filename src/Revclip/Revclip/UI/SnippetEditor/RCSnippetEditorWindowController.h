//
//  RCSnippetEditorWindowController.h
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface RCSnippetEditorWindowController : NSWindowController

+ (instancetype)shared;
- (void)showWindow:(nullable id)sender;
- (BOOL)saveChangesIfLoaded;
- (void)reloadIfLoaded;

@end

NS_ASSUME_NONNULL_END
