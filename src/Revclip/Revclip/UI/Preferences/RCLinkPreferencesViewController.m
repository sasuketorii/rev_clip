#import "RCLinkPreferencesViewController.h"
#import "RCLinkPreviewService.h"
#import "RCPreferencesPage.h"
#import "RCLocalization.h"

@interface RCLinkPreferencesViewController ()
@property (nonatomic, strong) NSPopUpButton *modePopup;
@end
@implementation RCLinkPreferencesViewController
- (void)loadView {
    self.modePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    NSArray *titles = @[@"Never fetch", @"Fetch on request", @"Fetch automatically"];
    for (NSUInteger index = 0; index < titles.count; index++) {
        [self.modePopup addItemWithTitle:RCLocalizedString(titles[index], nil)];
        self.modePopup.lastItem.tag = index;
    }
    self.modePopup.target = self;
    self.modePopup.action = @selector(modeChanged:);
    self.view = [RCPreferencesPage pageWithRows:@[
        @[RCLocalizedString(@"Link previews and website icons", nil), self.modePopup],
        @[RCLocalizedString(@"Fetching a preview connects to the website and may reveal your IP address and the full URL. Manual mode does not connect when you open a menu or hover over a link.", nil)],
        @[RCLocalizedString(@"In manual mode, hold Option while moving the pointer onto a link to fetch its preview. Choosing Never fetch also cancels pending requests and clears cached previews.", nil)],
    ]];
    [self refreshMode:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refreshMode:) name:NSUserDefaultsDidChangeNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)modeChanged:(NSPopUpButton *)sender { RCLinkPreviewService.shared.previewMode = sender.selectedItem.tag; }
- (void)refreshMode:(NSNotification *)notification {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self refreshMode:nil]; });
        return;
    }
    [self.modePopup selectItemWithTag:RCLinkPreviewService.shared.previewMode];
}
@end
