import XCTest
@testable import Revclip

private final class RCPreparationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
final class RCOCRPreparationTests: XCTestCase {
    @MainActor private func service() -> RCOCRWorkerService {
        let name = "RCOCRPreparationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return RCOCRWorkerService(defaults: defaults)
    }
    private let settings = RCOCRSettings(language: "auto", correction: false, preferredLanguages: ["ja", "en"])

    @MainActor func testSuccessfulPreparationIsReusedButLanguageChangeRequiresPreparation() async throws {
        let service = service(), counter = RCPreparationCounter()
        var states: [Bool] = []
        for _ in 0..<2 {
            try await service.ensurePrepared(settings: settings, cancellation: RCOCRCancellation(),
                preparing: { states.append($0) }, prepare: { _, _, _ in counter.increment() })
        }
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(states, [true, false])
        let changed = RCOCRSettings(language: "en-US", correction: false, preferredLanguages: ["ja", "en"])
        try await service.ensurePrepared(settings: changed, cancellation: RCOCRCancellation(), prepare: { _, _, _ in counter.increment() })
        XCTAssertEqual(counter.value, 2)
    }
    @MainActor func testFailedPreparationIsNotMarkedReady() async throws {
        let service = service(), counter = RCPreparationCounter()
        do {
            try await service.ensurePrepared(settings: settings, cancellation: RCOCRCancellation(), prepare: { _, _, _ in
                throw RCOCRError.workerFailed
            })
            XCTFail("Failure was accepted")
        } catch {}
        try await service.ensurePrepared(settings: settings, cancellation: RCOCRCancellation(), prepare: { _, _, _ in counter.increment() })
        XCTAssertEqual(counter.value, 1)
    }
    @MainActor func testCancelDuringPreparationStopsDependencyAndAllowsFreshAttempt() async throws {
        let service = service(), cell = RCOCRCancellation()
        let started = expectation(description: "preparation started")
        let settings = settings
        let task = Task { @MainActor in
            try await service.ensurePrepared(settings: settings, cancellation: cell, prepare: { _, workerCell, _ in
                let gate = DispatchSemaphore(value: 0)
                try workerCell.installWorker { gate.signal() }
                defer { workerCell.releaseWorker() }
                started.fulfill()
                guard gate.wait(timeout: .now() + 3) == .success else { throw RCOCRError.workerFailed }
                try workerCell.check()
            })
        }
        await fulfillment(of: [started], timeout: 2)
        cell.cancel()
        do { try await task.value; XCTFail("Cancelled preparation succeeded") }
        catch { guard case RCOCRError.cancelled = error else { return XCTFail("Unexpected \(error)") } }
        try await service.ensurePrepared(settings: settings, cancellation: RCOCRCancellation(), prepare: { _, _, _ in })
    }
    @MainActor func testConcurrentWaitersShareOnePreparation() async throws {
        let service = service(), counter = RCPreparationCounter(), settings = settings
        let started = expectation(description: "preparation started")
        let gate = DispatchSemaphore(value: 0)
        let prepare: @Sendable (RCOCRSettings, RCOCRCancellation, URL) throws -> Void = { _, _, _ in
            counter.increment(); started.fulfill()
            guard gate.wait(timeout: .now() + 3) == .success else { throw RCOCRError.workerFailed }
        }
        let first = Task { try await service.ensurePrepared(settings: settings, cancellation: RCOCRCancellation(), prepare: prepare) }
        await fulfillment(of: [started], timeout: 2)
        let secondStarted = expectation(description: "second waiting")
        let second = Task {
            try await service.ensurePrepared(settings: settings, cancellation: RCOCRCancellation(),
                preparing: { if $0 { secondStarted.fulfill() } }, prepare: prepare)
        }
        await fulfillment(of: [secondStarted], timeout: 2)
        gate.signal()
        try await first.value; try await second.value
        XCTAssertEqual(counter.value, 1)
    }
}
