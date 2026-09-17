import XCTest
@testable import Revclip

final class RCPermissionStatusTests: XCTestCase {
    @MainActor func testClipboardUnknownAndAskCannotAppearGranted() {
        typealias Page = RCPermissionsPreferencesController
        XCTAssertTrue(Page.clipboardStatus(.granted, privacyAPIAvailable: true).isReady)
        for state: RCClipboardAccessState in [.unknown, .denied, .notDetermined] {
            XCTAssertFalse(Page.clipboardStatus(state, privacyAPIAvailable: true).isReady)
        }
        XCTAssertEqual(Page.clipboardStatus(.notDetermined, privacyAPIAvailable: true).titleKey, "Permission Ask")
        XCTAssertEqual(Page.clipboardStatus(.denied, privacyAPIAvailable: true).titleKey, "Permission Denied")
        XCTAssertEqual(Page.clipboardStatus(.unknown, privacyAPIAvailable: true).titleKey, "Permission Unknown")
        XCTAssertEqual(Page.clipboardStatus(.granted, privacyAPIAvailable: false).titleKey, "Permission Not Required")
        XCTAssertFalse(Page.clipboardStatus(.unknown, privacyAPIAvailable: false).isReady)
    }
}
