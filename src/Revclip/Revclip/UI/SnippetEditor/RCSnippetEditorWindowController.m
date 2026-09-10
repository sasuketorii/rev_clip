//
//  RCSnippetEditorWindowController.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import "RCSnippetEditorWindowController.h"

#import "Revclip-Swift.h"

@interface RCSnippetEditorWindowController ()
@property (nonatomic, strong) RCSnippetEditorHost *editorHost;
@end

@implementation RCSnippetEditorWindowController

+ (instancetype)shared {
    static RCSnippetEditorWindowController *sharedController = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedController = [[self alloc] init];
    });
    return sharedController;
}

- (instancetype)init {
    self = [super initWithWindowNibName:@"RCSnippetEditorWindow"];
    return self;
}

- (void)windowDidLoad {
    [super windowDidLoad];

    NSWindow *window = self.window;
    window.title = NSLocalizedString(@"Template Editor", nil);
    window.styleMask = NSWindowStyleMaskTitled
                     | NSWindowStyleMaskClosable
                     | NSWindowStyleMaskMiniaturizable
                     | NSWindowStyleMaskResizable
                     | NSWindowStyleMaskFullSizeContentView;
    window.titlebarAppearsTransparent = YES;
    window.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace;
    window.releasedWhenClosed = NO;
    window.minSize = NSMakeSize(760.0, 520.0);
    [window setContentSize:NSMakeSize(960.0, 640.0)];
    self.editorHost = [RCSnippetEditorHost installInWindow:window];
}

- (BOOL)saveChangesIfLoaded {
    return !self.isWindowLoaded || [self.editorHost saveChanges];
}

- (void)reloadIfLoaded {
    if (self.isWindowLoaded) { [self.editorHost reload]; }
}

- (void)showWindow:(id)sender {
    if (!self.window.isVisible) {
        [self.editorHost reload];
    }
    [super showWindow:sender];
    [self.window center];
    [self.window makeKeyAndOrderFront:sender];
    [NSApp activateIgnoringOtherApps:YES];
}

@end
