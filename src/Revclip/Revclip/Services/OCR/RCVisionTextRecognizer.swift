import AppKit
import Vision

struct RCOCRSettings: Sendable {
    let language: String
    let correction: Bool
    let preferredLanguages: [String]
}

struct RCOCRLine: Sendable {
    let text: String
    let rect: CGRect
    let confidence: Float
}

struct RCOCRRecognition: Sendable {
    let text: String
    let lines: [RCOCRLine]
    let languages: [String]
    let revision: Int
    let seconds: Double
}

enum RCOCRError: Error {
    case inputTooLarge, invalidSelection, displayUnavailable, unsupportedLanguage, noText, cancelled
}

// Only this cancellation cell crosses executors. All mutable fields are locked;
// request.perform remains exclusively on the single admitted worker.
final class RCOCRCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var request: VNRecognizeTextRequest?
    func install(_ value: VNRecognizeTextRequest) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw RCOCRError.cancelled }
        request = value
    }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw RCOCRError.cancelled }
    }
    func cancel() {
        lock.lock(); cancelled = true; let current = request; lock.unlock()
        current?.cancel()
    }
    func releaseRequest() { lock.lock(); request = nil; lock.unlock() }
}

enum RCOCRGeometry {
    static func pixelRect(_ selection: CGRect, viewSize: CGSize, width: Int, height: Int) -> CGRect? {
        guard width > 0, height > 0, viewSize.width.isFinite, viewSize.height.isFinite,
              viewSize.width > 0, viewSize.height > 0,
              [selection.origin.x, selection.origin.y, selection.width, selection.height].allSatisfy(\.isFinite) else { return nil }
        let rect = selection.standardized.intersection(CGRect(origin: .zero, size: viewSize))
        guard !rect.isNull, !rect.isEmpty else { return nil }
        let sx = CGFloat(width) / viewSize.width, sy = CGFloat(height) / viewSize.height
        let x0 = max(0, floor(rect.minX * sx)), y0 = max(0, floor(rect.minY * sy))
        let x1 = min(CGFloat(width), ceil(rect.maxX * sx)), y1 = min(CGFloat(height), ceil(rect.maxY * sy))
        guard x1 - x0 >= 8, y1 - y0 >= 8 else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
    static func validImage(_ image: CGImage, maximumPixels: Int) -> Bool {
        let (pixels, overflow) = image.width.multipliedReportingOverflow(by: image.height)
        let (bytes, byteOverflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        return !overflow && !byteOverflow && pixels > 0 && pixels <= maximumPixels && bytes <= 128 * 1024 * 1024
    }
}

enum RCVisionTextRecognizer {
    static func supportedLanguages() throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return try request.supportedRecognitionLanguages()
    }

    static func languages(for settings: RCOCRSettings, supported: [String]) throws -> [String] {
        func match(_ raw: String) -> String? {
            let normalized = raw.replacingOccurrences(of: "_", with: "-").lowercased()
            return supported.first { $0.lowercased() == normalized } ?? supported.first {
                $0.split(separator: "-").first?.lowercased() == normalized.split(separator: "-").first.map(String.init)
            }
        }
        if settings.language == "ja-en" {
            guard let ja = match("ja"), let en = match("en") else { throw RCOCRError.unsupportedLanguage }
            return [ja, en]
        }
        if settings.language != "auto" {
            guard supported.contains(settings.language) else { throw RCOCRError.unsupportedLanguage }
            return [settings.language]
        }
        var result: [String] = []
        // Reserve room for both required mixed-text languages, then user preference.
        for raw in [settings.preferredLanguages.first ?? "ja", "ja", "en"] + settings.preferredLanguages {
            if let value = match(raw), !result.contains(value) { result.append(value) }
            if result.count == 3 { break }
        }
        guard !result.isEmpty else { throw RCOCRError.unsupportedLanguage }
        return result
    }

    /// Bullets, and what Apple Vision returns for a hollow or filled bullet ("o", "O",
    /// "0"), plus "1." / "1)" / "a." style ordinals. Deliberately a closed set: any other
    /// one or two characters are data, not a marker.
    static func isListMarker(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespaces)
        if ["•", "◦", "○", "●", "・", "‣", "▪", "■", "□", "◆", "◇", "–", "—", "-", "*", "o", "O", "0"].contains(value) { return true }
        guard value.count == 2, let mark = value.last, [".", ")", "．", "）"].contains(mark), let first = value.first else { return false }
        return first.isNumber || (first.isASCII && first.isLetter)
    }

    static func format(_ lines: [RCOCRLine], imageSize: CGSize) -> String {
        // Strict total ordering first; never use a non-transitive epsilon comparator.
        // Vision boxes normalize X by image width and Y by image height.
        // Compare gaps and glyph heights only after putting both into pixels.
        let pixelLines = lines.map { line in
            RCOCRLine(text: line.text,
                      rect: CGRect(x: line.rect.minX * imageSize.width, y: line.rect.minY * imageSize.height,
                                   width: line.rect.width * imageSize.width, height: line.rect.height * imageSize.height),
                      confidence: line.confidence)
        }
        let ordered = pixelLines.enumerated().sorted {
            if $0.element.rect.midY != $1.element.rect.midY { return $0.element.rect.midY > $1.element.rect.midY }
            if $0.element.rect.minX != $1.element.rect.minX { return $0.element.rect.minX < $1.element.rect.minX }
            return $0.offset < $1.offset
        }
        var rows: [[RCOCRLine]] = []
        for (_, line) in ordered {
            if let last = rows.last, let anchor = last.first,
               min(anchor.rect.maxY, line.rect.maxY) - max(anchor.rect.minY, line.rect.minY) >= min(anchor.rect.height, line.rect.height) * 0.65 {
                rows[rows.count - 1].append(line)
            } else { rows.append([line]) }
        }
        let result = rows.flatMap { row -> [String] in
            let sorted = row.sorted { $0.rect.minX < $1.rect.minX }
            var output: [String] = []
            var previous: RCOCRLine?
            for line in sorted {
                let value = line.text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                if let previous, let last = output.last {
                    let gap = line.rect.minX - previous.rect.maxX
                    let height = min(line.rect.height, previous.rect.height)
                    let adjacentFragments = gap >= -height * 0.1 && gap <= height * 0.15
                    let asciiWordEdges = previous.text.last?.isASCII == true && line.text.first?.isASCII == true
                        && (previous.text.last?.isLetter == true || previous.text.last?.isNumber == true)
                        && (line.text.first?.isLetter == true || line.text.first?.isNumber == true)
                    // A list marker and its text are one line on screen, but the indent
                    // between them is wider than a word gap, so Vision often reports the
                    // marker alone. It is joined only when the text is what a list marker
                    // reads as and the geometry agrees: the leftmost fragment of the row,
                    // no wider than a glyph or two, an indent-sized gap. A short value in
                    // the left column of a table ("A", "12", "ID") is not a marker and
                    // stays a column. Nothing is deleted or rewritten.
                    let markerAndText = previous.rect.minX == sorted[0].rect.minX && output.count == 1
                        && isListMarker(previous.text)
                        && previous.rect.width <= previous.rect.height * 1.5
                        && gap > 0 && gap <= height * 3
                    // Only a clear word-sized gap between Latin words is joined.
                    // Tiny gaps join the original fragments without adding a character;
                    // wide column gaps remain separate.
                    if adjacentFragments {
                        output[output.count - 1] = last + value
                    } else if (asciiWordEdges && gap >= height * 0.2 && gap <= height * 0.8) || markerAndText {
                        output[output.count - 1] = last + " " + value
                    } else { output.append(value) }
                } else { output.append(value) }
                previous = line
            }
            return output
        }.joined(separator: "\n")
        return result.trimmingCharacters(in: .newlines)
    }

    static func independentCrop(image: CGImage, selection: CGRect, cancellation: RCOCRCancellation) throws -> CGImage {
        try cancellation.check()
        guard RCOCRGeometry.validImage(image, maximumPixels: 32_000_000),
              selection.width >= 8, selection.height >= 8,
              selection.width * selection.height <= 16_000_000 else { throw RCOCRError.inputTooLarge }
        // CGImage.cropping can share its parent. Draw one independent SDR buffer
        // off-main before Vision, without any filesystem serialization.
        guard let crop = image.cropping(to: selection),
              let color = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8,
                                      bytesPerRow: crop.width * 4, space: color,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw RCOCRError.invalidSelection }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        guard let independent = context.makeImage() else { throw RCOCRError.inputTooLarge }
        return independent
    }

    static func recognizeCrop(_ image: CGImage, settings: RCOCRSettings, cancellation: RCOCRCancellation) throws -> RCOCRRecognition {
        try cancellation.check()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = settings.correction
        request.automaticallyDetectsLanguage = settings.language == "auto"
        request.minimumTextHeight = 0
        request.recognitionLanguages = try languages(for: settings, supported: request.supportedRecognitionLanguages())
        try cancellation.install(request)
        defer { cancellation.releaseRequest() }
        let start = ProcessInfo.processInfo.systemUptime
        try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
        try cancellation.check()
        var count = 0
        let lines = try (request.results ?? []).compactMap { observation -> RCOCRLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            count += candidate.string.utf8.count + 1
            guard count <= 1024 * 1024 else { throw RCOCRError.inputTooLarge }
            return RCOCRLine(text: candidate.string, rect: observation.boundingBox, confidence: candidate.confidence)
        }
        let text = format(lines, imageSize: CGSize(width: image.width, height: image.height))
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RCOCRError.noText }
        return RCOCRRecognition(text: text, lines: lines, languages: request.recognitionLanguages,
                                revision: request.revision, seconds: ProcessInfo.processInfo.systemUptime - start)
    }
}
