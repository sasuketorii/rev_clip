import AppKit
import os
import ScreenCaptureKit

/// Which of this process's windows are kept out of the frozen OCR frame.
enum RCOCRCaptureExclusion {
    /// Revclip's short-lived chrome: floating notices and previews, and menu-level
    /// windows and above. Normal windows and the status item stay in the frame.
    static func isTransient(layer: Int) -> Bool {
        layer == Int(CGWindowLevelForKey(.floatingWindow)) || layer >= Int(CGWindowLevelForKey(.popUpMenuWindow))
    }
    static func partition<Window>(_ windows: [Window], processID: pid_t, owner: (Window) -> pid_t?,
                                  layer: (Window) -> Int) -> (excluded: [Window], kept: [Window]) {
        let own = windows.filter { owner($0) == processID }
        return (own.filter { isTransient(layer: layer($0)) }, own.filter { !isTransient(layer: layer($0)) })
    }
}

/// Which screen holds the pointer, in AppKit's global coordinates.
enum RCOCRScreenHitTest {
    /// The pointer's x lies in [minX, maxX) and its y in (minY, maxY]: the top pixel row
    /// reports y == maxY. This is exactly that range (NSMouseInRect, not flipped), so a
    /// point on the border of two adjacent screens belongs to one of them only and no
    /// rounding tolerance is involved. A point inside no frame is a failure, not a guess.
    static func index(of point: CGPoint, in frames: [CGRect]) -> Int? {
        frames.firstIndex { point.x >= $0.minX && point.x < $0.maxX && point.y > $0.minY && point.y <= $0.maxY }
    }
}

@MainActor
@objc(RCOCRCoordinator)
final class RCOCRCoordinator: NSObject {
    @objc static let shared = RCOCRCoordinator()
    private static let log = Logger(subsystem: "com.revclip", category: "RCOCRCoordinator")
    private(set) var operation: UUID?
    private var context: RCOCRCommitContext?
    private var cancellation: RCOCRCancellation?
    private(set) var workerBusy = false
    // Vision initializes its models lazily. A cold run must not inherit the
    // steady-state deadline; successful initialization lasts for this process.
    private(set) var recognitionIsWarm = false
    var recognitionTimeout: Double { recognitionIsWarm ? 10 : 60 }
    private var historyPending = false
    private var selection: RCOCRSelectionController?
    private var frame: CGImage?
    private var timer: Timer?
    private var deadlineLength = 0.0
    private var lastActivity = 0.0
    var uptime: () -> Double = { ProcessInfo.processInfo.systemUptime }
    // Time of the input event that started the current operation; 0 when unknown.
    private var startingEventTime = 0.0
    private var noticeTimer: Timer?
    private var notice: NSPanel?
    private var permissionAlert: NSAlert?
    private var activeSettings: RCOCRSettings?
    private var observing = false
    private var enabled = true
    private var saveHistory = true
    var screenCaptureAccess: () -> Bool = { CGPreflightScreenCaptureAccess() }
    var commitRecognition: @MainActor (String, RCOCRCommitContext) async -> RCOCRCommitResult = { text, context in
        await RCClipboardService.shared().commitRecognizedText(text, context: context)
    }

    @objc static func unavailableReason() -> String? {
        guard #available(macOS 14.0, *) else { return RCLocalizedString("OCR OS Unsupported", comment: "") }
        return nil
    }
    @objc func startObserving() {
        guard !observing else { return }; observing = true
        enabled = Self.bool(kRCOCREnabledKey, fallback: true)
        saveHistory = Self.bool(kRCOCRSaveHistoryKey, fallback: true)
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(hotKeyTriggered(_:)), name: .RCHotKeyOCRTriggered, object: nil)
        nc.addObserver(self, selector: #selector(lifecycleStopped), name: .RCClipboardLifecycleDidStop, object: nil)
        nc.addObserver(self, selector: #selector(hotKeyFailed(_:)), name: .RCHotKeyRegistrationDidFail, object: nil)
        nc.addObserver(self, selector: #selector(settingsChanged), name: UserDefaults.didChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(displayChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        nc.addObserver(self, selector: #selector(invalidate), name: NSApplication.willTerminateNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            workspace.addObserver(self, selector: #selector(invalidate), name: name, object: nil)
        }
        workspace.addObserver(self, selector: #selector(displayChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(invalidate), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
    }
    static func bool(_ key: String, fallback: Bool) -> Bool { (UserDefaults.standard.object(forKey: key) as? NSNumber)?.boolValue ?? fallback }
    @objc nonisolated private func lifecycleStopped() {
        // stopMonitoring may originate off-main; invalidate admission there via
        // its generation, then close UI on main without synchronously waiting.
        if Thread.isMainThread { MainActor.assumeIsolated { invalidate() } } else { DispatchQueue.main.async { self.invalidate() } }
    }
    @objc nonisolated private func settingsChanged() {
        if Thread.isMainThread { MainActor.assumeIsolated { applySettingsChange() } }
        else { DispatchQueue.main.async { self.applySettingsChange() } }
    }
    private func applySettingsChange() {
        let newEnabled = Self.bool(kRCOCREnabledKey, fallback: true)
        let newSave = Self.bool(kRCOCRSaveHistoryKey, fallback: true)
        // Only the switch going off stops work. Reacting to every unrelated defaults
        // write while disabled would also dismiss the notice that says it is disabled.
        if enabled && !newEnabled { invalidate() }
        if saveHistory && !newSave, let context { RCClipboardService.shared().disableHistory(forOCRContext: context) }
        if enabled != newEnabled { enabled = newEnabled; RCHotKeyService.shared().reloadOCRHotKey() }
        saveHistory = newSave
    }
    @objc private func hotKeyFailed(_ notification: Notification) {
        guard (notification.userInfo?[RCHotKeyRegistrationFailureIdentifierUserInfoKey] as? NSNumber)?.intValue == 5 else { return }
        // Either another Revclip feature (named) or an OS refusal. Another application
        // using the same keys does not fail registration, so it is never blamed here.
        if let slot = notification.userInfo?[RCHotKeyRegistrationFailureConflictingSlotUserInfoKey] as? String {
            showNoticeText(String(format: RCLocalizedString("OCR Shortcut Internal Conflict", comment: ""),
                                  RCHotKeyRecorderView.localizedName(forSlot: slot)))
        } else {
            showNotice("OCR Shortcut Conflict")
        }
    }
    @objc private func displayChanged() {
        // A request still waiting behind a menu chose its display before the change.
        // Recognition that already owns an independent crop is left running.
        invalidationEpoch &+= 1
        if frame != nil || selection != nil || (operation != nil && cancellation == nil) { cancel() }
    }
    @objc func cancel() {
        if let permissionAlert {
            if NSApp.modalWindow === permissionAlert.window { NSApp.abortModal() }
            permissionAlert.window.orderOut(nil)
            self.permissionAlert = nil
        }
        operation = nil; startingEventTime = 0
        if let context { RCClipboardService.shared().cancelOCRContext(context) }
        context = nil; activeSettings = nil
        cancellation?.cancel(); cancellation = nil
        timer?.invalidate(); timer = nil
        selection?.close(); selection = nil; frame = nil
        dismissNotice()
    }
    private func deadline(_ seconds: Double, id: UUID) {
        timer?.invalidate()
        deadlineLength = seconds; lastActivity = uptime()
        armDeadline(after: seconds, id: id)
    }
    private func armDeadline(after seconds: Double, id: UUID) {
        timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.operation == id else { return }
                // Pointer activity only records a time; the one timer re-arms itself for
                // what is left, instead of being rebuilt on every drag event.
                if let remaining = self.checkDeadline(id: id) { self.armDeadline(after: remaining, id: id) }
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    // Shared by the real timer and deterministic delayed-worker tests.
    func checkDeadline(id: UUID) -> Double? {
        guard operation == id else { return nil }
        let remaining = deadlineLength - (uptime() - lastActivity)
        if remaining > 0.05 { return remaining }
        cancel(); showNotice("OCR Timed Out")
        return nil
    }
    private func noteActivity() { lastActivity = uptime() }
    /// Installed by RCMenuManager: runs the block once no Revclip menu is tracking.
    /// The hotkey can arrive while the status menu is open; that menu must close
    /// through AppKit's own teardown before the screen is frozen.
    @objc var menuTrackingGate: ((@escaping () -> Void) -> Void)?
    // Advanced by every external stop (Clear, Panic, quit, lock, sleep, feature off).
    // A request still waiting behind a menu holds no ticket yet, so this is what
    // keeps it from starting a fresh operation after the stop.
    private(set) var invalidationEpoch: UInt64 = 0
    // Advanced only by those stops, not by a display or Space change: recognition that
    // already owns its crop survives that change, and so does the report of its result.
    private(set) var stopEpoch: UInt64 = 0
    // A stop that originates off the main thread reaches invalidate() asynchronously,
    // so the clipboard service's own generation is compared as well: it has already
    // advanced by the time a stop and restart could let a stale request through.
    var monitoringGeneration: () -> UInt = { RCClipboardService.shared().monitoringGeneration }
    @objc func invoke() { request(fromApplication: NSWorkspace.shared.frontmostApplication, eventTime: 0, origin: "direct") }
    @objc private func hotKeyTriggered(_ notification: Notification) {
        let time = (notification.userInfo?[RCHotKeyEventTimestampUserInfoKey] as? NSNumber)?.doubleValue ?? 0
        // The app in front when the key was pressed, not after the menu has gone.
        request(fromApplication: NSWorkspace.shared.frontmostApplication, eventTime: time, origin: "hotkey")
    }
    @objc func request(fromApplication source: NSRunningApplication?) {
        request(fromApplication: source, eventTime: NSApp.currentEvent?.timestamp ?? 0, origin: "menu")
    }
    /// Whether two requests describe one physical key press. Both times are seconds
    /// since system start-up (GetEventTime, NSEvent.timestamp). That the hot key event
    /// carries the key's own time is not established, so this only ever recognises a
    /// positive match: a missing or zero time, or any difference a person could produce
    /// by pressing again, is a separate request.
    static func isSameInput(_ first: Double, _ second: Double) -> Bool {
        first > 0 && second > 0 && abs(first - second) <= 0.002
    }
    /// Single entry for the hotkey and the menu command.
    func request(fromApplication source: NSRunningApplication?, eventTime: Double, origin: String) {
        Self.log.debug("request origin=\(origin, privacy: .public) eventTime=\(eventTime) active=\(self.operation != nil)")
        // A menu key equivalent and the global hot key can both report one key press.
        // The second report must not act as the "press again to cancel" of the first.
        if operation != nil, Self.isSameInput(startingEventTime, eventTime) {
            Self.log.debug("request ignored: same input event as the running operation")
            return
        }
        let epoch = invalidationEpoch, monitoring = monitoringGeneration()
        let start: () -> Void = { [weak self] in
            guard let self, self.invalidationEpoch == epoch, self.monitoringGeneration() == monitoring else { return }
            if self.operation != nil, Self.isSameInput(self.startingEventTime, eventTime) { return }
            let wasIdle = self.operation == nil
            self.invokeFromApplication(source)
            if wasIdle, self.operation != nil { self.startingEventTime = eventTime }
        }
        if let menuTrackingGate { menuTrackingGate(start) } else { start() }
    }
    @objc private func invalidate() { invalidationEpoch &+= 1; stopEpoch &+= 1; cancel() }
    /// Whether the result of an accepted commit is shown. Clear, Panic, quit, lock,
    /// sleep and switching the feature off silence it completely, whatever the outcome.
    /// The one exception to "the operation must still be current" is the press-again
    /// that landed during the commit itself: the text is already on the clipboard, so
    /// the user is told, unless a newer operation owns the screen by then.
    static func reportsCommitOutcome(operationIsCurrent: Bool, isIdle: Bool, stoppedExternally: Bool) -> Bool {
        if stoppedExternally { return false }
        return operationIsCurrent || isIdle
    }
    /// Why faster OCR cannot be switched on right now, as a localization key. One rule
    /// for the preferences and the CLI: the OS must support it, and a stored manual
    /// language must exist in this OS instead of being replaced silently later.
    static func enableRefusalKey(language: String, supportedLanguages: () throws -> [String]) -> String? {
        if unavailableReason() != nil { return "OCR OS Unsupported" }
        if language == "auto" || language == "ja-en" { return nil }
        guard let supported = try? supportedLanguages(), supported.contains(language) else { return "OCR Enable Unsupported Language" }
        return nil
    }
    @objc static func supportedRecognitionLanguages() -> [String] { (try? RCVisionTextRecognizer.supportedLanguages()) ?? [] }
    @objc static func enableRefusalKey(forLanguage language: String) -> String? {
        enableRefusalKey(language: language, supportedLanguages: RCVisionTextRecognizer.supportedLanguages)
    }
    @objc static func enableRefusalKey() -> String? {
        enableRefusalKey(language: UserDefaults.standard.string(forKey: kRCOCRLanguageKey) ?? "auto",
                         supportedLanguages: RCVisionTextRecognizer.supportedLanguages)
    }
    static func noticeKey(for refusal: RCOCRRefusal) -> String {
        switch refusal {
        case .unknownSource: return "OCR Unknown Source"
        case .excludedSource: return "OCR Excluded Source"
        default: return "OCR Stopped"
        }
    }
    @objc func invokeFromApplication(_ source: NSRunningApplication?) {
        if operation != nil { cancel(); return }
        // Dismiss the previous result before taking the next frozen frame.
        dismissNotice()
        guard !workerBusy, !historyPending else { showNotice("OCR Worker Busy"); return }
        guard Self.bool(kRCOCREnabledKey, fallback: true) else { showNotice("OCR Disabled"); return }
        if let reason = Self.unavailableReason() { showNoticeText(reason); return }
        var refusal = RCOCRRefusal.none
        guard let ticket = RCClipboardService.shared().beginOCR(fromApplication: source?.bundleIdentifier ?? "",
                saveToHistory: Self.bool(kRCOCRSaveHistoryKey, fallback: true), refusal: &refusal) else {
            showNotice(Self.noticeKey(for: refusal)); return
        }
        // No permission request or enumeration happens merely by launching the app.
        guard screenCaptureAccess() else {
            let permissionID = UUID(); operation = permissionID; context = ticket
            let alert = NSAlert(); permissionAlert = alert
            alert.messageText = RCLocalizedString("OCR Permission Required", comment: "")
            alert.informativeText = RCLocalizedString("OCR Permission Explanation", comment: "")
            alert.addButton(withTitle: RCLocalizedString("OCR Continue", comment: ""))
            alert.addButton(withTitle: RCLocalizedString("Cancel", comment: ""))
            let response = alert.runModal()
            let stillActive = operation == permissionID
            cancel()
            if stillActive && response == .alertFirstButtonReturn {
                Self.openScreenRecordingSettings()
            }
            return
        }
        let screens = NSScreen.screens
        guard let index = RCOCRScreenHitTest.index(of: NSEvent.mouseLocation, in: screens.map(\.frame)),
              case let screen = screens[index],
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            showNotice("OCR Display Unavailable"); return
        }
        let id = UUID(); operation = id; context = ticket
        activeSettings = RCOCRSettings(language: UserDefaults.standard.string(forKey: kRCOCRLanguageKey) ?? "auto",
                                       correction: Self.bool(kRCOCRCorrectionKey, fallback: false), preferredLanguages: Locale.preferredLanguages)
        workerBusy = true; deadline(5, id: id)
        // Menu commands arrive here after RCMenuManager has ended menu tracking.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                defer { self.workerBusy = false }
                do {
                    guard self.operation == id else { return }
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    guard self.operation == id else { return }
                    guard let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { throw RCOCRError.displayUnavailable }
                    // A closed menu can still be fading on screen. Revclip's own menus,
                    // notices and previews never belong in the frozen frame, whatever the
                    // compositor has finished; every other window is captured as shown.
                    let pid = ProcessInfo.processInfo.processIdentifier
                    let own = RCOCRCaptureExclusion.partition(content.windows, processID: pid,
                        owner: { $0.owningApplication?.processID }, layer: { $0.windowLayer })
                    let filter: SCContentFilter
                    if let app = content.applications.first(where: { $0.processID == pid }) {
                        filter = SCContentFilter(display: display, excludingApplications: [app], exceptingWindows: own.kept)
                    } else {
                        filter = SCContentFilter(display: display, excludingWindows: own.excluded)
                    }
                    Self.log.debug("capture filter: own transient=\(own.excluded.count) kept=\(own.kept.count)")
                    let width = ceil(filter.contentRect.width * CGFloat(filter.pointPixelScale))
                    let height = ceil(filter.contentRect.height * CGFloat(filter.pointPixelScale))
                    guard width.isFinite, height.isFinite, width > 0, height > 0, width * height <= 32_000_000 else { throw RCOCRError.inputTooLarge }
                    let config = SCStreamConfiguration()
                    config.width = Int(width); config.height = Int(height); config.showsCursor = false
                    config.pixelFormat = kCVPixelFormatType_32BGRA
                    config.colorSpaceName = CGColorSpace.sRGB
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    guard self.operation == id else { return }
                    guard RCOCRGeometry.validImage(image, maximumPixels: 32_000_000) else { throw RCOCRError.inputTooLarge }
                    self.frame = image
                    self.selection = RCOCRSelectionController(image: image, screen: screen, previousApplication: source,
                        selected: { [weak self] rect in self?.recognize(rect, id: id) },
                        cancelled: { [weak self] in self?.cancel() },
                        activationFailed: { [weak self] in
                            guard let self, self.operation == id else { return }
                            self.cancel(); self.showNotice("OCR Activation Failed")
                        },
                        interacted: { [weak self] in self?.noteActivity() })
                    self.deadline(120, id: id)
                    self.selection?.show()
                } catch {
                    guard self.operation == id else { return }
                    self.cancel()
                    switch error {
                    case RCOCRError.inputTooLarge: self.showNotice("OCR Input Too Large")
                    case RCOCRError.displayUnavailable: self.showNotice("OCR Display Unavailable")
                    default: self.showNotice("OCR Capture Failed")
                    }
                }
            }
        }
    }
    private func recognize(_ rect: CGRect, id: UUID) {
        guard operation == id, let image = frame, let settings = activeSettings else { return }
        guard rect.width * rect.height <= 16_000_000 else { cancel(); showNotice("OCR Input Too Large"); return }
        selection?.close(); selection = nil; frame = nil
        let cell = RCOCRCancellation()
        beginRecognition(cell: cell, id: id)
        Task { @MainActor in
            do {
                let crop = try await Task.detached(priority: .userInitiated) {
                    try autoreleasepool { try RCVisionTextRecognizer.independentCrop(image: image, selection: rect, cancellation: cell) }
                }.value
                guard self.operation == id else { self.workerBusy = false; return }
                self.recognizeCrop(crop, id: id, settings: settings, cell: cell)
            } catch {
                self.workerBusy = false
                guard self.operation == id else { return }
                self.cancel()
                switch error {
                case RCOCRError.inputTooLarge: self.showNotice("OCR Input Too Large")
                case RCOCRError.cancelled: break
                default: self.showNotice("OCR Invalid Selection")
                }
            }
        }
    }
    // Separate task owns only the crop, so the capture frame/selection closure
    // cannot retain the full display while Vision is running.
    func beginRecognition(cell: RCOCRCancellation, id: UUID) {
        cancellation = cell
        workerBusy = true
        deadline(recognitionTimeout, id: id)
    }
    @discardableResult
    func recognizeCrop(_ crop: CGImage, id: UUID, settings: RCOCRSettings, cell: RCOCRCancellation,
                       using recognize: @escaping @Sendable (CGImage, RCOCRSettings, RCOCRCancellation) async throws -> RCOCRRecognition = { crop, settings, cell in
                           try await Task.detached(priority: .userInitiated) {
                               try autoreleasepool { try RCVisionTextRecognizer.recognizeCrop(crop, settings: settings, cancellation: cell) }
                           }.value
                       }) -> Task<Void, Never> {
        return Task { @MainActor in
            do {
                let result = try await recognize(crop, settings, cell)
                self.recognitionIsWarm = true
                self.workerBusy = false
                guard self.operation == id, let context = self.context else { return }
                guard self.screenCaptureAccess() else { self.cancel(); self.showNotice("OCR Permission Required"); return }
                self.timer?.invalidate(); self.dismissNotice()
                await self.commit(result.text, context: context, id: id, using: self.commitRecognition)
            } catch {
                self.workerBusy = false
                guard self.operation == id else { return }
                self.cancel()
                switch error {
                case RCOCRError.noText: self.showNotice("OCR No Text")
                case RCOCRError.unsupportedLanguage: self.showNotice("OCR Unsupported Language")
                case RCOCRError.inputTooLarge: self.showNotice("OCR Input Too Large")
                case RCOCRError.cancelled: break
                default: self.showNotice("OCR Recognition Failed")
                }
            }
        }
    }
    /// Everything around the clipboard commit: what is remembered before the await and
    /// what may happen after it. The commit itself is passed in, so this exact code is
    /// what the tests drive with a commit they hold back.
    func commit(_ text: String, context: RCOCRCommitContext, id: UUID,
                using perform: @MainActor (String, RCOCRCommitContext) async -> RCOCRCommitResult) async {
        historyPending = true
        let stops = stopEpoch, monitoring = monitoringGeneration()
        let outcome = await perform(text, context)
        historyPending = false
        let reports = Self.reportsCommitOutcome(operationIsCurrent: operation == id, isIdle: operation == nil,
                                                stoppedExternally: stopEpoch != stops || monitoringGeneration() != monitoring)
        // This operation always ends here, reported or not; a newer one is not touched.
        if operation == id { cancel() }
        guard reports else { return }
        switch outcome {
        case .historyStored, .historySkipped: showNotice("OCR Copied")
        case .historyFailed: showNotice("OCR History Failed")
        case .clipboardChanged: showNotice("OCR Clipboard Changed")
        case .clipboardWriteFailed: showNotice("OCR Write Failed")
        default: break
        }
    }
    /// Test access to the state commit(_:context:id:using:) reads and leaves behind.
    var noticeIsVisible: Bool { notice != nil }
    func adoptOperationForTesting(_ id: UUID?, context: RCOCRCommitContext? = nil) { operation = id; self.context = context }
    @objc static func openScreenRecordingSettings() {
        requestScreenRecordingAccess(preflight: CGPreflightScreenCaptureAccess,
                                     request: CGRequestScreenCaptureAccess) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
        }
    }
    /// Called only by an explicit user action, never by loading preferences.
    /// Request first so a fresh install is registered in the TCC settings list.
    static func requestScreenRecordingAccess(preflight: () -> Bool, request: () -> Bool, openSettings: () -> Void) {
        if !preflight() { _ = request() }
        openSettings()
    }
    private func dismissNotice() {
        noticeTimer?.invalidate(); noticeTimer = nil
        notice?.orderOut(nil); notice?.close(); notice = nil
    }
    private func showNotice(_ key: String) {
        let style: RCOCRNoticePanel.Style
        if key == "OCR Copied" || key == "OCR History Failed" { style = .success }
        else if ["OCR Clipboard Changed", "OCR Worker Busy", "OCR Disabled"].contains(key) { style = .information }
        else { style = .failure }
        showNoticeText(RCLocalizedString(key, comment: ""), style: style)
    }
    private func showNoticeText(_ text: String, style: RCOCRNoticePanel.Style = .failure) {
        dismissNotice()
        let panel = RCOCRNoticePanel(text: text, style: style)
        if let screen = NSScreen.main {
            panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - panel.frame.width / 2, y: screen.visibleFrame.minY + 80))
        }
        notice = panel; panel.orderFrontRegardless()
        noticeTimer = Timer(timeInterval: 3, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.dismissNotice() } }
        RunLoop.main.add(noticeTimer!, forMode: .common)
    }
}
