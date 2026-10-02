import Foundation
import os
import AppKit
import Darwin

// The application watchdog is not enough if its process crashes. These sources
// exist only for this child's lifetime and never poll or keep an idle service up.
let parentPID = getppid()
guard parentPID > 1 else { exit(1) }
let lifetime = RCOCRWorkerLifetime(parentPID: parentPID, timeout: RCOCRWorkerProtocol.recognitionTimeout + 2)
guard getppid() == parentPID else { exit(1) }

// Private stdin/stdout protocol. No arguments, disk images, capture permission,
// clipboard access, history access, or network requests.
let response: RCOCRWorkerProtocol.Response = autoreleasepool {
    do {
        let (image, settings) = try RCOCRWorkerProtocol.readRequest(from: .standardInput)
        let result = try RCVisionTextRecognizer.recognizeCrop(image, settings: settings, cancellation: RCOCRCancellation())
        return .init(result: .init(text: result.text, lines: [], languages: result.languages,
                                  revision: result.revision, seconds: result.seconds), failure: nil)
    } catch {
        Logger(subsystem: "com.revclip", category: "OCRWorker").error(
            "Vision failed domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code)")
        let failure: String
        switch error {
        case RCOCRError.noText: failure = "noText"
        case RCOCRError.unsupportedLanguage: failure = "unsupportedLanguage"
        case RCOCRError.inputTooLarge: failure = "inputTooLarge"
        default: failure = "recognitionFailed"
        }
        return .init(result: nil, failure: failure)
    }
}
do {
    let data = try JSONEncoder().encode(response)
    guard data.count <= RCOCRWorkerProtocol.maximumResponseBytes else { exit(1) }
    try FileHandle.standardOutput.write(contentsOf: data)
} catch { exit(1) }
