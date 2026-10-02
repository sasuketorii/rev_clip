import Foundation
import CoreGraphics
import os
import Darwin

/// A request owns one short-lived child. Killing that child actually stops Vision;
/// VNRequest.cancel alone cannot interrupt a stuck model compiler in this process.
enum RCOCRWorkerClient {
    static let timeout = RCOCRWorkerProtocol.recognitionTimeout
    private static let log = Logger(subsystem: "com.revclip", category: "OCRWorker")
    static var executableURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/revclip-ocr")
    }
    static func recognize(_ image: CGImage, settings: RCOCRSettings, cancellation: RCOCRCancellation,
                          executable: URL = executableURL, timeout: Double = timeout) throws -> RCOCRRecognition {
        try cancellation.check()
        let child = RCOCRChildProcess(executable: executable)
        try cancellation.installWorker { child.stop() }
        defer { cancellation.releaseWorker() }
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.setEventHandler { child.stop(timedOut: true) }
        watchdog.schedule(deadline: .now() + timeout)
        watchdog.resume()
        defer { watchdog.cancel(); child.finish() }
        try child.start()
        let began = ProcessInfo.processInfo.systemUptime
        do {
            try RCOCRWorkerProtocol.writeRequest(image: image, settings: settings, to: child.input.fileHandleForWriting)
            try child.input.fileHandleForWriting.close()
            let result = try RCOCRWorkerProtocol.readResponse(from: child.output.fileHandleForReading)
            child.process.waitUntilExit()
            try cancellation.check()
            if child.didTimeOut { throw RCOCRError.timedOut }
            guard child.process.terminationStatus == 0 else { throw RCOCRError.workerFailed }
            log.info("recognition succeeded seconds=\(ProcessInfo.processInfo.systemUptime - began)")
            return result
        } catch {
            child.stop()
            child.process.waitUntilExit()
            try cancellation.check()
            if child.didTimeOut { throw RCOCRError.timedOut }
            log.error("recognition failed domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code)")
            throw error
        }
    }
}

private final class RCOCRChildProcess: @unchecked Sendable {
    let process = Process()
    let input = Pipe(), output = Pipe()
    private let lock = NSLock()
    private var stopped = false
    private var expired = false
    var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return expired }
    init(executable: URL) {
        process.executableURL = executable
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // A timeout may close the child's reader while pixels are being written.
        // Suppress SIGPIPE only on this descriptor, never process-wide.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }
    func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { throw expired ? RCOCRError.timedOut : RCOCRError.cancelled }
        try process.run()
        // Only the child owns these ends now. EOF must arrive when it is killed.
        try input.fileHandleForReading.close()
        try output.fileHandleForWriting.close()
    }
    func stop(timedOut: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        if timedOut { expired = true }
        if process.isRunning {
            // No cooperative cancellation or shutdown hook in the ML runtime may
            // keep this private child alive and hold the next OCR request hostage.
            kill(process.processIdentifier, SIGKILL)
        }
    }
    func finish() {
        stop()
        if process.isRunning { process.waitUntilExit() }
        try? input.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
    }
}
