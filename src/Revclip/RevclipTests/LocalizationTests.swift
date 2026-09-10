import XCTest
@testable import Revclip

final class LocalizationTests: XCTestCase {
    private let languages = ["en", "ja", "ko", "zh-Hans", "fr", "de", "pt-BR", "it"]

    func testBundledLanguagesHaveCompleteTranslationsAndMatchingFormatArguments() throws {
        let bundle = Bundle.main
        let baseURL = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en"))
        let english = try strings(at: baseURL)
        XCTAssertFalse(english.isEmpty)
        let format = try NSRegularExpression(pattern: #"%(?:\d+\$)?[-+ #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hlLzjtq])?[@diuoxXfFeEgGaAcCsSp%]"#)
        func arguments(_ text: String) -> [String] {
            let text = text as NSString
            return format.matches(in: text as String, range: NSRange(location: 0, length: text.length))
                .map { text.substring(with: $0.range) }.filter { $0 != "%%" }.sorted()
        }
        for language in languages {
            XCTAssertTrue(bundle.localizations.contains(language), "Missing language \(language)")
            let path = try XCTUnwrap(bundle.resourceURL?.appendingPathComponent("\(language).lproj/Localizable.strings"))
            let translated = try strings(at: path)
            for (key, value) in english {
                let result = try XCTUnwrap(translated[key], "\(language): \(key)")
                XCTAssertFalse(result.isEmpty, "\(language): \(key)")
                XCTAssertEqual(arguments(value), arguments(result), "\(language): \(key)")
            }
            for nib in ["MainMenu", "RCGeneralPreferencesView", "RCTypePreferencesView", "RCShortcutsPreferencesView", "RCUpdatesPreferencesView", "RCBetaPreferencesView"] {
                let url = try XCTUnwrap(bundle.resourceURL?.appendingPathComponent("\(language).lproj/\(nib).strings"))
                XCTAssertFalse(try strings(at: url).isEmpty, "\(language): \(nib)")
            }
        }
    }

    private func strings(at url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }
}
