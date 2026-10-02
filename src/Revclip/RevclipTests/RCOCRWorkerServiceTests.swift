import XCTest
import CoreGraphics
@testable import Revclip

final class RCOCRWorkerServiceTests: XCTestCase {
    private func image() throws -> CGImage {
        try XCTUnwrap(CGContext(data: nil, width: 80, height: 24, bitsPerComponent: 8,
            bytesPerRow: 320, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage())
    }
    private let settings = RCOCRSettings(language: "auto", correction: false, preferredLanguages: ["ja"])

    @MainActor func testFirstRequestRecognizesActualPixelsExactlyOnceWithoutSyntheticPreparation() async throws {
        let service = RCOCRWorkerService()
        let reply = RCOCRRecognition(text: "Selected 日本語", lines: [], languages: ["ja-JP"], revision: 3, seconds: 35)
        let executable = URL(fileURLWithPath: "/unused/ocr-worker")
        let called = expectation(description: "Exactly one actual recognition")
        called.assertForOverFulfill = true
        let result = try await service.recognize(image(), settings: settings, cancellation: RCOCRCancellation(), executable: executable) { image, configuration, _, worker in
            called.fulfill()
            XCTAssertEqual(image.width, 80)
            XCTAssertEqual(image.height, 24)
            XCTAssertEqual(configuration.language, "auto")
            XCTAssertFalse(configuration.correction)
            XCTAssertEqual(worker, executable)
            return reply
        }
        await fulfillment(of: [called], timeout: 1)
        XCTAssertEqual(result.text, "Selected 日本語", "The first real recognition result must reach the caller")
    }

    @MainActor func testFailureDoesNotCreateASeparatePreparationGateOnNextRequest() async throws {
        let service = RCOCRWorkerService()
        do {
            _ = try await service.recognize(image(), settings: settings, cancellation: RCOCRCancellation()) { _, _, _, _ in
                throw RCOCRError.workerFailed
            }
            XCTFail("Failure was accepted")
        } catch { guard case RCOCRError.workerFailed = error else { return XCTFail("Unexpected \(error)") } }
        let result = try await service.recognize(image(), settings: settings, cancellation: RCOCRCancellation()) { image, _, _, _ in
            XCTAssertEqual(image.width, 80)
            return .init(text: "Recovered", lines: [], languages: [], revision: 3, seconds: 0.1)
        }
        XCTAssertEqual(result.text, "Recovered")
    }

    @MainActor func testCancellationRejectsAnUncooperativeLateResult() async throws {
        let cell = RCOCRCancellation()
        do {
            _ = try await RCOCRWorkerService().recognize(image(), settings: settings, cancellation: cell) { _, _, cell, _ in
                cell.cancel()
                return .init(text: "Must not copy", lines: [], languages: [], revision: 3, seconds: 0.1)
            }
            XCTFail("Cancelled worker result was accepted")
        } catch { guard case RCOCRError.cancelled = error else { return XCTFail("Unexpected \(error)") } }
    }
}
