import AppKit
import XCTest
@testable import Revclip

final class AppearanceTests: XCTestCase {
    @MainActor
    func testSavedThemeControlsWindowsAndSystemFallback() {
        let defaults = UserDefaults.standard
        let key = RCAppearanceController.preferenceKey
        let original = defaults.object(forKey: key)
        let appearance = NSApp.appearance
        defer {
            if let original { defaults.set(original, forKey: key) }
            else { defaults.removeObject(forKey: key) }
            NSApp.appearance = appearance
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for (value, expected) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            defaults.set(value, forKey: key)
            RCAppearanceController.applySavedAppearance()
            XCTAssertEqual(NSApp.appearance?.name, expected)
            XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), expected)
        }
        for value in ["system", "invalid-future-value"] {
            defaults.set(value, forKey: key)
            RCAppearanceController.applySavedAppearance()
            XCTAssertNil(NSApp.appearance)
        }
        defaults.removeObject(forKey: key)
        RCAppearanceController.applySavedAppearance()
        XCTAssertNil(NSApp.appearance)
    }
}
