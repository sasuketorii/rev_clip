#import <XCTest/XCTest.h>
#import "RCHotKeyRecorderView.h"
#import "RCMenuManager.h"
@interface RCMenuManager (ShortcutDisplayTesting)
- (void)appendApplicationSectionToMenu:(NSMenu *)menu;
- (NSDictionary *)menuPreferenceSnapshot;
@end
@interface RCShortcutDisplayTests : XCTestCase
@end
@implementation RCShortcutDisplayTests
- (void)testModifiersDoNotTransformTheDisplayedBaseKey {
    XCTAssertEqualObjects([RCHotKeyRecorderView displayStringForKeyCombo:RCMakeKeyCombo(kVK_ANSI_2, cmdKey | shiftKey)], @"⇧⌘2");
    XCTAssertEqualObjects([RCHotKeyRecorderView displayStringForKeyCombo:RCMakeKeyCombo(kVK_ANSI_V, cmdKey | shiftKey)], @"⇧⌘V");
    XCTAssertEqualObjects([RCHotKeyRecorderView displayStringForKeyCombo:RCMakeKeyCombo(kVK_ANSI_V, cmdKey | optionKey)], @"⌥⌘V");
    XCTAssertEqualObjects([RCHotKeyRecorderView displayStringForKeyCombo:RCInvalidKeyCombo()], @"");
    XCTAssertEqualObjects([RCHotKeyRecorderView keyEquivalentForKeyCombo:RCMakeKeyCombo(0, 0)], @"");
}
- (void)testFunctionKeysAndCustomMenuModifierLabels {
    RCKeyCombo combo = RCMakeKeyCombo(kVK_F5, controlKey | optionKey);
    NSString *key = [RCHotKeyRecorderView keyEquivalentForKeyCombo:combo];
    XCTAssertEqual([key characterAtIndex:0], NSF5FunctionKey);
    XCTAssertEqualObjects([RCHotKeyRecorderView displayStringForKeyEquivalent:key modifiers:[RCHotKeyService cocoaModifiersFromCarbonModifiers:combo.modifiers]], @"⌃⌥F5");
    XCTAssertEqualObjects([RCHotKeyRecorderView displayStringForKeyEquivalent:@"2" modifiers:NSEventModifierFlagCommand | NSEventModifierFlagShift], @"⇧⌘2");
}
- (void)testOCRMenuFollowsSavedShortcutAndExplicitClear {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id saved = [defaults objectForKey:@"RCOCRKeyCombo"], enabled = [defaults objectForKey:@"RCOCREnabled"];
    @try {
        [defaults setBool:YES forKey:@"RCOCREnabled"];
        RCMenuManager *manager = [RCMenuManager new];
        for (NSDictionary *value in @[@{@"keyCode":@19,@"modifiers":@(cmdKey|shiftKey)}, @{@"keyCode":@11,@"modifiers":@(cmdKey|controlKey)}, @{@"keyCode":@0,@"modifiers":@0}]) {
            NSDictionary *before = [manager menuPreferenceSnapshot];
            [defaults setObject:value forKey:@"RCOCRKeyCombo"];
            XCTAssertEqualObjects([manager menuPreferenceSnapshot][@"RCOCRKeyCombo"], value);
            if (![before[@"RCOCRKeyCombo"] isEqual:value]) XCTAssertNotEqualObjects(before, [manager menuPreferenceSnapshot]);
            NSMenu *menu = [NSMenu new]; [manager appendApplicationSectionToMenu:menu];
            NSMenuItem *item = menu.itemArray.firstObject;
            XCTAssertEqual(item.action, NSSelectorFromString(@"invokeOCR:"));
            NSString *expected = [value[@"modifiers"] unsignedIntValue] == 0 ? @"" : [value[@"keyCode"] intValue] == 19 ? @"2" : @"b";
            XCTAssertEqualObjects(item.keyEquivalent, expected);
            if (expected.length) XCTAssertEqual(item.keyEquivalentModifierMask, [RCHotKeyService cocoaModifiersFromCarbonModifiers:[value[@"modifiers"] unsignedIntValue]]);
        }
    } @finally {
        if (saved) [defaults setObject:saved forKey:@"RCOCRKeyCombo"]; else [defaults removeObjectForKey:@"RCOCRKeyCombo"];
        if (enabled) [defaults setObject:enabled forKey:@"RCOCREnabled"]; else [defaults removeObjectForKey:@"RCOCREnabled"];
    }
}
@end
