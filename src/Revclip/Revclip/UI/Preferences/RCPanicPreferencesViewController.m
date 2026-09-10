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
    NSTextField *titleLabel = [self createLabel:@"パニック消去" bold:YES fontSize:16.0];
    [container addSubview:titleLabel];

    // Description label
    NSTextField *descriptionLabel = [self createWrappingLabel:
        @"すべてのクリップボード履歴、テンプレート、設定を完全に削除してアプリを終了します。\nこの操作は取り消せません。"];
    [container addSubview:descriptionLabel];

    // Separator
    NSBox *separator = [[NSBox alloc] init];
    separator.boxType = NSBoxSeparator;
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:separator];

    // Input label
    NSTextField *inputLabel = [self createLabel:@"確認のため「Panic」と入力してください：" bold:NO fontSize:13.0];
    [container addSubview:inputLabel];

    // Confirmation text field
    self.confirmationTextField = [[NSTextField alloc] init];
    self.confirmationTextField.translatesAutoresizingMaskIntoConstraints = NO;
    self.confirmationTextField.placeholderString = @"Panic";
    self.confirmationTextField.bezelStyle = NSTextFieldRoundedBezel;
    self.confirmationTextField.font = [NSFont systemFontOfSize:13.0];
    [container addSubview:self.confirmationTextField];

    // Erase button
    self.eraseButton = [NSButton buttonWithTitle:@"全データ削除" target:self action:@selector(eraseButtonClicked:)];
    self.eraseButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.eraseButton.bezelStyle = NSBezelStyleRegularSquare;
    self.eraseButton.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightMedium];
    self.eraseButton.contentTintColor = [NSColor systemRedColor];
    self.eraseButton.controlSize = NSControlSizeRegular;
    [container addSubview:self.eraseButton];

    // Layout constraints
    [NSLayoutConstraint activateConstraints:@[
        // Warning icon
        [warningIcon.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20.0],
        [warningIcon.topAnchor constraintEqualToAnchor:container.topAnchor constant:20.0],
        [warningIcon.widthAnchor constraintEqualToConstant:24.0],
        [warningIcon.heightAnchor constraintEqualToConstant:24.0],

        // Title label (next to icon)
        [titleLabel.leadingAnchor constraintEqualToAnchor:warningIcon.trailingAnchor constant:8.0],
        [titleLabel.centerYAnchor constraintEqualToAnchor:warningIcon.centerYAnchor],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-20.0],

        // Description label
        [descriptionLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20.0],
        [descriptionLabel.topAnchor constraintEqualToAnchor:warningIcon.bottomAnchor constant:16.0],
        [descriptionLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-20.0],

        // Separator
        [separator.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20.0],
        [separator.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-20.0],
        [separator.topAnchor constraintEqualToAnchor:descriptionLabel.bottomAnchor constant:16.0],

        // Input label
        [inputLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20.0],
        [inputLabel.topAnchor constraintEqualToAnchor:separator.bottomAnchor constant:16.0],
        [inputLabel.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-20.0],

        // Confirmation text field
        [self.confirmationTextField.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20.0],
        [self.confirmationTextField.topAnchor constraintEqualToAnchor:inputLabel.bottomAnchor constant:8.0],
        [self.confirmationTextField.widthAnchor constraintEqualToConstant:200.0],

        // Erase button
        [self.eraseButton.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20.0],
        [self.eraseButton.topAnchor constraintEqualToAnchor:self.confirmationTextField.bottomAnchor constant:16.0],
        [self.eraseButton.widthAnchor constraintGreaterThanOrEqualToConstant:120.0],
    ]];
}

- (NSImageView *)createWarningIcon {
    NSImageView *imageView = [[NSImageView alloc] init];
    imageView.translatesAutoresizingMaskIntoConstraints = NO;

    NSImage *warningImage = [NSImage imageWithSystemSymbolName:@"exclamationmark.triangle.fill"
                                     accessibilityDescription:@"警告"];
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
        alert.messageText = @"入力が正しくありません";
        alert.informativeText = @"確認のため「Panic」と正確に入力してください。";
        alert.alertStyle = NSAlertStyleWarning;
        [alert addButtonWithTitle:@"OK"];
        [alert beginSheetModalForWindow:self.view.window completionHandler:nil];
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"最終確認";
    alert.informativeText = @"すべてのクリップボード履歴、テンプレート、設定が完全に削除されます。アプリは終了します。\n\nこの操作は取り消せません。";
    alert.alertStyle = NSAlertStyleCritical;
    [alert addButtonWithTitle:@"全データ削除して終了"];
    [alert addButtonWithTitle:@"キャンセル"];

    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse returnCode) {
        if (returnCode == NSAlertFirstButtonReturn) {
            [[RCPanicEraseService shared] executePanicEraseWithCompletion:nil];
        }
    }];
}

@end
