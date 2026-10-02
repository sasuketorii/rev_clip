import Foundation
import CoreGraphics

/// Private, bounded, memory-only transport. The worker never captures a screen or
/// opens the clipboard/history. Only the selected SDR pixels cross this pipe.
enum RCOCRWorkerProtocol {
    static let maximumPixels = 16_000_000
    static let maximumHeaderBytes = 16_384
    static let maximumResponseBytes = 8 * 1024 * 1024
    // A sample warmup cannot certify the OS model cache for the actual crop.
    // Bound compilation together with inference in the same stoppable child.
    static let recognitionTimeout: Double = 90
    struct Header: Codable {
        let version: Int
        let width: Int
        let height: Int
        let settings: RCOCRSettings

        var byteCount: Int? {
            guard version == 2, width >= 8, height >= 8,
                  width <= RCOCRWorkerProtocol.maximumPixels / height else { return nil }
            return width * height * 4
        }
    }
    struct Response: Codable {
        let result: RCOCRRecognition?
        let failure: String?
    }
    static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            guard let part = try handle.read(upToCount: min(65_536, count - data.count)), !part.isEmpty else {
                throw RCOCRError.workerFailed
            }
            data.append(part)
        }
        return data
    }
    static func readRequest(from handle: FileHandle) throws -> (CGImage, RCOCRSettings) {
        let prefix = try readExactly(4, from: handle)
        let length = prefix.reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= maximumHeaderBytes else { throw RCOCRError.inputTooLarge }
        let header = try JSONDecoder().decode(Header.self, from: readExactly(length, from: handle))
        guard let count = header.byteCount else { throw RCOCRError.inputTooLarge }
        let pixels = try readExactly(count, from: handle)
        guard let provider = CGDataProvider(data: pixels as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: header.width, height: header.height, bitsPerComponent: 8,
                  bitsPerPixel: 32, bytesPerRow: header.width * 4, space: space,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw RCOCRError.invalidSelection
        }
        return (image, header.settings)
    }
    static func writeRequest(image: CGImage, settings: RCOCRSettings, to handle: FileHandle) throws {
        let header = Header(version: 2, width: image.width, height: image.height, settings: settings)
        guard let count = header.byteCount,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                  bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw RCOCRError.inputTooLarge }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let bytes = context.data else { throw RCOCRError.invalidSelection }
        let metadata = try JSONEncoder().encode(header)
        guard metadata.count <= maximumHeaderBytes else { throw RCOCRError.inputTooLarge }
        let n = UInt32(metadata.count)
        try handle.write(contentsOf: Data([UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)]))
        try handle.write(contentsOf: metadata)
        // Bounded chunks avoid a second full-frame allocation.
        for offset in stride(from: 0, to: count, by: 65_536) {
            try handle.write(contentsOf: Data(bytes: bytes.advanced(by: offset), count: min(65_536, count - offset)))
        }
    }
    static func readResponse(from handle: FileHandle) throws -> RCOCRRecognition {
        var data = Data()
        while let part = try handle.read(upToCount: min(65_536, maximumResponseBytes + 1 - data.count)), !part.isEmpty {
            data.append(part)
            guard data.count <= maximumResponseBytes else { throw RCOCRError.inputTooLarge }
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        if let result = response.result, response.failure == nil,
           result.text.utf8.count <= 1024 * 1024, result.lines.isEmpty { return result }
        switch response.failure {
        case "noText": throw RCOCRError.noText
        case "unsupportedLanguage": throw RCOCRError.unsupportedLanguage
        case "inputTooLarge": throw RCOCRError.inputTooLarge
        default: throw RCOCRError.workerFailed
        }
    }
}
