import Foundation
import os
import AppKit
import Darwin

// The application watchdog is not enough if its process crashes. These sources
// exist only for this child's lifetime and never poll or keep an idle service up.
let parentPID = getppid()
guard parentPID > 1 else { exit(1) }
let parentExit = DispatchSource.makeProcessSource(identifier: parentPID, eventMask: .exit, queue: .global(qos: .utility))
parentExit.setEventHandler { _exit(1) }
parentExit.resume()
guard getppid() == parentPID else { exit(1) }
let lifetime = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
lifetime.setEventHandler { _exit(124) }
lifetime.schedule(deadline: .now() + RCOCRWorkerProtocol.preparationTimeout + 5)
lifetime.resume()
defer { parentExit.cancel(); lifetime.cancel() }

func prepareModels(settings: RCOCRSettings) throws {
    let languages = try RCVisionTextRecognizer.languages(for: settings, supported: RCVisionTextRecognizer.supportedLanguages())
    let samples = ["ja": "画面の文字を認識します。", "en": "Recognize screen text 123 https://example.com",
                   "zh": "识别屏幕上的文字。", "ko": "화면의 문자를 인식합니다.",
                   "fr": "Reconnaître le texte à l’écran.", "de": "Text auf dem Bildschirm erkennen.",
                   "es": "Reconocer texto en la pantalla.", "pt": "Reconhecer texto na tela.",
                   "it": "Riconoscere il testo sullo schermo.", "ru": "Распознавание текста на экране.",
                   "uk": "Розпізнавання тексту на екрані.", "ar": "التعرف على النص على الشاشة",
                   "th": "อ่านข้อความบนหน้าจอ", "vi": "Nhận dạng văn bản trên màn hình.",
                   "hi": "स्क्रीन पर लिखे पाठ को पहचानें।", "mr": "स्क्रीनवरील मजकूर ओळखा.",
                   "yu": "識別螢幕上的文字。", "tr": "Ekrandaki metni tanıyın.",
                   "id": "Kenali teks di layar.", "cs": "Rozpoznat text na obrazovce.",
                   "da": "Genkend tekst på skærmen.", "nl": "Tekst op het scherm herkennen.",
                   "no": "Gjenkjenn tekst på skjermen.", "nn": "Kjenn att tekst på skjermen.",
                   "nb": "Gjenkjenn tekst på skjermen.", "ms": "Kenali teks pada skrin.",
                   "pl": "Rozpoznaj tekst na ekranie.", "ro": "Recunoaște textul de pe ecran.",
                   "sv": "Känn igen text på skärmen.", "fi": "Tunnista näytön teksti."]
    for language in languages {
        try autoreleasepool {
            let sample = samples[String(language.prefix(2))] ?? "Screen text 123"
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 160,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { throw RCOCRError.workerFailed }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1280, height: 160).fill()
            sample.draw(at: CGPoint(x: 20, y: 60), withAttributes: [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState()
            guard let image = bitmap.cgImage else { throw RCOCRError.workerFailed }
            _ = try RCVisionTextRecognizer.recognizeCrop(image, settings: settings, cancellation: RCOCRCancellation())
        }
    }
}

// Private stdin/stdout protocol. No arguments, disk images, capture permission,
// clipboard access, history access, or network requests.
let response: RCOCRWorkerProtocol.Response = autoreleasepool {
    do {
        let (image, settings, prepareOnly) = try RCOCRWorkerProtocol.readRequest(from: .standardInput)
        lifetime.schedule(deadline: .now() + (prepareOnly ? RCOCRWorkerProtocol.preparationTimeout : RCOCRWorkerProtocol.recognitionTimeout) + 2)
        if prepareOnly {
            try prepareModels(settings: settings)
            return .init(result: .init(text: "", lines: [], languages: [], revision: 3, seconds: 0), failure: nil)
        }
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
