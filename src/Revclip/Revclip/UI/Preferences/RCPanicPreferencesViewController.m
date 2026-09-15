#import "RCPreferencesPage.h"
#import "RCLocalization.h"
//
//  RCPanicPreferencesViewController.m
//  Revclip
//
//  Copyright (c) 2024-2026 Revclip. Licensed under the MIT License.
//

#import "RCPanicPreferencesViewController.h"
#import "RCPanicEraseService.h"

@interface RCPanicPreferencesViewController ()

@property (nonatomic, strong) NSTextField *confirmationTextField;
@property (nonatomic, strong) NSButton *eraseButton;

@end

@implementation RCPanicPreferencesViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self buildUI];
}

#pragma mark - UI Construction

- (void)buildUI {
    NSView *container = self.view;
    container.wantsLayer = YES;

    // Warning icon
    NSImageView *warningIcon = [self createWarningIcon];
    [container addSubview:warningIcon];

    // Title label
    NSTextField *titleLabel = [self createLabel:RCLocalizedString(@"Delete Revclip Data", nil) bold:YES fontSize:16.0];
    [container addSubview:titleLabel];

    // Description label
    NSTextField *descriptionLabel = [self createWrappingLabel:
        RCLocalizedString(@"This deletes clipboard history, templates, and settings stored by Revclip, clears the current clipboard, then quits Revclip. Other files on your Mac are not deleted. This cannot be undone.", nil)];
    [container addSubview:descriptionLabel];

    // Separator
    NSBox *separator = [[NSBox alloc] init];
    separator.boxType = NSBoxSeparator;
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:separator];

    // Input label
    NSTextField *inputLabel = [self createLabel:RCLocalizedString(@"Type \"Panic\" to confirm:", nil) bold:NO fontSize:13.0];
    [container addSubview:inputLabel];

    // Confirmation text field
    self.confirmationTextField = [[RCPreferencesTextField alloc] initWithFrame:NSZeroRect];
    self.confirmationTextField.translatesAutoresizingMaskIntoConstraints = NO;
    self.confirmationTextField.placeholderString = @"Panic";
    [self.confirmationTextField.heightAnchor constraintEqualToConstant:40].active = YES;
    self.confirmationTextField.font = [NSFont systemFontOfSize:13.0];
    [container addSubview:self.confirmationTextField];

    // Erase button
    self.eraseButton = [NSButton buttonWithTitle:RCLocalizedString(@"Delete All Revclip Data", nil) target:self action:@selector(eraseButtonClicked:)];
    self.eraseButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.eraseButton.bezelStyle = NSBezelStyleRegularSquare;
    self.eraseButton.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightMedium];
    self.eraseButton.bordered = NO;
    self.eraseButton.wantsLayer = YES;
    self.eraseButton.layer.backgroundColor = [NSColor colorWithSRGBRed:1.0 green:0.0 blue:94.0 / 255.0 alpha:1.0].CGColor;
    self.eraseButton.layer.cornerRadius = 18.0;
    self.eraseButton.contentTintColor = NSColor.whiteColor;
    self.eraseButton.attributedTitle = [[NSAttributedString alloc] initWithString:self.eraseButton.title
        attributes:@{NSForegroundColorAttributeName: NSColor.whiteColor,
                     NSFontAttributeName: self.eraseButton.font}];
    self.eraseButton.controlSize = NSControlSizeRegular;
    [container addSubview:self.eraseButton];

    [NSLayoutConstraint activateConstraints:@[
        [warningIcon.widthAnchor constraintEqualToConstant:24],
        [warningIcon.heightAnchor constraintEqualToConstant:24],
        [self.eraseButton.widthAnchor constraintEqualToConstant:MAX(120, ceil(self.eraseButton.attributedTitle.size.width) + 32)],
        [self.eraseButton.heightAnchor constraintEqualToConstant:36],
    ]];
    NSStackView *deleteActions = [NSStackView stackViewWithViews:@[self.eraseButton, [NSView new]]];
    self.view = [RCPreferencesPage pageWithRows:@[
        @[titleLabel.stringValue, warningIcon],
        @[descriptionLabel.stringValue],
        @[inputLabel.stringValue, self.confirmationTextField],
        @[@"", deleteActions],
    ]];

}

- (NSImageView *)createWarningIcon {
    NSImageView *imageView = [[NSImageView alloc] init];
    imageView.translatesAutoresizingMaskIntoConstraints = NO;

    NSImage *warningImage = [NSImage imageWithSystemSymbolName:@"exclamationmark.triangle.fill"
                                     accessibilityDescription:RCLocalizedString(@"Warning", nil)];
    if (warningImage != nil) {
        imageView.image = warningImage;
        imageView.contentTintColor = [NSColor systemOrangeColor];
    }
    imageView.imageScaling = NSImageScaleProportionallyUpOrDown;

    return imageView;
}

- (NSTextField *)createLabel:(NSString *)text bold:(BOOL)bold fontSize:(CGFloat)fontSize {
    NSTextField *label = [NSTextField labelWithString:text];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = bold ? [NSFont boldSystemFontOfSize:fontSize] : [NSFont systemFontOfSize:fontSize];
    label.textColor = [NSColor labelColor];
    label.selectable = NO;
    return label;
}

- (NSTextField *)createWrappingLabel:(NSString *)text {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [NSFont systemFontOfSize:13.0];
    label.textColor = [NSColor secondaryLabelColor];
    label.selectable = NO;
    return label;
}

#pragma mark - Actions

- (IBAction)eraseButtonClicked:(id)sender {
    (void)sender;

    NSString *typed = [self.confirmationTextField.stringValue
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (![typed isEqualToString:@"Panic"]) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = RCLocalizedString(@"Incorrect confirmation", nil);
        alert.informativeText = RCLocalizedString(@"Type \"Panic\" exactly to confirm.", nil);
        alert.alertStyle = NSAlertStyleWarning;
        [alert addButtonWithTitle:RCLocalizedString(@"OK", nil)];
        [alert beginSheetModalForWindow:self.view.window completionHandler:nil];
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = RCLocalizedString(@"Delete all Revclip data?", nil);
    alert.informativeText = RCLocalizedString(@"This deletes clipboard history, templates, and settings stored by Revclip, clears the current clipboard, then quits Revclip. Other files on your Mac are not deleted. This cannot be undone.", nil);
    alert.alertStyle = NSAlertStyleCritical;
    [alert addButtonWithTitle:RCLocalizedString(@"Delete Revclip Data and Quit", nil)];
    [alert addButtonWithTitle:RCLocalizedString(@"Cancel", nil)];

    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse returnCode) {
        if (returnCode == NSAlertFirstButtonReturn) {
            [[RCPanicEraseService shared] executePanicEraseWithCompletion:^(BOOL success) {
                if (success) return;
                NSAlert *failure = [NSAlert new];
                failure.alertStyle = NSAlertStyleWarning;
                failure.messageText = RCLocalizedString(@"Revclip data deletion incomplete", nil);
                failure.informativeText = RCLocalizedString(@"Not all Revclip data could be deleted. Clipboard recording is stopped. Some data may already have been deleted. Try the deletion again before quitting.", nil);
                [failure addButtonWithTitle:RCLocalizedString(@"OK", nil)];
                [failure beginSheetModalForWindow:self.view.window completionHandler:nil];
            }];
        }
    }];
}

@end
