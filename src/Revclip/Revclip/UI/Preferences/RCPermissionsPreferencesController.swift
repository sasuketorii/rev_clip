import AppKit

private final class RCPermissionsPage: NSView { override var isFlipped: Bool { true } }

/// Read-only permission presentation: opening this page never requests access or reads content.
@MainActor
@objc(RCPermissionsPreferencesController)
final class RCPermissionsPreferencesController: NSViewController {
    enum Status {
        case granted, required, denied, ask, unknown, notRequired
        var isReady: Bool { self == .granted || self == .notRequired }
        var titleKey: String {
            switch self {
            case .granted: return "Permission Granted"
            case .required: return "Permission Required"
            case .denied: return "Permission Denied"
            case .ask: return "Permission Ask"
            case .unknown: return "Permission Unknown"
            case .notRequired: return "Permission Not Required"
            }
        }
    }
    private var indicators: [NSImageView] = []
    private var statuses: [NSTextField] = []
    private var settingsButtons: [NSButton] = []
    private let names = ["Permission Accessibility", "Permission Clipboard", "Permission Screen Recording"]
    private func text(_ key: String) -> String { RCLocalizedString(key, comment: "") }

    static func clipboardStatus(_ state: RCClipboardAccessState, privacyAPIAvailable: Bool) -> Status {
        if !privacyAPIAvailable { return state == .granted ? .notRequired : .unknown }
        switch state {
        case .granted: return .granted
        case .denied: return .denied
        case .notDetermined: return .ask
        default: return .unknown
        }
    }

    override func loadView() {
        let page = RCPermissionsPage(frame: NSRect(x: 0, y: 0, width: 660, height: 480))
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)
        let explanations = ["Permission Accessibility Help", "Permission Clipboard Help", "Permission Screen Recording Help"]
        for index in names.indices {
            let card = RCPreferencesSurface(frame: .zero)
            card.translatesAutoresizingMaskIntoConstraints = false
            let dot = NSImageView()
            dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
            dot.setAccessibilityElement(false)
            dot.translatesAutoresizingMaskIntoConstraints = false
            let title = NSTextField(labelWithString: text(names[index]))
            title.font = .systemFont(ofSize: 14, weight: .semibold)
            let status = NSTextField(labelWithString: "")
            status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
            let heading = NSStackView(views: [dot, title, status])
            heading.orientation = .horizontal; heading.spacing = 8; heading.alignment = .centerY
            heading.translatesAutoresizingMaskIntoConstraints = false
            let explanation = NSTextField(wrappingLabelWithString: text(explanations[index]))
            explanation.font = .systemFont(ofSize: 12); explanation.textColor = .secondaryLabelColor
            explanation.preferredMaxLayoutWidth = 380
            explanation.translatesAutoresizingMaskIntoConstraints = false
            let button = NSButton(title: text("Open System Settings"), target: self, action: #selector(openSettings(_:)))
            button.bezelStyle = .rounded; button.tag = index
            button.setAccessibilityLabel(text(names[index]) + ": " + text("Open System Settings"))
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            card.addSubview(heading); card.addSubview(explanation); card.addSubview(button)
            stack.addArrangedSubview(card)
            NSLayoutConstraint.activate([
                card.widthAnchor.constraint(equalTo: stack.widthAnchor),
                card.heightAnchor.constraint(greaterThanOrEqualToConstant: 118),
                dot.widthAnchor.constraint(equalToConstant: 10), dot.heightAnchor.constraint(equalToConstant: 10),
                heading.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
                heading.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
                heading.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -16),
                explanation.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
                explanation.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
                explanation.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -16),
                explanation.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -16),
                button.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
                button.centerYAnchor.constraint(equalTo: explanation.centerYAnchor),
                button.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -16)
            ])
            indicators.append(dot); statuses.append(status); settingsButtons.append(button)
        }
        let help = NSTextField(wrappingLabelWithString: text("Permission Status Help"))
        help.font = .systemFont(ofSize: 12); help.textColor = .secondaryLabelColor
        stack.addArrangedSubview(help)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: page.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -24),
            help.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        view = page
        refreshStatuses()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshStatuses()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshStatuses), name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshStatuses), name: .RCClipboardAccessStateDidChange, object: nil)
    }
    override func viewWillDisappear() {
        super.viewWillDisappear()
        NotificationCenter.default.removeObserver(self)
    }
    @objc private func refreshStatuses() {
        let privacy = RCPrivacyService.shared()
        let clipboardAPI = privacy.isClipboardPrivacyAPIAvailable()
        let values: [Status] = [
            RCAccessibilityService.shared().isAccessibilityEnabled() ? .granted : .required,
            Self.clipboardStatus(privacy.clipboardAccessState(), privacyAPIAvailable: clipboardAPI),
            CGPreflightScreenCaptureAccess() ? .granted : .required
        ]
        for (index, status) in values.enumerated() {
            indicators[index].contentTintColor = status.isReady ? .systemGreen : .systemYellow
            statuses[index].stringValue = text(status.titleKey)
            statuses[index].setAccessibilityLabel(text(names[index]) + ": " + text(status.titleKey))
        }
        settingsButtons[1].isEnabled = clipboardAPI
    }
    @objc private func openSettings(_ sender: NSButton) {
        switch sender.tag {
        case 0: RCAccessibilityService.shared().openAccessibilitySettingsWithFallback()
        case 1: RCPrivacyService.shared().openClipboardSettings()
        case 2: RCOCRCoordinator.openScreenRecordingSettings()
        default: break
        }
    }
}
