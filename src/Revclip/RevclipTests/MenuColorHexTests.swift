import XCTest
@testable import Revclip
final class MenuColorHexTests: XCTestCase {
    func testNormalization() {
        XCTAssertEqual(MenuColorHex.normalize("ff005e"), "#FF005E")
        XCTAssertEqual(MenuColorHex.normalize(" #aB12eF\n"), "#AB12EF")
        XCTAssertEqual(MenuColorHex.normalize("000000"), "#000000")
    }
    func testIncompleteOrMalformedInputIsRejected() {
        for input in ["", "#", "#FFF", "#12345678", "#GG005E", "##FF005E", "ＦＦ００５Ｅ", "#FF 05E"] {
            XCTAssertNil(MenuColorHex.normalize(input), input)
        }
    }
}
