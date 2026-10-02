import AppKit
import XCTest
@testable import Revclip

final class RCOCRWorkerTests: XCTestCase {
    private func image(width: Int = 8, height: Int = 8) throws -> CGImage {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage())
    }
    private let settings = RCOCRSettings(language: "ja-en", correction: true, preferredLanguages: ["ja"])
    private func executable(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("revclip-ocr-test-\(UUID().uuidString)")
        try Data(("#!/bin/sh\n" + body).utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testHungWorkerIsTerminatedAndNextRequestCanRun() throws {
        let hanging = try executable("trap '' TERM\nexec /bin/sleep 60\n")
        let began = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try RCOCRWorkerClient.recognize(image(), settings: settings,
            cancellation: RCOCRCancellation(), executable: hanging, timeout: 0.1)) {
            guard case RCOCRError.timedOut = $0 else { return XCTFail("Unexpected \($0)") }
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 3)
        // A separate, successful response after timeout proves no stuck slot/pipe
        // survives the old worker. No screen/clipboard or Vision model is involved.
        let result = RCOCRRecognition(text: "Recovery 日本語", lines: [], languages: ["ja-JP"], revision: 3, seconds: 0.1)
        let data = try JSONEncoder().encode(RCOCRWorkerProtocol.Response(result: result, failure: nil))
        let response = try XCTUnwrap(String(data: data, encoding: .utf8))
        let healthy = try executable("cat >/dev/null\nprintf '%s' '\(response)'\n")
        let actual = try RCOCRWorkerClient.recognize(image(), settings: settings,
            cancellation: RCOCRCancellation(), executable: healthy, timeout: 2)
        XCTAssertEqual(actual.text, result.text)
    }
    func testCancellationInterruptsUncooperativeWorker() async throws {
        let hanging = try executable("trap '' TERM\nexec /bin/sleep 60\n")
        let cell = RCOCRCancellation(), input = try image(), configuration = settings
        let task = Task.detached {
            try RCOCRWorkerClient.recognize(input, settings: configuration, cancellation: cell,
                                          executable: hanging, timeout: 5)
        }
        try await Task.sleep(for: .milliseconds(100))
        cell.cancel()
        do { _ = try await task.value; XCTFail("Cancelled worker returned text") }
        catch { guard case RCOCRError.cancelled = error else { return XCTFail("Unexpected \(error)") } }
    }
    func testCancelledBeforeLaunchAndMissingExecutableFailWithoutSuspendedTimerCrash() throws {
        let cell = RCOCRCancellation(); cell.cancel()
        XCTAssertThrowsError(try RCOCRWorkerClient.recognize(image(), settings: settings, cancellation: cell))
        XCTAssertThrowsError(try RCOCRWorkerClient.recognize(image(), settings: settings,
            cancellation: RCOCRCancellation(), executable: URL(fileURLWithPath: "/nonexistent/revclip-ocr")))
    }
    func testEarlyWorkerExitDoesNotSendSIGPIPEToApplication() throws {
        XCTAssertThrowsError(try RCOCRWorkerClient.recognize(image(width: 1024, height: 1024), settings: settings,
            cancellation: RCOCRCancellation(), executable: URL(fileURLWithPath: "/usr/bin/false"), timeout: 2))
    }
    func testWireRejectsOverflowAndOversizedImagesBeforeAllocation() {
        let invalid = [(Int.max, Int.max), (8, Int.max), (0, 8), (7, 8), (16_000_001, 8)]
        for (width, height) in invalid {
            XCTAssertNil(RCOCRWorkerProtocol.Header(version: 2, width: width, height: height, settings: settings).byteCount)
        }
        XCTAssertNil(RCOCRWorkerProtocol.Header(version: 1, width: 8, height: 8, settings: settings).byteCount)
        XCTAssertEqual(RCOCRWorkerProtocol.Header(version: 2, width: 4000, height: 4000, settings: settings).byteCount, 64_000_000)
    }
    func testWireImageRoundTripRetainsDimensionsAndSettings() throws {
        let pipe = Pipe()
        try RCOCRWorkerProtocol.writeRequest(image: image(), settings: settings, to: pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()
        let (decoded, config) = try RCOCRWorkerProtocol.readRequest(from: pipe.fileHandleForReading)
        XCTAssertEqual(decoded.width, 8); XCTAssertEqual(decoded.height, 8)
        XCTAssertEqual(config.language, settings.language)
        XCTAssertEqual(config.correction, settings.correction)
    }
}
