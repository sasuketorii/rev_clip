import Foundation
import Darwin

// Compile with the production RCOCRWorkerLifetime.swift. No Vision, capture,
// pasteboard or history is involved; each process must exit from the callback.
let mode = CommandLine.arguments.last!
var watchedProcess: Process?
let watchedPID: pid_t
if mode == "parent" {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["0.2"]
    try process.run()
    watchedProcess = process
    watchedPID = process.processIdentifier
} else {
    watchedPID = getppid()
}
let watchdog = RCOCRWorkerLifetime(parentPID: watchedPID, timeout: mode == "timer" ? 0.1 : 5)
Thread.sleep(forTimeInterval: 10)
withExtendedLifetime(watchdog) {}
exit(99)
