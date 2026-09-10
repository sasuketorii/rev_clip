#import <XCTest/XCTest.h>
#import "RCMenuManager.h"
#import "RCClipItem.h"
#import "RCConstants.h"

@interface RCMenuManager (NativeTesting)
- (void)appendClipItems:(NSArray<RCClipItem *> *)items toMenu:(NSMenu *)menu;
- (void)appendApplicationSectionToMenu:(NSMenu *)menu;
- (void)appendSnippetDictionaries:(NSArray<NSDictionary *> *)snippets folderIdentifier:(NSString *)folder toMenu:(NSMenu *)menu;
@end

@interface RCNativeMenuTests : XCTestCase
@property NSDictionary *saved;
@end
@implementation RCNativeMenuTests
- (void)setUp {
    self.saved = NSUserDefaults.standardUserDefaults.dictionaryRepresentation;
    NSDictionary *values = @{kRCPrefNumberOfItemsPlaceInlineKey:@0, kRCPrefNumberOfItemsPlaceInsideFolderKey:@10,
        kRCMenuItemsAreMarkedWithNumbersKey:@YES, kRCPrefMenuItemsTitleStartWithZeroKey:@NO,
        kRCPrefShowIconInTheMenuKey:@YES, kRCShowToolTipOnMenuItemKey:@YES};
    [values enumerateKeysAndObjectsUsingBlock:^(id k,id v,BOOL *stop){[NSUserDefaults.standardUserDefaults setObject:v forKey:k];}];
}
- (void)tearDown {
    for (NSString *key in @[kRCPrefNumberOfItemsPlaceInlineKey,kRCPrefNumberOfItemsPlaceInsideFolderKey,
        kRCMenuItemsAreMarkedWithNumbersKey,kRCPrefMenuItemsTitleStartWithZeroKey,kRCPrefShowIconInTheMenuKey,kRCShowToolTipOnMenuItemKey]) {
        if (self.saved[key]) [NSUserDefaults.standardUserDefaults setObject:self.saved[key] forKey:key];
        else [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
    }
}
- (void)testNativeHistoryKeepsTenItemFoldersNumbersImagesAndHelp {
    NSMutableArray *clips = [NSMutableArray array];
    for (NSUInteger i=0;i<21;i++) {
        RCClipItem *clip = [RCClipItem new]; clip.title = @"本文"; clip.dataHash = [NSString stringWithFormat:@"fixture-%lu",i];
        clip.primaryType = NSPasteboardTypeString; [clips addObject:clip];
    }
    NSMenu *menu = [NSMenu new];
    RCMenuManager *manager = [RCMenuManager new];
    [manager appendClipItems:clips toMenu:menu];
    XCTAssertEqual(menu.numberOfItems,3);
    XCTAssertEqual(menu.itemArray[0].submenu.numberOfItems,10);
    XCTAssertEqual(menu.itemArray[1].submenu.numberOfItems,10);
    XCTAssertEqual(menu.itemArray[2].submenu.numberOfItems,1);
    NSMenuItem *first = menu.itemArray[0].submenu.itemArray[0];
    NSMenuItem *eleventh = menu.itemArray[1].submenu.itemArray[0];
    XCTAssertEqualObjects(first.title,@"1. 本文"); XCTAssertEqualObjects(eleventh.title,@"11. 本文");
    XCTAssertNil(first.toolTip); XCTAssertNil(first.view); XCTAssertNotNil(first.image); XCTAssertEqualObjects(first.accessibilityHelp,@"本文");
    XCTAssertEqual(first.action,NSSelectorFromString(@"selectClipMenuItem:")); XCTAssertEqual(first.target,manager);
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:kRCPrefMenuItemsTitleStartWithZeroKey];
    NSMenu *zero = [NSMenu new]; [manager appendClipItems:clips toMenu:zero];
    XCTAssertEqualObjects(zero.itemArray[0].submenu.itemArray[0].title,@"0. 本文");
}
- (void)testSnippetIdentifiersHelpAndAppActionsRemainNative {
    RCMenuManager *manager = [RCMenuManager new]; NSMenu *menu = [NSMenu new];
    [manager appendSnippetDictionaries:@[@{@"identifier":@"snippet-id",@"title":@"Snippet",@"content":@"body",@"enabled":@YES}]
                      folderIdentifier:@"folder-id" toMenu:menu];
    NSMenuItem *item = menu.itemArray.firstObject;
    XCTAssertNil(item.toolTip); XCTAssertNil(item.view); XCTAssertEqualObjects(item.accessibilityHelp,@"body"); XCTAssertNotNil(item.image);
    XCTAssertEqual(item.action,NSSelectorFromString(@"selectSnippetMenuItem:"));
    XCTAssertTrue([[item.representedObject allValues] containsObject:@"snippet-id"]);
    XCTAssertTrue([[item.representedObject allValues] containsObject:@"folder-id"]);
    [manager appendApplicationSectionToMenu:menu];
    NSMutableSet *actions = [NSMutableSet set];
    for (NSMenuItem *row in menu.itemArray) { XCTAssertNil(row.view); if(row.action) [actions addObject:NSStringFromSelector(row.action)]; }
    XCTAssertTrue([actions containsObject:@"openPreferences:"]); XCTAssertTrue([actions containsObject:@"openSnippetEditor:"]);
    XCTAssertTrue([actions containsObject:@"terminate:"]); XCTAssertEqual(menu.itemArray.lastObject.target,NSApp);
}
@end
