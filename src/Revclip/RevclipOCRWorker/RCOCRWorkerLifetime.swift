import Foundation
import Darwin

/// The production GCD callbacks are also exercised in a standalone subprocess,
/// without invoking Vision or terminating the XCTest host.
final class RCOCRWorkerLifetime {
    private let parentExit: DispatchSourceProcess
    private let lifetime: DispatchSourceTimer

    init(parentPID: pid_t, timeout: Double) {
        parentExit = DispatchSource.makeProcessSource(identifier: parentPID, eventMask: .exit, queue: .global(qos: .utility))
        // Explicit Sendable prevents callbacks from inheriting MainActor when
        // constructed by a Swift 6 executable. Both execute on a global queue.
        parentExit.setEventHandler { @Sendable in _exit(1) }
        parentExit.resume()
        lifetime = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        lifetime.setEventHandler { @Sendable in _exit(124) }
        lifetime.schedule(deadline: .now() + timeout)
        lifetime.resume()
    }

    deinit { parentExit.cancel(); lifetime.cancel() }
}
