import AppKit

@MainActor
final class RCOCRSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func becomeKey() {
        super.becomeKey()
        DispatchQueue.main.async { [weak self] in
            (self?.contentView as? RCOCRSelectionView)?.refreshPointer()
        }
    }
    override func resignKey() {
        (contentView as? RCOCRSelectionView)?.releasePointer()
        super.resignKey()
    }

}

@MainActor
final class RCOCRSelectionView: NSView {
    var image: CGImage? {
        didSet {
            displayImage = image.map { NSImage(cgImage: $0, size: bounds.size) }
            needsDisplay = true
        }
    }
    private var displayImage: NSImage?
    var origin: CGPoint?
    var selection = CGRect.zero
    var selected: ((CGRect) -> Void)?
    var cancelled: (() -> Void)?
    var interacted: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    static let selectionFillOpacity: CGFloat = 0.10
    // Keep the pointer crosshair distinct from the shorter selection corner marks.
    static let armLength: CGFloat = 22.5
    static let cornerArmLength: CGFloat = armLength / 2
    static let pointerSize: CGFloat = 48
    // Everything drawn outside the selection rectangle: the corner marks plus half
    // their stroke and antialiasing. Redraw requests must cover it or marks are left behind.
    static let selectionRedrawInset: CGFloat = cornerArmLength + 2.5
    static func resolvedSelectionColor() -> NSColor {
        if RCMenuStyle.isEnabled(), let color = RCMenuStyle.color(forKey: "primary") { return color }
        return NSColor(srgbRed: 0, green: 127.0 / 255.0, blue: 1, alpha: 1)
    }
    private let selectionColor = RCOCRSelectionView.resolvedSelectionColor()
    // The crosshair is window content, so screen recorders capture it even
    // when they replace or omit the hardware cursor. Movement updates only this layer.
    private(set) var pointerLayer: CALayer?
    private var hidesSystemPointer = false
    private var selectionTrackingArea: NSTrackingArea?
    override func updateTrackingAreas() {
        if let selectionTrackingArea { removeTrackingArea(selectionTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways,
                      .inVisibleRect, .enabledDuringMouseDrag], owner: self, userInfo: nil)
        addTrackingArea(area); selectionTrackingArea = area
        super.updateTrackingAreas()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { preparePointerLayer(); updatePointerScale() }
        else { releasePointer() }
    }
    private func preparePointerLayer() {
        wantsLayer = true
        guard let layer else { return }
        if let pointerLayer {
            if pointerLayer.superlayer !== layer { layer.addSublayer(pointerLayer) }
            return
        }
        let pointer = CALayer()
        let center = Self.pointerSize / 2, arm = Self.armLength
        pointer.bounds = CGRect(x: 0, y: 0, width: Self.pointerSize, height: Self.pointerSize)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: center, y: center - arm)); path.addLine(to: CGPoint(x: center, y: center + arm))
        path.move(to: CGPoint(x: center - arm, y: center)); path.addLine(to: CGPoint(x: center + arm, y: center))
        for (color, width) in [(NSColor.white.withAlphaComponent(0.85), CGFloat(4.5)), (selectionColor, CGFloat(3))] {
            let stroke = CAShapeLayer()
            stroke.path = path; stroke.strokeColor = color.cgColor; stroke.fillColor = nil; stroke.lineWidth = width
            pointer.addSublayer(stroke)
        }
        layer.addSublayer(pointer); pointerLayer = pointer
        updatePointerScale()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updatePointerScale()
    }
    private func updatePointerScale() {
        let scale = window?.backingScaleFactor ?? 1
        pointerLayer?.contentsScale = scale
        pointerLayer?.sublayers?.forEach { $0.contentsScale = scale }
    }
    func positionPointer(at point: CGPoint) {
        guard image != nil else { return }
        preparePointerLayer()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pointerLayer?.position = point
        pointerLayer?.isHidden = !bounds.contains(point)
        CATransaction.commit()
    }
    func refreshPointer() {
        guard image != nil, let window, window.isVisible else { releasePointer(); return }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        positionPointer(at: point)
        let shouldHide = NSApp.isActive && window.isKeyWindow && bounds.contains(point)
            && pointerLayer?.superlayer === layer && pointerLayer != nil
        if shouldHide && !hidesSystemPointer {
            NSCursor.hide(); hidesSystemPointer = true
        } else if !shouldHide { releasePointer() }
    }
    func releasePointer() {
        if hidesSystemPointer { NSCursor.unhide(); hidesSystemPointer = false }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pointerLayer?.isHidden = true
        CATransaction.commit()
    }
    override func mouseEntered(with event: NSEvent) { refreshPointer() }
    override func mouseExited(with event: NSEvent) { releasePointer() }
    override func mouseMoved(with event: NSEvent) { refreshPointer() }
    override func draw(_ dirtyRect: NSRect) {
        guard let displayImage else { return }
        displayImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        guard !selection.isEmpty else { return }
        // Match the supplied selection mockup: pale blue inside, clear outside.
        selectionColor.withAlphaComponent(Self.selectionFillOpacity).setFill()
        NSBezierPath(rect: selection).fill()
        selectionColor.setStroke()
        let border = NSBezierPath(rect: selection)
        border.lineWidth = 1.5; border.stroke()
        let corners = NSBezierPath()
        for x in [selection.minX, selection.maxX] {
            for y in [selection.minY, selection.maxY] {
                corners.move(to: NSPoint(x: x - Self.cornerArmLength, y: y))
                corners.line(to: NSPoint(x: x + Self.cornerArmLength, y: y))
                corners.move(to: NSPoint(x: x, y: y - Self.cornerArmLength))
                corners.line(to: NSPoint(x: x, y: y + Self.cornerArmLength))
            }
        }
        corners.lineWidth = 1.5; corners.stroke()
    }
    override func mouseDown(with event: NSEvent) {
        refreshPointer()
        let oldSelection = selection
        origin = convert(event.locationInWindow, from: nil); selection = .zero
        interacted?(); setNeedsDisplay(oldSelection.insetBy(dx: -Self.selectionRedrawInset, dy: -Self.selectionRedrawInset))
    }
    override func mouseDragged(with event: NSEvent) {
        refreshPointer()
        guard let origin else { return }
        let point = convert(event.locationInWindow, from: nil)
        let oldSelection = selection
        selection = CGRect(x: min(origin.x, point.x), y: min(origin.y, point.y),
                           width: abs(origin.x - point.x), height: abs(origin.y - point.y)).intersection(bounds)
        interacted?(); setNeedsDisplay(oldSelection.union(selection).insetBy(dx: -Self.selectionRedrawInset, dy: -Self.selectionRedrawInset))
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        guard let image, let rect = RCOCRGeometry.pixelRect(selection, viewSize: bounds.size, width: image.width, height: image.height) else { return }
        selected?(rect)
    }
    override func rightMouseDown(with event: NSEvent) { cancelled?() }
    override func keyDown(with event: NSEvent) {
        // Handle cancellation only while this selection view owns keyboard focus.
        // 51 is Mac Delete (Backspace); 117 is forward Delete on extended keyboards.
        // Other keys are ignored here: passing them up the responder chain only ends in
        // the system alert sound, once per stray key press.
        if [UInt16(53), 51, 117].contains(event.keyCode) { cancelled?() }
    }
}

@MainActor
final class RCOCRSelectionController {
    private let panel: RCOCRSelectionPanel
    private let selectionView: RCOCRSelectionView
    private var observers: [NSObjectProtocol] = []
    private var activationDeadline: Timer?
    private var closed = false
    private let previousApplication: NSRunningApplication?
    private let activationFailed: () -> Void
    init(image: CGImage, screen: NSScreen, previousApplication: NSRunningApplication?,
         selected: @escaping (CGRect) -> Void, cancelled: @escaping () -> Void,
         activationFailed: @escaping () -> Void, interacted: @escaping () -> Void) {
        self.previousApplication = previousApplication
        self.activationFailed = activationFailed
        panel = RCOCRSelectionPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.isOpaque = true
        panel.backgroundColor = .black
        // Capture finishes before this panel is shown; allow demo recording.
        panel.sharingType = .readOnly
        selectionView = RCOCRSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
        selectionView.image = image
        selectionView.selected = selected; selectionView.cancelled = cancelled; selectionView.interacted = interacted
        selectionView.setAccessibilityLabel(RCLocalizedString("OCR Selection Help", comment: ""))
        panel.contentView = selectionView
    }
    func show() {
        guard !closed, observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.presentWhenActive() }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.selectionView.releasePointer()
                self?.selectionView.cancelled?()
            }
        })
        if NSApp.isActive { presentWhenActive() }
        else {
            activationDeadline = Timer(timeInterval: 1, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.closed, !self.panel.isVisible else { return }
                    // Not a user cancellation: the owner says why nothing appeared.
                    self.activationFailed()
                }
            }
            if let activationDeadline { RunLoop.main.add(activationDeadline, forMode: .common) }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    private func presentWhenActive() {
        guard !closed, NSApp.isActive else { return }
        activationDeadline?.invalidate(); activationDeadline = nil
        panel.disableCursorRects()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(selectionView)
        selectionView.refreshPointer()
    }
    func close() {
        guard !closed else { return }
        closed = true
        activationDeadline?.invalidate(); activationDeadline = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        selectionView.releasePointer()
        let restore = panel.isKeyWindow && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        selectionView.image = nil
        selectionView.selected = nil; selectionView.cancelled = nil; selectionView.interacted = nil
        panel.orderOut(nil); panel.close()
        if restore { previousApplication?.activate(options: []) }
    }
}
