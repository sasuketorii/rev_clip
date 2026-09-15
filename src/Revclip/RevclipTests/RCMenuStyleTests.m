#import <XCTest/XCTest.h>
#import "RCMenuStyle.h"
@interface RCMenuStyleTests : XCTestCase
@property NSDictionary *saved;
@property id enabled;
@property XCTestExpectation *activation;
@end
@implementation RCMenuStyleTests
- (void)setUp {
    self.saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:RCMenuStyle.paletteKey];
    self.enabled = [NSUserDefaults.standardUserDefaults objectForKey:@"RCMenuCustomColorsEnabled"];
}
- (void)tearDown {
    if (self.saved) [NSUserDefaults.standardUserDefaults setObject:self.saved forKey:RCMenuStyle.paletteKey];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:RCMenuStyle.paletteKey];
    if (self.enabled) [NSUserDefaults.standardUserDefaults setObject:self.enabled forKey:@"RCMenuCustomColorsEnabled"];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:@"RCMenuCustomColorsEnabled"];
}
- (void)testInvalidColorsFallBackAndValidColorHasFixedAlpha {
    for (id value in @[@"#12345Z", @"#fff", @"#00000000", @"garbage", @7]) {
        [NSUserDefaults.standardUserDefaults setObject:@{@"text":value} forKey:RCMenuStyle.paletteKey];
        XCTAssertNil([RCMenuStyle colorForKey:@"text"]);
    }
    [NSUserDefaults.standardUserDefaults setObject:@{@"text":@"#FF005E"} forKey:RCMenuStyle.paletteKey];
    NSColor *color = [[RCMenuStyle colorForKey:@"text"] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    XCTAssertEqualWithAccuracy(color.redComponent, 1, 0.001);
    XCTAssertEqualWithAccuracy(color.blueComponent, 94.0/255, 0.001);
    XCTAssertEqual(color.alphaComponent, 1);
}
- (void)testStylingKeepsNativeActionSubmenuAndMediaAndResetRestoresNativeView {
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"RCMenuCustomColorsEnabled"];
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"Test\nWrapped" action:@selector(description) keyEquivalent:@"k"];
    item.target = self;
    item.submenu = [[NSMenu alloc] initWithTitle:@"Child"];
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(16,16)];
    item.image = image;
    [RCMenuStyle applyToItem:item];
    NSView *view = item.view;
    XCTAssertNotNil(view);
    XCTAssertNil([view hitTest:NSMakePoint(5,5)]);
    XCTAssertEqual(item.target, self);
    XCTAssertEqual(item.action, @selector(description));
    XCTAssertNotNil(item.submenu);
    XCTAssertEqual(item.image, image);
    XCTAssertFalse(image.isTemplate);
    [RCMenuStyle applyToItem:item];
    XCTAssertEqual(view, item.view);
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"RCMenuCustomColorsEnabled"];
    [RCMenuStyle applyToItem:item];
    XCTAssertNil(item.view);
    XCTAssertEqualObjects(item.title, @"Test\nWrapped");
}
- (void)menuAction:(id)sender { [self.activation fulfill]; }
- (void)testAccessibleActivationDispatchesExistingActionAndDisabledItemDoesNot {
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"RCMenuCustomColorsEnabled"];
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"Activate" action:@selector(menuAction:) keyEquivalent:@""];
    item.target = self;
    [RCMenuStyle applyToItem:item];
    item.enabled = NO;
    XCTAssertFalse([item.view accessibilityPerformPress]);
    item.enabled = YES;
    self.activation = [self expectationWithDescription:@"menu action"];
    self.activation.assertForOverFulfill = YES;
    XCTAssertTrue([item.view accessibilityPerformPress]);
    [self waitForExpectations:@[self.activation] timeout:1];
}
@end
