import Foundation
import CoreGraphics

/// Model preparation is separate from the eight-second recognition budget. The
/// stamp is a hint, not an authority: timeout/engine failure invalidates it.
@MainActor
final class RCOCRWorkerService {
    static let shared = RCOCRWorkerService()
    private let defaults: UserDefaults
    private let stampKey = "RCOCRPreparedModelsV1"
    private struct Preparation {
        let id: UUID
        let signature: String
        let cell: RCOCRCancellation
        let task: Task<Void, Error>
    }
    private var preparation: Preparation?
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func signature(settings: RCOCRSettings, executable: URL) -> String {
        let metadata = try? FileManager.default.attributesOfItem(atPath: executable.path)
        let modified = (metadata?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (metadata?[.size] as? NSNumber)?.uint64Value ?? 0
        // Locale/model inputs and the helper identity are bounded local metadata;
        // no captured content is ever part of this key.
        return ["1", ProcessInfo.processInfo.operatingSystemVersionString, executable.path,
                String(modified), String(size), settings.language, String(settings.correction),
                settings.preferredLanguages.joined(separator: ",")].joined(separator: "|")
    }
    func cancelPreparation() { preparation?.cell.cancel() }

    func ensurePrepared(settings: RCOCRSettings, cancellation: RCOCRCancellation,
                        executable: URL = RCOCRWorkerClient.executableURL,
                        preparing: @MainActor (Bool) -> Void = { _ in },
                        prepare: @escaping @Sendable (RCOCRSettings, RCOCRCancellation, URL) throws -> Void = { settings, cell, executable in
                            try RCOCRWorkerService.prepareModels(settings: settings, cancellation: cell, executable: executable)
                        }) async throws {
        try cancellation.check()
        let signature = signature(settings: settings, executable: executable)
        if defaults.string(forKey: stampKey) == signature { return }
        preparing(true)
        defer { preparing(false) }
        if let old = preparation, old.signature != signature {
            old.cell.cancel()
            _ = await old.task.result
            if preparation?.id == old.id { preparation = nil }
            return try await ensurePrepared(settings: settings, cancellation: cancellation, executable: executable,
                                            preparing: preparing, prepare: prepare)
        }
        try cancellation.check()
        let current: Preparation
        if let existing = preparation { current = existing }
        else {
            let cell = RCOCRCancellation()
            current = Preparation(id: UUID(), signature: signature, cell: cell,
                task: Task.detached(priority: .utility) { try prepare(settings, cell, executable) })
            preparation = current
        }
        do {
            try cancellation.installWorker { current.cell.cancel() }
            defer { cancellation.releaseWorker() }
            try await current.task.value
            try current.cell.check()
            try cancellation.check()
            if preparation?.id == current.id {
                defaults.set(signature, forKey: stampKey)
                preparation = nil
            }
        } catch {
            current.cell.cancel()
            // Cancellation cannot release ownership before the child is reaped.
            _ = await current.task.result
            if preparation?.id == current.id { preparation = nil }
            throw error
        }
    }
    nonisolated static func prepareModels(settings: RCOCRSettings, cancellation: RCOCRCancellation, executable: URL) throws {
        guard let image = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage() else {
            throw RCOCRError.workerFailed
        }
        _ = try RCOCRWorkerClient.recognize(image, settings: settings, cancellation: cancellation,
            executable: executable, timeout: RCOCRWorkerClient.preparationTimeout, prepareOnly: true)
    }
    func recognize(_ image: CGImage, settings: RCOCRSettings, cancellation: RCOCRCancellation,
                   executable: URL = RCOCRWorkerClient.executableURL,
                   preparing: @MainActor (Bool) -> Void) async throws -> RCOCRRecognition {
        try await ensurePrepared(settings: settings, cancellation: cancellation, executable: executable, preparing: preparing)
        try cancellation.check()
        do {
            return try await Task.detached(priority: .userInitiated) {
                try RCOCRWorkerClient.recognize(image, settings: settings, cancellation: cancellation, executable: executable)
            }.value
        } catch {
            switch error {
            case RCOCRError.noText, RCOCRError.cancelled, RCOCRError.inputTooLarge, RCOCRError.unsupportedLanguage: break
            default: defaults.removeObject(forKey: stampKey)
            }
            throw error
        }
    }
}
