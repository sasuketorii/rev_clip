// Local synthetic-only harness. Compile with the production recognizer source:
// swiftc -O src/Revclip/Revclip/Services/OCR/RCVisionTextRecognizer.swift scripts/benchmark_revocr.swift -o .local/revocr/benchmark
// Does not capture a screen, access a pasteboard, open history, or ship in the app.
import AppKit
import Darwin

private func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
}
private func distance(_ a: String, _ b: String) -> Int {
    let a = Array(a), b = Array(b)
    var previous = Array(0...b.count)
    for (i, value) in a.enumerated() {
        var row = [i + 1] + Array(repeating: 0, count: b.count)
        for (j, other) in b.enumerated() {
            row[j + 1] = min(row[j] + 1, previous[j + 1] + 1, previous[j] + (value == other ? 0 : 1))
        }
        previous = row
    }
    return previous.last!
}
@main struct RCOCRBenchmark {
    @MainActor static func image(_ text: String, size: CGFloat, dark: Bool, colored: Bool) -> CGImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 720, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        (dark ? NSColor.black : NSColor.white).setFill(); NSRect(x: 0, y: 0, width: 1280, height: 720).fill()
        text.draw(at: CGPoint(x: 32, y: 460), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
                    .foregroundColor: colored ? NSColor.systemBlue : (dark ? NSColor.white : NSColor.black)])
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage!
    }
    @MainActor static func main() async throws {
        let fixtures = ["RevOCR copies screen text.", "日本語の文字をコピーします。", "日本語 RevOCR 123", "https://example.com/a-b?x=1", "hello@example.test",
                        "let count = 123;", "0123456789 + - = / : ;", "Two lines\nSecond line", "Dark mode text 42", "Color text 2026", "Small text example", "画面の端と余白を確認"]
        let language = CommandLine.arguments.dropFirst().first ?? "auto"
        precondition(["auto", "ja-en"].contains(language), "mode must be auto or ja-en")
        let settings = RCOCRSettings(language: language, correction: false, preferredLanguages: ["ja"])
        var measurements: [Double] = [], memory: [UInt64] = [residentBytes()]
        var errors = 0, characters = 0, exact = 0
        for index in 0..<100 {
            let sample = index % fixtures.count
            let input = image(fixtures[sample], size: sample == 10 ? 16 : 30, dark: sample == 8, colored: sample == 9)
            let result = try await Task.detached(priority: .userInitiated) {
                try autoreleasepool { try RCVisionTextRecognizer.recognizeCrop(input, settings: settings, cancellation: RCOCRCancellation()) }
            }.value
            measurements.append(result.seconds * 1000)
            if index < fixtures.count {
                let edits = distance(fixtures[sample], result.text)
                errors += edits; characters += fixtures[sample].count; exact += edits == 0 ? 1 : 0
                let row: [String: Any] = ["fixture": sample, "expected": fixtures[sample], "recognized": result.text, "edits": edits,
                                         "revision": result.revision, "languages": result.languages, "ms": result.seconds * 1000]
                print(String(data: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), encoding: .utf8)!)
            }
            if index % 10 == 9 { memory.append(residentBytes()) }
        }
        let warm = measurements.dropFirst().sorted()
        let summary: [String: Any] = ["scope": "standalone_optimized_recognizer_synthetic_not_app_or_screen", "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "language_mode": language, "automatically_detects_language": language == "auto", "n": 100, "independent_fixtures": fixtures.count, "pixels": "1280x720", "correction": false,
            "first_ms": measurements[0], "warm_p50_ms": warm[49], "warm_p95_ms": warm[94], "max_ms": measurements.max()!,
            "exact": exact, "character_units": "extended_grapheme_clusters_including_whitespace_and_LF", "edits": errors, "characters": characters,
            "cer": Double(errors) / Double(characters), "rss_start_then_every_10_bytes": memory]
        print(String(data: try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
