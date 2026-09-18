import AppKit

@MainActor
@objc(RCOCRPreferencesController)
final class RCOCRPreferencesController: NSViewController, @preconcurrency RCHotKeyRecorderViewDelegate {
    private let enabledControl = NSSwitch()
    private let historyControl = NSSwitch()
    private let correctionControl = NSSwitch()
    private let languages = NSPopUpButton()
    private let recorder = RCHotKeyRecorderView()
    private let shortcutWarning = NSTextField(wrappingLabelWithString: "")
    private func text(_ key: String) -> String { RCLocalizedString(key, comment: "") }
    private let historyStatus = NSTextField(wrappingLabelWithString: "")
    private var unsupportedItem: NSMenuItem?
    override func loadView() {
        for control in [enabledControl, historyControl, correctionControl] { control.target = self; control.action = #selector(changed(_:)) }
        recorder.delegate = self
        recorder.warningLabel = shortcutWarning
        shortcutWarning.textColor = .systemYellow
        languages.addItem(withTitle: text("OCR Automatic")); languages.lastItem?.representedObject = "auto"
        languages.addItem(withTitle: text("OCR Japanese English")); languages.lastItem?.representedObject = "ja-en"
        do {
            for language in try RCVisionTextRecognizer.supportedLanguages() {
                languages.addItem(withTitle: Locale.current.localizedString(forIdentifier: language) ?? language)
                languages.lastItem?.representedObject = language
            }
        } catch { languages.toolTip = text("OCR Unsupported Language") }
        languages.target = self; languages.action = #selector(languageChanged)
        let explanation = NSTextField(wrappingLabelWithString: text("OCR Settings Help"))
        explanation.font = .systemFont(ofSize: 12); explanation.textColor = .secondaryLabelColor
        explanation.preferredMaxLayoutWidth = 400
        let correctionHelp = NSTextField(wrappingLabelWithString: text("OCR Correction Help"))
        correctionHelp.font = .systemFont(ofSize: 12); correctionHelp.textColor = .secondaryLabelColor
        correctionHelp.preferredMaxLayoutWidth = 380
        view = RCPreferencesPage(rows: [
            [text("OCR Copy Screen Text"), enabledControl],
            [text("OCR Shortcut"), recorder],
            ["", shortcutWarning],
            [text("OCR Language"), languages],
            [text("OCR Correction"), correctionControl],
            ["", correctionHelp],
            [text("OCR Save History"), historyControl],
            ["", historyStatus],
            ["", explanation]
        ])
        historyStatus.font = .systemFont(ofSize: 12); historyStatus.textColor = .secondaryLabelColor
        historyStatus.preferredMaxLayoutWidth = 380
        reloadValues()
    }
    // Every control is re-read, not only the shortcut: the CLI and the other pages
    // change the same values while this page is loaded.
    override func viewWillAppear() {
        super.viewWillAppear(); reloadValues()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(reloadValues), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(reloadValues), name: .RCSettingsDidChange, object: nil)
        center.addObserver(self, selector: #selector(reloadValues), name: .RCClipboardAccessStateDidChange, object: nil)
    }
    override func viewWillDisappear() { super.viewWillDisappear(); NotificationCenter.default.removeObserver(self) }
    @objc private func reloadValues() {
        enabledControl.state = RCOCRCoordinator.bool(kRCOCREnabledKey, fallback: true) ? .on : .off
        historyControl.state = RCOCRCoordinator.bool(kRCOCRSaveHistoryKey, fallback: true) ? .on : .off
        correctionControl.state = RCOCRCoordinator.bool(kRCOCRCorrectionKey, fallback: false) ? .on : .off
        recorder.keyCombo = RCHotKeyService.shared().configuredKeyCombo(forSlot: RCHotKeySlotOCR)
        let saved = UserDefaults.standard.string(forKey: kRCOCRLanguageKey) ?? "auto"
        if let unsupportedItem, languages.itemArray.contains(unsupportedItem) { languages.menu?.removeItem(unsupportedItem) }
        unsupportedItem = nil
        if let item = languages.itemArray.first(where: { $0.representedObject as? String == saved }) { languages.select(item) }
        else {
            // Shown as unsupported, never silently replaced by another language.
            languages.addItem(withTitle: text("OCR Unsupported Language")); languages.lastItem?.representedObject = saved
            unsupportedItem = languages.lastItem
            languages.select(languages.lastItem)
        }
        historyStatus.stringValue = Self.historyStatusKey(saveEnabled: historyControl.state == .on,
            access: RCPrivacyService.shared().clipboardAccessState()).map(text) ?? ""
        historyStatus.isHidden = historyStatus.stringValue.isEmpty
    }
    /// Why a recognized text is copied but not stored, shown here instead of as one
    /// more notice after every copy. nil while results are stored.
    static func historyStatusKey(saveEnabled: Bool, access: RCClipboardAccessState) -> String? {
        guard saveEnabled else { return nil }
        return access == .granted ? nil : "OCR History Needs Clipboard Access"
    }
    @objc private func changed(_ sender: NSSwitch) {
        if sender === enabledControl, sender.state == .on, let key = RCOCRCoordinator.enableRefusalKey() {
            // Same refusal as the CLI; the switch stays off and nothing is stored.
            reloadValues()
            let alert = NSAlert(); alert.messageText = text(key); alert.runModal()
            return
        }
        if sender === enabledControl {
            // Switching the feature changes whether its shortcut is registered, through
            // the same contract as assigning it. A refusal leaves the switch where it was.
            let enabled = sender.state == .on
            var transaction: AnyObject?
            let result = RCHotKeyService.shared().prepare([RCHotKeyAssignment(keepingSlot: RCHotKeySlotOCR)],
                ocrEnabledAfterCommit: NSNumber(value: enabled), transaction: &transaction)
            guard result.succeeded, let transaction else {
                reloadValues(); recorder.show(result); return
            }
            RCHotKeyService.shared().commitPreparedAssignments(transaction)
            UserDefaults.standard.set(enabled, forKey: kRCOCREnabledKey)
        } else {
            UserDefaults.standard.set(sender.state == .on, forKey: sender === historyControl ? kRCOCRSaveHistoryKey : kRCOCRCorrectionKey)
        }
        reloadValues()
    }
    @objc private func languageChanged() { UserDefaults.standard.set(languages.selectedItem?.representedObject as? String, forKey: kRCOCRLanguageKey) }
    func hotKeyRecorderView(_ recorderView: RCHotKeyRecorderView, didRecord keyCombo: RCKeyCombo) {
        apply(RCHotKeyAssignment(settingSlot: RCHotKeySlotOCR, combo: keyCombo))
    }
    func hotKeyRecorderViewDidClearKeyCombo(_ recorderView: RCHotKeyRecorderView) {
        apply(RCHotKeyAssignment(clearingSlot: RCHotKeySlotOCR))
    }
    private func apply(_ assignment: RCHotKeyAssignment) {
        let result = RCHotKeyService.shared().apply([assignment])
        reloadValues()
        recorder.show(result)
    }
}
