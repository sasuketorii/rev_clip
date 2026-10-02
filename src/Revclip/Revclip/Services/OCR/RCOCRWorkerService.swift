import Foundation
import CoreGraphics

/// Recognize the actual crop in one bounded child. Neither a UserDefaults stamp
/// nor successful inference on a sample proves the OS models are ready for this
/// crop. The coordinator owns admission; only immutable pixels cross executors.
@MainActor
final class RCOCRWorkerService {
    static let shared = RCOCRWorkerService()

    func recognize(_ image: CGImage, settings: RCOCRSettings, cancellation: RCOCRCancellation,
                   executable: URL = RCOCRWorkerClient.executableURL,
                   using recognize: @escaping @Sendable (CGImage, RCOCRSettings, RCOCRCancellation, URL) throws -> RCOCRRecognition = {
                       try RCOCRWorkerClient.recognize($0, settings: $1, cancellation: $2, executable: $3)
                   }) async throws -> RCOCRRecognition {
        try cancellation.check()
        let result = try await Task.detached(priority: .userInitiated) {
            try recognize(image, settings, cancellation, executable)
        }.value
        try cancellation.check()
        return result
    }
}
