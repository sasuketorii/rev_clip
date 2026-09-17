import XCTest
import AppKit
@testable import Revclip

final class RCOCRVisionTests: XCTestCase {
    func testReadingGapsUsePixelsRegardlessOfCropAspectRatio() {
        // Same 20px-high words with a 10px word gap, in differently shaped crops.
        for size in [CGSize(width: 1000, height: 100), CGSize(width: 100, height: 1000), CGSize(width: 1000, height: 1000)] {
            func line(_ text: String, x: CGFloat) -> RCOCRLine {
                .init(text: text, rect: CGRect(x: x / size.width, y: 40 / size.height,
                    width: 30 / size.width, height: 20 / size.height), confidence: 1)
            }
            XCTAssertEqual(RCVisionTextRecognizer.format([line("Hello", x: 0), line("world", x: 40)], imageSize: size), "Hello world")
            XCTAssertEqual(RCVisionTextRecognizer.format([line("Left", x: 0), line("Column", x: 80)], imageSize: size), "Left\nColumn")
        }
    }

    /// Pixel-space fixture: x range, top, height (top-left origin), on a given image size.
    private func fragment(_ text: String, _ x0: CGFloat, _ x1: CGFloat, top: CGFloat, height: CGFloat, in size: CGSize) -> RCOCRLine {
        .init(text: text, rect: CGRect(x: x0 / size.width, y: 1 - (top + height) / size.height,
                                       width: (x1 - x0) / size.width, height: height / size.height), confidence: 1)
    }

    func testListMarkerStaysOnTheLineOfItsTextAndRealLineBreaksAreKept() {
        // Geometry measured from the reported screenshot (1418x686): a marker the engine
        // returned alone, its text on the same row, a nested item, and a second visual line.
        for scale in [CGFloat(1), 2] {
            let size = CGSize(width: 1418 * scale, height: 686 * scale)
            func f(_ t: String, _ a: CGFloat, _ b: CGFloat, _ top: CGFloat, _ h: CGFloat) -> RCOCRLine {
                fragment(t, a * scale, b * scale, top: top * scale, height: h * scale, in: size)
            }
            let lines = [f("文脈ごとの適切な表現", 54, 396, 29, 37),
                         f("o", 60, 85, 117, 29), f("日常的な会話・メモ・チャット（そのままでOK）", 128, 884, 113, 35),
                         f("o", 134, 163, 420, 33), f("high-speed OCR（高速なOCR）", 210, 693, 418, 37),
                         f("faster OCR processing / faster text recognition", 218, 944, 571, 37),
                         f("（より高速なOCR処理／文字認識）", 239, 746, 620, 37)]
            XCTAssertEqual(RCVisionTextRecognizer.format(lines, imageSize: size), """
                文脈ごとの適切な表現
                o 日常的な会話・メモ・チャット（そのままでOK）
                o high-speed OCR（高速なOCR）
                faster OCR processing / faster text recognition
                （より高速なOCR処理／文字認識）
                """, "scale \(scale): the marker is kept, nothing is deleted, separate lines stay separate")
        }
    }

    func testColumnsCodeAndNonMarkersKeepTheirPreviousOutput() {
        let size = CGSize(width: 1200, height: 400)
        func f(_ t: String, _ a: CGFloat, _ b: CGFloat, _ top: CGFloat = 100) -> RCOCRLine { fragment(t, a, b, top: top, height: 30, in: size) }
        // Two columns of prose: a long left fragment and a wide gutter, on two rows.
        XCTAssertEqual(RCVisionTextRecognizer.format([f("左の段の一行目の文章", 0, 400), f("右の段の一行目の文章", 600, 1000),
                                                      f("左の段の二行目", 0, 300, 150), f("右の段の二行目", 600, 900, 150)], imageSize: size),
                       "左の段の一行目の文章\n右の段の一行目の文章\n左の段の二行目\n右の段の二行目")
        // A long left fragment with an indent-sized gap is not a marker.
        XCTAssertEqual(RCVisionTextRecognizer.format([f("名前", 0, 120), f("値", 180, 210)], imageSize: size), "名前\n値")
        // Code split by the engine is left as it was.
        XCTAssertEqual(RCVisionTextRecognizer.format([f("let x", 0, 90), f("= 1", 105, 150)], imageSize: size), "let x\n= 1")
        // A short left fragment across a column-sized gap is a table cell, not a marker.
        XCTAssertEqual(RCVisionTextRecognizer.format([f("0", 0, 18), f("合計", 140, 200)], imageSize: size), "0\n合計")
        // Three characters, or a short fragment that is not the leftmost, are not markers.
        XCTAssertEqual(RCVisionTextRecognizer.format([f("(1)", 0, 40), f("項目", 80, 140)], imageSize: size), "(1)\n項目")
        XCTAssertEqual(RCVisionTextRecognizer.format([f("見出しの文章", 0, 200), f("o", 260, 285), f("本文", 330, 390)], imageSize: size),
                       "見出しの文章\no\n本文")
        // Short values in the left column of a table are data, on one row or on several.
        XCTAssertEqual(RCVisionTextRecognizer.format([f("A", 0, 20), f("123", 70, 130)], imageSize: size), "A\n123")
        XCTAssertEqual(RCVisionTextRecognizer.format([f("ID", 0, 34), f("Value", 80, 170), f("7", 0, 16, 150), f("Alpha", 80, 170, 150),
                                                      f("12", 0, 32, 200), f("Beta", 80, 160, 200)], imageSize: size),
                       "ID\nValue\n7\nAlpha\n12\nBeta")
        XCTAssertFalse(RCVisionTextRecognizer.isListMarker("A")); XCTAssertFalse(RCVisionTextRecognizer.isListMarker("12"))
        XCTAssertFalse(RCVisionTextRecognizer.isListMarker("ID")); XCTAssertFalse(RCVisionTextRecognizer.isListMarker("x")); XCTAssertFalse(RCVisionTextRecognizer.isListMarker(""))
        for marker in ["•", "○", "o", "O", "0", "-", "・", "1.", "2)", "a.", "３．"] { XCTAssertTrue(RCVisionTextRecognizer.isListMarker(marker), marker) }
        // Short numbered and hyphen markers with an ordinary indent are joined, unchanged.
        XCTAssertEqual(RCVisionTextRecognizer.format([f("1.", 0, 28), f("最初の項目", 60, 210)], imageSize: size), "1. 最初の項目")
        XCTAssertEqual(RCVisionTextRecognizer.format([f("-", 0, 12), f("item", 50, 110)], imageSize: size), "- item")
    }

    func testPointerScreenUsesTheExactCoordinateRangeAndNeverGuesses() {
        let main = CGRect(x: 0, y: 0, width: 1512, height: 982), right = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let left = CGRect(x: -1280, y: 100, width: 1280, height: 800)
        let frames = [main, right, left]
        XCTAssertEqual(RCOCRScreenHitTest.index(of: CGPoint(x: 700, y: 982), in: frames), 0, "Top pixel row reports y == maxY")
        XCTAssertNil(RCOCRScreenHitTest.index(of: CGPoint(x: 700, y: 0), in: frames), "y == minY is below the bottom row")
        XCTAssertEqual(RCOCRScreenHitTest.index(of: CGPoint(x: 1511.9, y: 1), in: frames), 0)
        XCTAssertEqual(RCOCRScreenHitTest.index(of: CGPoint(x: 1512, y: 500), in: frames), 1, "A shared edge belongs to exactly one screen")
        XCTAssertEqual(RCOCRScreenHitTest.index(of: CGPoint(x: -1280, y: 900), in: frames), 2, "Negative origin, top row")
        XCTAssertEqual(RCOCRScreenHitTest.index(of: CGPoint(x: -0.5, y: 500), in: frames), 2)
        XCTAssertNil(RCOCRScreenHitTest.index(of: CGPoint(x: -0.5, y: 950), in: frames), "Outside every screen is a failure, not the nearest screen")
        XCTAssertNil(RCOCRScreenHitTest.index(of: CGPoint(x: 5000, y: 5000), in: frames))
        XCTAssertNil(RCOCRScreenHitTest.index(of: CGPoint(x: 10, y: 10), in: []))
    }

    func testPixelGeometryUsesActualFrameAndRoundsOutward() {
        for (size, width, height) in [(CGSize(width: 100, height: 100), 200, 200), (CGSize(width: 100, height: 100), 125, 175), (CGSize(width: 100, height: 200), 100, 200)] {
            let selection = CGRect(x: 10.1, y: 20.1, width: 30.2, height: 40.2)
            let rect = RCOCRGeometry.pixelRect(selection, viewSize: size, width: width, height: height)!
            XCTAssertEqual(rect.minX, floor(selection.minX * CGFloat(width) / size.width))
            XCTAssertEqual(rect.maxY, ceil(selection.maxY * CGFloat(height) / size.height))
            XCTAssertEqual(RCOCRGeometry.pixelRect(CGRect(x: selection.maxX, y: selection.maxY, width: -selection.width, height: -selection.height), viewSize: size, width: width, height: height), rect)
        }
        XCTAssertNil(RCOCRGeometry.pixelRect(CGRect(x: CGFloat.nan, y: 0, width: 20, height: 20), viewSize: CGSize(width: 100, height: 100), width: 200, height: 200))
        XCTAssertNil(RCOCRGeometry.pixelRect(CGRect(x: 1, y: 1, width: 1, height: 1), viewSize: CGSize(width: 100, height: 100), width: 200, height: 200))
        XCTAssertEqual(RCOCRGeometry.pixelRect(CGRect(x: -10, y: -20, width: 200, height: 200), viewSize: CGSize(width: 100, height: 100), width: 200, height: 200), CGRect(x: 0, y: 0, width: 200, height: 200))
    }
    func testCropPreservesTopLeftPixelCoordinatesAndOwnsOnlySelectedDimensions() throws {
        var pixels = [UInt8](repeating: 255, count: 40 * 40 * 4)
        for y in 0..<40 { for x in 0..<40 {
            let offset = (y * 40 + x) * 4
            pixels[offset] = y < 20 ? 255 : 0
            pixels[offset + 1] = x >= 20 ? 255 : 0
            pixels[offset + 2] = y >= 20 ? 255 : 0
        } }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: 40, height: 40, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 160,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        for (rect, expected) in [(CGRect(x: 0, y: 0, width: 20, height: 20), [255, 0, 0]),
                                 (CGRect(x: 0, y: 20, width: 20, height: 20), [0, 0, 255])] {
            let crop = try RCVisionTextRecognizer.independentCrop(image: image, selection: rect, cancellation: RCOCRCancellation())
            XCTAssertEqual(crop.width, 20); XCTAssertEqual(crop.height, 20)
            let data = crop.dataProvider!.data! as Data
            XCTAssertEqual(Array(data.prefix(3)).map(Int.init), expected)
            XCTAssertLessThanOrEqual(crop.bytesPerRow * crop.height, 20 * 20 * 4)
        }
    }
    func testFormatterKeepsSymbolsWhitespaceLowConfidenceAndStableReadingOrder() {
        let lines = [
            RCOCRLine(text: "  let O0 = 1;", rect: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.1), confidence: 0.01),
            RCOCRLine(text: "https://example.test/a-b?x=1", rect: CGRect(x: 0.1, y: 0.8, width: 0.7, height: 0.1), confidence: 1),
            RCOCRLine(text: "日本語 ABC\r\n次の行", rect: CGRect(x: 0.1, y: 0.5, width: 0.5, height: 0.1), confidence: 0.5)
        ]
        XCTAssertEqual(RCVisionTextRecognizer.format(lines, imageSize: CGSize(width: 1, height: 1)), "https://example.test/a-b?x=1\n日本語 ABC\n次の行\n  let O0 = 1;")
    }
    func testSameRowGroupingOnlyJoinsUnambiguousJapaneseAndLatinGaps() {
        func line(_ text: String, _ x: Double) -> RCOCRLine { .init(text: text, rect: CGRect(x: x, y: 0.5, width: 0.2, height: 0.1), confidence: 1) }
        XCTAssertEqual(RCVisionTextRecognizer.format([line("日本", 0.1), line("語", 0.305)], imageSize: CGSize(width: 1, height: 1)), "日本語")
        XCTAssertEqual(RCVisionTextRecognizer.format([line("Hello", 0.1), line("world", 0.34)], imageSize: CGSize(width: 1, height: 1)), "Hello world")
        XCTAssertEqual(RCVisionTextRecognizer.format([line("Column", 0.1), line("Other", 0.7)], imageSize: CGSize(width: 1, height: 1)), "Column\nOther")
        XCTAssertEqual(RCVisionTextRecognizer.format([line("A-1", 0.1), line("B_2", 0.34)], imageSize: CGSize(width: 1, height: 1)), "A-1 B_2")
        XCTAssertEqual(RCVisionTextRecognizer.format([line("text", 0.1), line("42", 0.34)], imageSize: CGSize(width: 1, height: 1)), "text 42")
        XCTAssertEqual(RCVisionTextRecognizer.format([line("日本語", 0.1), line("。", 0.305)], imageSize: CGSize(width: 1, height: 1)), "日本語。")
    }
    func testLanguagePolicyDoesNotSilentlyReplaceUnsupportedManualSetting() throws {
        let support = ["en-US", "ja-JP", "fr-FR"]
        XCTAssertEqual(try RCVisionTextRecognizer.languages(for: .init(language: "auto", correction: false, preferredLanguages: ["fr_FR"]), supported: support), ["fr-FR","ja-JP","en-US"])
        XCTAssertThrowsError(try RCVisionTextRecognizer.languages(for: .init(language: "xx", correction: false, preferredLanguages: []), supported: support))
    }
    @MainActor
    private func fixture(_ text: String, dark: Bool = false) -> CGImage {
        let image = NSImage(size: CGSize(width: 1000, height: 200))
        image.lockFocus()
        (dark ? NSColor.black : NSColor.white).setFill(); NSRect(x: 0, y: 0, width: 1000, height: 200).fill()
        text.draw(at: CGPoint(x: 30, y: 70), withAttributes: [.font: NSFont.systemFont(ofSize: 38), .foregroundColor: dark ? NSColor.white : NSColor.black])
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }
    @MainActor
    func testRealVisionSyntheticJapaneseEnglishAndSymbols() async throws {
        for (text, dark) in [("RevOCR Hello 12345",false),("日本語の文字をコピー",false),("日本語 RevOCR 123",true),("https://example.com",false)] {
            let image = fixture(text, dark: dark)
            let result = try await Task.detached {
                try RCVisionTextRecognizer.recognizeCrop(image, settings: .init(language: "ja-en", correction: false, preferredLanguages: ["ja"]), cancellation: RCOCRCancellation())
            }.value
            if text == "日本語 RevOCR 123" {
                // Accuracy observation: Vision revision 3 drops the Japanese/Latin
                // separator on this fixture. Do not normalize it into an exact pass.
                XCTAssertTrue(result.text.contains("日本語") && result.text.contains("RevOCR") && result.text.contains("123"))
                print("REVOCR_ACCURACY mixed_exact=\(result.text == text) expected_characters=\(text.count) actual_characters=\(result.text.count)")
            } else { XCTAssertEqual(result.text, text) }
            print("REVOCR_SYNTHETIC revision=\(result.revision) languages=\(result.languages) pixels=\(image.width)x\(image.height) ms=\(result.seconds * 1000)")
        }
    }
    @MainActor
    func testNoTextAndCancellationLeaveNoResult() async throws {
        let image = fixture("")
        do {
            _ = try await Task.detached { try RCVisionTextRecognizer.recognizeCrop(image, settings: .init(language: "auto", correction: false, preferredLanguages: ["ja"]), cancellation: RCOCRCancellation()) }.value
            XCTFail("blank must be noText")
        } catch RCOCRError.noText { }
        let cell = RCOCRCancellation(); cell.cancel()
        XCTAssertThrowsError(try RCVisionTextRecognizer.recognizeCrop(image, settings: .init(language: "auto", correction: false, preferredLanguages: []), cancellation: cell))
    }
}
