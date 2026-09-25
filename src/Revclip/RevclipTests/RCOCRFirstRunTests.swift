import AppKit
import XCTest
@testable import Revclip

private actor RCHeldRecognition {
    private var continuation: CheckedContinuation<RCOCRRecognition, Error>?
    func run(started: XCTestExpectation) async throws -> RCOCRRecognition {
        try await withCheckedThrowingContinuation {
            continuation = $0
            started.fulfill()
        }
    }
    func succeed() {
        continuation?.resume(returning: RCOCRRecognition(text: "Synthetic OCR", lines: [], languages: ["en-US"], revision: 3, seconds: 12))
        continuation = nil
    }
}

final class RCOCRFirstRunTests: XCTestCase {
    @MainActor
    func testFreshPermissionActionRequestsBeforeOpeningSettings() {
        for grantedByRequest in [false, true] {
            var calls: [String] = []
            RCOCRCoordinator.requestScreenRecordingAccess(preflight: { calls.append("preflight"); return false },
                request: { calls.append("request"); return grantedByRequest }, openSettings: { calls.append("settings") })
            XCTAssertEqual(calls, ["preflight", "request", "settings"])
        }
        var requests = 0, opens = 0
        RCOCRCoordinator.requestScreenRecordingAccess(preflight: { true }, request: { requests += 1; return true }, openSettings: { opens += 1 })
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(opens, 1)
    }

    @MainActor
    private func image() throws -> CGImage {
        try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage())
    }
    private let settings = RCOCRSettings(language: "ja-en", correction: false, preferredLanguages: ["ja"])

    @MainActor
    func testColdRecognitionSurvivesOldDeadlineAndThenUsesWarmBudget() async throws {
        let coordinator = RCOCRCoordinator()
        defer { coordinator.cancel() }
        let id = UUID(), cell = RCOCRCancellation(), held = RCHeldRecognition()
        var now = 100.0
        coordinator.uptime = { now }
        var copied: [String] = []
        coordinator.screenCaptureAccess = { true }
        coordinator.commitRecognition = { text, _ in copied.append(text); return .historySkipped }
        coordinator.adoptOperationForTesting(id, context: RCOCRCommitContext())
        coordinator.beginRecognition(cell: cell, id: id)
        let started = expectation(description: "recognition started")
        let task = coordinator.recognizeCrop(try image(), id: id, settings: settings, cell: cell) { _, _, _ in
            try await held.run(started: started)
        }
        await fulfillment(of: [started], timeout: 2)
        now += 12
        XCTAssertNotNil(coordinator.checkDeadline(id: id), "Cold initialization must survive the old 10 second limit")
        XCTAssertEqual(coordinator.operation, id)
        XCTAssertNoThrow(try cell.check())
        await held.succeed()
        await task.value
        XCTAssertFalse(coordinator.workerBusy)
        XCTAssertTrue(coordinator.recognitionIsWarm)
        XCTAssertEqual(coordinator.recognitionTimeout, 10)
        XCTAssertEqual(copied, ["Synthetic OCR"], "A slow first result reaches the existing clipboard commit exactly once")
        XCTAssertNil(coordinator.operation)
        XCTAssertTrue(coordinator.noticeIsVisible)
    }

    @MainActor
    func testTimeoutAndRepeatedInvocationsDoNotAccumulateWorkersOrAcceptLateResults() async throws {
        let coordinator = RCOCRCoordinator()
        defer { coordinator.cancel() }
        let id = UUID(), cell = RCOCRCancellation(), held = RCHeldRecognition()
        var now = 100.0
        coordinator.uptime = { now }
        coordinator.adoptOperationForTesting(id)
        coordinator.beginRecognition(cell: cell, id: id)
        let started = expectation(description: "recognition started")
        let task = coordinator.recognizeCrop(try image(), id: id, settings: settings, cell: cell) { _, _, _ in
            try await held.run(started: started)
        }
        await fulfillment(of: [started], timeout: 2)
        now += 61
        XCTAssertNil(coordinator.checkDeadline(id: id))
        XCTAssertNil(coordinator.operation)
        XCTAssertThrowsError(try cell.check())
        for _ in 0..<5 { coordinator.invokeFromApplication(nil) }
        XCTAssertTrue(coordinator.workerBusy, "An unreturned system call must still own the single worker slot")
        XCTAssertNil(coordinator.operation)
        // Even an uncooperative dependency returning success after cancel cannot commit.
        coordinator.cancel()
        await held.succeed()
        await task.value
        XCTAssertFalse(coordinator.workerBusy)
        XCTAssertNil(coordinator.operation)
        XCTAssertFalse(coordinator.noticeIsVisible)
    }

    @MainActor
    func testPressAgainCancelsColdRecognitionAndReleasesSlotWhenWorkerReturns() async throws {
        let coordinator = RCOCRCoordinator()
        defer { coordinator.cancel() }
        let id = UUID(), cell = RCOCRCancellation(), held = RCHeldRecognition()
        coordinator.adoptOperationForTesting(id)
        coordinator.beginRecognition(cell: cell, id: id)
        let started = expectation(description: "recognition started")
        let task = coordinator.recognizeCrop(try image(), id: id, settings: settings, cell: cell) { _, _, _ in
            try await held.run(started: started)
        }
        await fulfillment(of: [started], timeout: 2)
        coordinator.invokeFromApplication(nil)
        XCTAssertNil(coordinator.operation)
        XCTAssertThrowsError(try cell.check())
        await held.succeed()
        await task.value
        XCTAssertFalse(coordinator.workerBusy)
        XCTAssertFalse(coordinator.noticeIsVisible)
    }
}
