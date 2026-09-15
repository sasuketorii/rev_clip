#import <XCTest/XCTest.h>
#import "RCAgentPreferencesViewController.h"
#import "RCLocalization.h"

@interface RCAgentPreferencesViewController (Testing)
+ (NSString *)shellQuotedArgument:(NSString *)argument;
+ (NSString *)installationPromptForBundleURL:(NSURL *)bundleURL appName:(NSString *)appName;
- (NSPasteboard *)promptPasteboard;
- (IBAction)copyPrompt:(id)sender;
@property (nonatomic, strong) NSTextView *promptField;
@property (nonatomic, strong) NSTextField *promptCopyStatus;
@end

@interface RCAgentPreferencesProbe : RCAgentPreferencesViewController
@property (nonatomic, strong) NSPasteboard *isolatedPasteboard;
@end
@implementation RCAgentPreferencesProbe
- (NSPasteboard *)promptPasteboard { return self.isolatedPasteboard; }
@end

@interface RCAgentPreferencesTests : XCTestCase
@end

@implementation RCAgentPreferencesTests

- (void)testShellQuotingPreservesApostrophesAndShellMetacharacters {
    XCTAssertEqualObjects([RCAgentPreferencesViewController shellQuotedArgument:@""], @"''");
    XCTAssertEqualObjects([RCAgentPreferencesViewController shellQuotedArgument:@"/Volumes/O'Brien/$HOME `whoami`; Demo.app"],
                          @"'/Volumes/O'\"'\"'Brien/$HOME `whoami`; Demo.app'");
}

- (void)testRelocatedBundleProducesInspectInstallInspectWithMetadataTarget {
    NSURL *url = [NSURL fileURLWithPath:@"/Volumes/O'Brien/日本語 Test/Renamed.app" isDirectory:YES];
    NSString *prompt = [RCAgentPreferencesViewController installationPromptForBundleURL:url appName:@"revclip-demo"];
    NSString *command = @"'/Volumes/O'\"'\"'Brien/日本語 Test/Renamed.app/Contents/Helpers/revclip' agent";
    NSString *expected = [NSString stringWithFormat:@"```sh\n%@ inspect --app 'revclip-demo'\n%@ install --app 'revclip-demo'\n%@ inspect --app 'revclip-demo'\n```", command, command, command];
    XCTAssertTrue([prompt containsString:expected]);
    XCTAssertFalse([prompt containsString:@"/Applications/"]);
    XCTAssertFalse([prompt containsString:@"--force"]);
}

- (void)testAppTargetUsesMetadataWithFallbackAndIsNotInferredFromBundleFilename {
    NSURL *url = [NSURL fileURLWithPath:@"/tmp/revclip-demo.app" isDirectory:YES];
    NSString *release = [RCAgentPreferencesViewController installationPromptForBundleURL:url appName:@"Revclip"];
    XCTAssertTrue([release containsString:@"install --app 'Revclip'"]);
    NSString *fallback = [RCAgentPreferencesViewController installationPromptForBundleURL:url appName:@""];
    XCTAssertTrue([fallback containsString:@"install --app 'Revclip'"]);
    NSString *custom = [RCAgentPreferencesViewController installationPromptForBundleURL:url appName:@"Custom Agent App"];
    XCTAssertTrue([custom containsString:@"install --app 'Custom Agent App'"]);
    NSString *quoted = [RCAgentPreferencesViewController installationPromptForBundleURL:url appName:@"Revclip'; touch bad"];
    XCTAssertTrue([quoted containsString:@"install --app 'Revclip'\"'\"'; touch bad'"]);
}

- (void)testCopyActionCopiesExactlyDisplayedTextWithoutUsingGeneralPasteboard {
    [NSApplication sharedApplication];
    RCAgentPreferencesProbe *controller = [RCAgentPreferencesProbe new];
    controller.isolatedPasteboard = [NSPasteboard pasteboardWithUniqueName];
    @try {
        (void)controller.view;
        NSString *displayed = controller.promptField.string;
        XCTAssertTrue(controller.promptField.selectable);
        XCTAssertFalse(controller.promptField.editable);
        [controller copyPrompt:nil];
        XCTAssertEqualObjects([controller.isolatedPasteboard stringForType:NSPasteboardTypeString], displayed);
        XCTAssertEqualObjects(controller.promptCopyStatus.stringValue, RCLocalizedString(@"Prompt copied. Paste it into your agent.", nil));
        // A second copy must use the currently displayed value, never a regenerated prompt.
        controller.promptField.string = @"Displayed 日本語\n```sh\nquoted 'path'\n```";
        [controller copyPrompt:nil];
        XCTAssertEqualObjects([controller.isolatedPasteboard stringForType:NSPasteboardTypeString], controller.promptField.string);
    } @finally {
        [controller.isolatedPasteboard releaseGlobally];
    }
}

- (void)testDocumentFitsNarrowHostAndScrollsToBottomAfterLanguageRefresh {
    [NSApplication sharedApplication];
    RCAgentPreferencesViewController *controller = [RCAgentPreferencesViewController new];
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 860, 520)
                                                styleMask:NSWindowStyleMaskTitled
                                                  backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(200, 0, 660, 480)];
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = NO;
    [window.contentView addSubview:scroll];
    NSView *document = controller.view;
    document.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = document;
    NSClipView *clip = scroll.contentView;
    [NSLayoutConstraint activateConstraints:@[
        [document.widthAnchor constraintEqualToAnchor:clip.widthAnchor],
        [document.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor],
        [document.topAnchor constraintEqualToAnchor:clip.topAnchor],
    ]];
    for (NSNumber *width in @[@660, @580, @1000]) {
        [scroll setFrameSize:NSMakeSize(width.doubleValue, 480)];
        [window.contentView layoutSubtreeIfNeeded];
        XCTAssertTrue(document.isFlipped);
        XCTAssertEqualWithAccuracy(document.frame.size.width, clip.bounds.size.width, 1);
        NSView *content = document.subviews.firstObject;
        XCTAssertLessThanOrEqual(content.frame.size.width, 680.5);
        XCTAssertGreaterThanOrEqual(content.frame.origin.x, 23.5);
        XCTAssertGreaterThan(document.frame.size.height, clip.bounds.size.height);
        NSScrollView *promptScroll = controller.promptField.enclosingScrollView;
        XCTAssertEqualWithAccuracy(promptScroll.frame.size.height, 260, 1);
        XCTAssertFalse(promptScroll.hasHorizontalScroller);
        XCTAssertTrue(controller.promptField.textContainer.widthTracksTextView);
        XCTAssertLessThan(document.frame.size.height, 1200);
        [controller.promptField.layoutManager ensureLayoutForTextContainer:controller.promptField.textContainer];
        [controller.promptField scrollRangeToVisible:NSMakeRange(controller.promptField.string.length, 0)];
        XCTAssertGreaterThan(promptScroll.contentView.bounds.origin.y, 0);
        XCTAssertLessThanOrEqual(NSMaxX(controller.promptField.frame), controller.promptField.superview.bounds.size.width);
    }
    [NSNotificationCenter.defaultCenter postNotificationName:RCLanguageDidChangeNotification object:nil];
    [window.contentView layoutSubtreeIfNeeded];
    XCTAssertEqual(scroll.documentView, document);
    XCTAssertEqual(document.subviews.count, 1u);
    CGFloat shortPromptHeight = document.frame.size.height;
    controller.promptField.string = [@"長いプロンプト / A long translated prompt\n" stringByPaddingToLength:20000
                                                                                            withString:@"長いプロンプト / A long translated prompt\n"
                                                                                       startingAtIndex:0];
    [window.contentView layoutSubtreeIfNeeded];
    XCTAssertEqualWithAccuracy(document.frame.size.height, shortPromptHeight, 1);
    [document scrollPoint:NSMakePoint(0, document.bounds.size.height)];
    XCTAssertGreaterThan(clip.bounds.origin.y, 0);
    [window close];
}

- (void)testCopyFailureProvidesSelectableFallback {
    [NSApplication sharedApplication];
    RCAgentPreferencesProbe *controller = [RCAgentPreferencesProbe new];
    (void)controller.view;
    // An unavailable pasteboard deterministically exercises the failed-write branch.
    [controller copyPrompt:nil];
    XCTAssertEqualObjects(controller.promptCopyStatus.stringValue,
                         RCLocalizedString(@"Could not copy the prompt. Select and copy the text below.", nil));
    XCTAssertTrue(controller.promptField.selectable);
}

- (void)testEightProviderIconsHaveNamedAssetsAndFixedSize {
    [NSApplication sharedApplication];
    RCAgentPreferencesViewController *controller = [RCAgentPreferencesViewController new];
    NSMutableSet<NSString *> *names = [NSMutableSet set];
    NSMutableArray<NSView *> *pending = [NSMutableArray arrayWithObject:controller.view];
    NSUInteger pairs = 0;
    while (pending.count) {
        NSView *row = pending.lastObject;
        [pending removeLastObject];
        if ([row.identifier isEqualToString:@"agentProviderPair"]) {
            pairs++;
            XCTAssertEqual(((NSStackView *)row).arrangedSubviews.count, 2u);
        }
        [pending addObjectsFromArray:row.subviews];
        for (NSView *child in row.subviews) {
            if ([child isKindOfClass:NSTextField.class]) {
                XCTAssertNotEqualObjects(((NSTextField *)child).stringValue, RCLocalizedString(@"Agent Settings", nil));
            }
            if (![child isKindOfClass:NSImageView.class]) { continue; }
            NSImageView *icon = (NSImageView *)child;
            [names addObject:icon.identifier];
            XCTAssertEqualObjects(icon.contentTintColor, NSColor.labelColor);
            BOOL width = NO, height = NO;
            for (NSLayoutConstraint *constraint in icon.constraints) {
                width |= constraint.firstAttribute == NSLayoutAttributeWidth && constraint.constant == 18;
                height |= constraint.firstAttribute == NSLayoutAttributeHeight && constraint.constant == 18;
            }
            XCTAssertTrue(width && height);
        }
    }
    XCTAssertEqual(pairs, 4u);
    NSSet *expectedNames = [NSSet setWithArray:@[@"Agent-openai", @"Agent-claude", @"Agent-gemini",
        @"Agent-cursor", @"Agent-grok", @"Agent-kimi", @"Agent-hermes", @"Agent-deepseek"]];
    XCTAssertEqualObjects(names, expectedNames);
}

@end
