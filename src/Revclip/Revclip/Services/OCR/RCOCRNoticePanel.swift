import AppKit

// Layout follows the supplied app_installer Figma reference. The SVG assets
// preserve the supplied shapes; original colors are rendered without vibrancy tinting.
@MainActor
final class RCOCRNoticePanel: NSPanel {
    enum Style { case success, failure, information }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(text: String, style: Style) {
        let compact = text.count <= 32
        let width: CGFloat = compact ? 240 : 360
        let height: CGFloat = compact ? 152 : 184
        super.init(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false; isOpaque = false; backgroundColor = .clear
        sharingType = .readOnly
        hasShadow = false; level = .floating; hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)
        setAccessibilityLabel(text)
        let surface = NSView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 24; surface.layer?.masksToBounds = true
        surface.layer?.borderWidth = 1
        let accessibility = NSWorkspace.shared
        surface.layer?.borderColor = NSColor.white.withAlphaComponent(accessibility.accessibilityDisplayShouldIncreaseContrast ? 0.6 : 0.10).cgColor
        if accessibility.accessibilityDisplayShouldReduceTransparency {
            surface.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        } else {
            surface.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.90).cgColor
        }
        contentView = surface
        let name = style == .success ? "RevOCRSuccess" : style == .failure ? "RevOCRFailure" : nil
        let image = (name.flatMap { NSImage(named: $0) } ?? NSImage(systemSymbolName: "info.circle.fill", accessibilityDescription: nil))?.copy() as? NSImage
        image?.isTemplate = style == .information
        let icon = NSImageView(frame: CGRect(x: width / 2 - 20, y: height - 76, width: 40, height: 40))
        icon.contentTintColor = style == .information ? .white : nil
        icon.image = image; icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        surface.addSubview(icon)
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.drawsBackground = false; label.isBezeled = false
        label.textColor = .white; label.alignment = .center
        label.maximumNumberOfLines = 4
        label.frame = CGRect(x: 20, y: 24, width: width - 40, height: compact ? 32 : 72)
        label.setAccessibilityLabel(text); surface.addSubview(label)
    }
}
