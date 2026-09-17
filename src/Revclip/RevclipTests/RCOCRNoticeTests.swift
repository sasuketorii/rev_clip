import AppKit
import XCTest
@testable import Revclip

final class RCOCRNoticeTests: XCTestCase {
    @MainActor
    func testSelectionCrosshairIsWindowContentAndSurvivesSystemCursorReset() throws {
        let prior = NSCursor.current
        defer { prior.set() }
        let view = RCOCRSelectionView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 400, bitsPerPixel: 32))
        view.image = bitmap.cgImage
        // No mouse movement is needed for the initial crosshair.
        view.positionPointer(at: CGPoint(x: 40, y: 30))
        let pointer = try XCTUnwrap(view.pointerLayer)
        XCTAssertTrue(pointer.superlayer === view.layer)
        XCTAssertEqual(pointer.bounds.size, CGSize(width: 48, height: 48))
        XCTAssertEqual(pointer.position, CGPoint(x: 40, y: 30))
        XCTAssertFalse(pointer.isHidden)
        NSCursor.arrow.set()
        XCTAssertFalse(pointer.isHidden, "OS cursor changes must not remove the visible crosshair")
        XCTAssertEqual(pointer.sublayers?.count, 2)
        view.positionPointer(at: CGPoint(x: 70, y: 80))
        XCTAssertTrue(view.pointerLayer === pointer, "Movement reuses the tiny layer")
        XCTAssertEqual(pointer.position, CGPoint(x: 70, y: 80))
        XCTAssertNil(pointer.animationKeys())
        view.positionPointer(at: CGPoint(x: -1, y: 30))
        XCTAssertTrue(pointer.isHidden)
        view.positionPointer(at: CGPoint(x: 40, y: 30))
        view.releasePointer()
        XCTAssertTrue(pointer.isHidden)
        view.releasePointer() // Cleanup is idempotent.
    }

    @MainActor
    func testSelectionUsesExistingPrimaryAndFixedFillOpacity() throws {
        let defaults = UserDefaults.standard
        let enabledKey = "RCMenuCustomColorsEnabled"
        let paletteKey = RCMenuStyle.paletteKey()
        let oldEnabled = defaults.object(forKey: enabledKey)
        let oldPalette = defaults.object(forKey: paletteKey)
        defer {
            if let oldEnabled { defaults.set(oldEnabled, forKey: enabledKey) } else { defaults.removeObject(forKey: enabledKey) }
            if let oldPalette { defaults.set(oldPalette, forKey: paletteKey) } else { defaults.removeObject(forKey: paletteKey) }
        }
        defaults.set(false, forKey: enabledKey)
        var color = try XCTUnwrap(RCOCRSelectionView.resolvedSelectionColor().usingColorSpace(.sRGB))
        XCTAssertEqual(color.redComponent, 0, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 127.0 / 255, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 1, accuracy: 0.001)
        defaults.set(true, forKey: enabledKey)
        defaults.set(["primary": "#CC3399"], forKey: paletteKey)
        color = try XCTUnwrap(RCOCRSelectionView.resolvedSelectionColor().usingColorSpace(.sRGB))
        XCTAssertEqual(color.redComponent, 0.8, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 0.2, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 0.6, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 1)
        XCTAssertEqual(RCOCRSelectionView.selectionFillOpacity, 0.10)
    }

    @MainActor
    func testSelectionCancellationKeysCannotCommitSelection() throws {
        for keyCode: UInt16 in [53, 51, 117] {
            let view = RCOCRSelectionView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
            view.origin = CGPoint(x: 10, y: 10)
            view.selection = CGRect(x: 10, y: 10, width: 30, height: 30)
            var cancelled = 0
            var selected = 0
            view.cancelled = { cancelled += 1 }
            view.selected = { _ in selected += 1 }
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode))
            view.keyDown(with: event)
            XCTAssertEqual(cancelled, 1)
            XCTAssertEqual(selected, 0)
        }
    }

    @MainActor
    func testSuppliedAssetsAndNonactivatingNoticeLayout() throws {
        XCTAssertNotNil(NSImage(named: "RevOCRSuccess"))
        XCTAssertNotNil(NSImage(named: "RevOCRFailure"))
        for style: RCOCRNoticePanel.Style in [.success, .failure, .information] {
            let text = style == .success ? "クリップボードにコピー" : "コピーに失敗しました"
            let panel = RCOCRNoticePanel(text: text, style: style)
            XCTAssertFalse(panel.canBecomeKey); XCTAssertFalse(panel.canBecomeMain)
            XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
            let surface = try XCTUnwrap(panel.contentView)
            XCTAssertFalse(surface is NSVisualEffectView, "HUD must not add a vibrancy backdrop")
            let label = try XCTUnwrap(surface.subviews.compactMap { $0 as? NSTextField }.first)
            XCTAssertFalse(label.drawsBackground)
            XCTAssertEqual(label.stringValue, text)
            XCTAssertTrue(surface.bounds.contains(label.frame))
            for icon in surface.subviews where icon is NSImageView || icon is NSProgressIndicator {
                XCTAssertFalse(label.frame.intersects(icon.frame), "status text must not overlap icon/spinner")
            }
            panel.close()
        }
    }
    func testCaptureExcludesOnlyOwnMenusNoticesAndPreviews() {
        struct Window: Equatable { let pid: pid_t; let layer: Int }
        let menu = Int(CGWindowLevelForKey(.popUpMenuWindow)), floating = Int(CGWindowLevelForKey(.floatingWindow))
        let status = Int(CGWindowLevelForKey(.statusWindow))
        let windows = [Window(pid: 7, layer: menu), Window(pid: 7, layer: menu + 1), Window(pid: 7, layer: floating),
                       Window(pid: 7, layer: 0), Window(pid: 7, layer: status),
                       Window(pid: 9, layer: menu), Window(pid: 9, layer: 0)]
        let own = RCOCRCaptureExclusion.partition(windows, processID: 7, owner: { $0.pid }, layer: { $0.layer })
        XCTAssertEqual(own.excluded, Array(windows[0...2]), "A fading Revclip menu never reaches the frozen frame")
        XCTAssertEqual(own.kept, Array(windows[3...4]), "Normal windows and the status item stay visible")
        XCTAssertFalse((own.excluded + own.kept).contains { $0.pid == 9 }, "Other apps' menus are captured as shown")
    }

    @MainActor
    func testRequestWaitsBehindMenuGateAndDiesWithAnExternalStop() {
        let coordinator = RCOCRCoordinator.shared
        let priorGate = coordinator.menuTrackingGate
        defer { coordinator.menuTrackingGate = priorGate }
        var waiting: [() -> Void] = []
        coordinator.menuTrackingGate = { waiting.append($0) }
        coordinator.startObserving()
        coordinator.invoke()
        XCTAssertEqual(waiting.count, 1, "The hotkey goes through the menu gate instead of starting at once")
        let epoch = coordinator.invalidationEpoch
        // Clear, Panic and quit all stop the clipboard lifecycle.
        NotificationCenter.default.post(name: .RCClipboardLifecycleDidStop, object: nil)
        XCTAssertEqual(coordinator.invalidationEpoch, epoch &+ 1)
        // No ticket existed yet; running the stale request must not create an operation.
        waiting[0]()
        XCTAssertEqual(coordinator.invalidationEpoch, epoch &+ 1)
        XCTAssertNil(coordinator.operation)

        // An off-main stop invalidates asynchronously; after stop and restart only the
        // clipboard service's generation tells the stale request apart.
        let priorGeneration = coordinator.monitoringGeneration
        defer { coordinator.monitoringGeneration = priorGeneration }
        var generation: UInt = 41
        coordinator.monitoringGeneration = { generation }
        coordinator.invoke()
        generation = 42
        XCTAssertEqual(waiting.count, 2)
        waiting[1]()
        XCTAssertNil(coordinator.operation, "A request accepted under an older monitoring generation never starts")

        // A display or Space change invalidates a request that owns no operation yet.
        coordinator.invoke()
        let beforeDisplayChange = coordinator.invalidationEpoch
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(coordinator.invalidationEpoch, beforeDisplayChange &+ 1)
        waiting[2]()
        XCTAssertNil(coordinator.operation)
    }
    /// Drives the product's commit handler with a commit that is held back, so the stop
    /// really happens between "before the await" and "after the await".
    @MainActor
    private func runCommit(outcome: RCOCRCommitResult, id: UUID, whileWaiting: @escaping @MainActor () -> Void) async {
        let coordinator = RCOCRCoordinator.shared
        coordinator.startObserving()
        coordinator.adoptOperationForTesting(id)
        await coordinator.commit("synthetic", context: RCOCRCommitContext(), id: id) { _, _ in
            await withCheckedContinuation { (release: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { MainActor.assumeIsolated { whileWaiting() }; release.resume() }
            }
            return outcome
        }
    }

    @MainActor
    func testStopDuringTheCommitAwaitLeavesNoNoticeForAnyOutcomeAndReleasesTheOperation() async {
        let coordinator = RCOCRCoordinator.shared
        defer { coordinator.cancel() }
        let stops: [(String, @MainActor () -> Void)] = [
            ("clipboard lifecycle stop (Clear, Panic, quit)", { NotificationCenter.default.post(name: .RCClipboardLifecycleDidStop, object: nil) }),
            ("application will terminate", { NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil) }),
            ("screens did sleep", { NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil) }),
        ]
        for (name, stop) in stops {
            for outcome in [RCOCRCommitResult.historyStored, .historySkipped, .historyFailed, .clipboardChanged, .clipboardWriteFailed] {
                await runCommit(outcome: outcome, id: UUID(), whileWaiting: stop)
                XCTAssertFalse(coordinator.noticeIsVisible, "\(name), outcome \(outcome.rawValue): a late result must not reappear")
                XCTAssertNil(coordinator.operation, "\(name): the operation is released")
            }
        }
        // A changed monitoring generation alone (an off-main stop that has not reached the
        // coordinator yet, followed by a restart) silences it as well.
        let priorGeneration = coordinator.monitoringGeneration
        defer { coordinator.monitoringGeneration = priorGeneration }
        var generation: UInt = 7
        coordinator.monitoringGeneration = { generation }
        let id = UUID()
        await runCommit(outcome: .historyStored, id: id, whileWaiting: { generation = 8 })
        XCTAssertFalse(coordinator.noticeIsVisible)
        XCTAssertNil(coordinator.operation, "Still this operation: ended even though nothing is shown")
    }

    @MainActor
    func testCommitReportsNormallyAndNeverTouchesANewerOperation() async {
        let coordinator = RCOCRCoordinator.shared
        defer { coordinator.cancel() }
        let id = UUID()
        await runCommit(outcome: .historyStored, id: id, whileWaiting: {})
        XCTAssertTrue(coordinator.noticeIsVisible, "The ordinary path shows its result")
        XCTAssertNil(coordinator.operation)
        coordinator.cancel()
        // A display change during the await is not a stop: the result is still reported.
        await runCommit(outcome: .clipboardChanged, id: UUID(), whileWaiting: {
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        })
        XCTAssertTrue(coordinator.noticeIsVisible)
        coordinator.cancel()
        // The press-again that landed during the commit: the text is already copied.
        await runCommit(outcome: .historyStored, id: UUID(), whileWaiting: { coordinator.cancel() })
        XCTAssertTrue(coordinator.noticeIsVisible)
        coordinator.cancel()
        // A newer operation owns the screen by then: nothing is shown and it is not ended.
        let newer = UUID()
        await runCommit(outcome: .historyStored, id: UUID(), whileWaiting: { coordinator.adoptOperationForTesting(newer) })
        XCTAssertFalse(coordinator.noticeIsVisible)
        XCTAssertEqual(coordinator.operation, newer, "Only its own operation is ended")
    }

    @MainActor
    func testExternalStopSilencesEveryCommitOutcomeAndOnlyAPressAgainStillReports() {
        // Clear, Panic, quit, lock, sleep, feature off: nothing is shown, whatever happened
        // to the text, and whatever state the operation is in by then.
        for current in [true, false] { for idle in [true, false] {
            XCTAssertFalse(RCOCRCoordinator.reportsCommitOutcome(operationIsCurrent: current, isIdle: idle, stoppedExternally: true))
        } }
        XCTAssertTrue(RCOCRCoordinator.reportsCommitOutcome(operationIsCurrent: true, isIdle: false, stoppedExternally: false))
        XCTAssertTrue(RCOCRCoordinator.reportsCommitOutcome(operationIsCurrent: false, isIdle: true, stoppedExternally: false),
                      "The press-again that landed during the commit: the text is already copied")
        XCTAssertFalse(RCOCRCoordinator.reportsCommitOutcome(operationIsCurrent: false, isIdle: false, stoppedExternally: false),
                       "A newer operation owns the screen")
        // The stop counter is what the commit compares, and only real stops advance it.
        let coordinator = RCOCRCoordinator.shared
        coordinator.startObserving()
        let stops = coordinator.stopEpoch, requests = coordinator.invalidationEpoch
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(coordinator.stopEpoch, stops, "A display change keeps a running recognition and its report")
        XCTAssertEqual(coordinator.invalidationEpoch, requests &+ 1, "but drops a request still waiting behind a menu")
        NotificationCenter.default.post(name: .RCClipboardLifecycleDidStop, object: nil)
        XCTAssertEqual(coordinator.stopEpoch, stops &+ 1)
    }

    @MainActor
    func testSameInputIsOnlyEverAPositiveMatchOfTwoKnownTimes() {
        XCTAssertTrue(RCOCRCoordinator.isSameInput(1234.5670, 1234.5675))
        XCTAssertFalse(RCOCRCoordinator.isSameInput(1234.567, 1234.617), "Pressing again is another input")
        XCTAssertFalse(RCOCRCoordinator.isSameInput(0, 0), "Unknown times never match")
        XCTAssertFalse(RCOCRCoordinator.isSameInput(0, 1234.567))
        XCTAssertFalse(RCOCRCoordinator.isSameInput(1234.567, 0))
    }

    @MainActor
    func testRefusalsHaveTheirOwnWordingAndSwitchingOnNeedsAUsableLanguage() {
        XCTAssertEqual(RCOCRCoordinator.noticeKey(for: .unknownSource), "OCR Unknown Source")
        XCTAssertEqual(RCOCRCoordinator.noticeKey(for: .excludedSource), "OCR Excluded Source")
        XCTAssertEqual(RCOCRCoordinator.noticeKey(for: .stopped), "OCR Stopped")
        let supported = { ["en-US", "ja-JP"] }
        XCTAssertNil(RCOCRCoordinator.enableRefusalKey(language: "auto", supportedLanguages: supported))
        XCTAssertNil(RCOCRCoordinator.enableRefusalKey(language: "ja-en", supportedLanguages: supported))
        XCTAssertNil(RCOCRCoordinator.enableRefusalKey(language: "ja-JP", supportedLanguages: supported))
        XCTAssertEqual(RCOCRCoordinator.enableRefusalKey(language: "de-DE", supportedLanguages: supported), "OCR Enable Unsupported Language")
        XCTAssertEqual(RCOCRCoordinator.enableRefusalKey(language: "ja-JP", supportedLanguages: { throw RCOCRError.unsupportedLanguage }),
                       "OCR Enable Unsupported Language", "An unreadable list is not permission")
    }

    @MainActor
    func testHistoryHelpExplainsCopyOnlyInsteadOfAnotherNotice() {
        XCTAssertNil(RCOCRPreferencesController.historyStatusKey(saveEnabled: true, access: .granted))
        XCTAssertNil(RCOCRPreferencesController.historyStatusKey(saveEnabled: false, access: .denied), "Off is the user's own choice")
        for state in [RCClipboardAccessState.notDetermined, .denied, .unknown] {
            XCTAssertEqual(RCOCRPreferencesController.historyStatusKey(saveEnabled: true, access: state), "OCR History Needs Clipboard Access")
        }
    }
}
