import AppKit
import SwiftUI

/// One persisted preference for every AppKit window and menu in the application.
@objc(RCAppearanceController)
@MainActor
final class RCAppearanceController: NSObject {
    static let preferenceKey = "RCAppAppearance"

    @objc static func applySavedAppearance() {
        let value = UserDefaults.standard.string(forKey: preferenceKey)
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    @objc static func makePreferencesController() -> NSViewController {
        let controller = NSHostingController(rootView: AppearancePreferencesView())
        controller.view.frame = NSRect(x: 0, y: 0, width: 700, height: 340)
        return controller
    }
}

struct AppearancePreferencesView: View {
    @State private var languageRevision = 0
    @AppStorage(RCAppearanceController.preferenceKey) private var selection = "system"

    private let choices = [
        ("system", "Theme System", "circle.lefthalf.filled"),
        ("light", "Theme Light", "sun.max.fill"),
        ("dark", "Theme Dark", "moon.fill")
    ]

    var body: some View {
        let _ = languageRevision
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text(RCLocalizedString("Theme Description", comment: "")).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                ForEach(choices, id: \.0) { choice in
                    Button {
                        selection = choice.0
                        RCAppearanceController.applySavedAppearance()
                    } label: {
                        VStack(spacing: 14) {
                            Image(systemName: choice.2)
                                .font(.system(size: 28, weight: .light))
                                .foregroundStyle(selection == choice.0 ? Color.accentColor : .secondary)
                            Text(RCLocalizedString(choice.1, comment: "")).font(.body.weight(.medium))
                            Image(systemName: selection == choice.0 ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selection == choice.0 ? Color.accentColor : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 22)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18)
                                .strokeBorder(selection == choice.0 ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selection == choice.0 ? 2 : 1)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(RCLocalizedString(choice.1, comment: "")))
                    .accessibilityAddTraits(selection == choice.0 ? .isSelected : [])
                }
            }
            MenuColorPreferences()
        }
        .onReceive(NotificationCenter.default.publisher(for: .RCLanguageDidChange)) { _ in languageRevision += 1 }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, minHeight: 340, alignment: .topLeading)
    }
}

private struct MenuColorPreferences: View {
    @Environment(\.colorScheme) private var colorScheme
    private var paletteKey: String { colorScheme == .dark ? "RCMenuCustomColors" : "RCMenuCustomColorsLight" }
    @AppStorage("RCMenuCustomColorsEnabled") private var enabled = false
    @State private var colors: [String: String] = [:]
    @State private var drafts: [String: String] = [:]
    private var fields: [(String, String, String)] { [("primary", "Menu Primary Color", "#007AFF"), ("text", "Menu Text Color", colorScheme == .dark ? "#FFFFFF" : "#1A1A1A"), ("background", "Menu Background Color", colorScheme == .dark ? "#171717" : "#F2F2F2"), ("hoverText", "Menu Hover Text Color", "#FFFFFF"), ("hoverBackground", "Menu Hover Background Color", "#3478F6")] }
    private func reloadPalette() {
        colors = UserDefaults.standard.dictionary(forKey: paletteKey) as? [String: String] ?? [:]
        drafts = [:]
    }
    private func binding(_ key: String, fallback: String) -> Binding<Color> {
        Binding(get: {
            let hex = colors[key] ?? fallback
            let value = UInt32(hex.dropFirst(), radix: 16) ?? 0xFFFFFF
            return Color(.sRGB, red: Double((value >> 16) & 255)/255, green: Double((value >> 8) & 255)/255, blue: Double(value & 255)/255, opacity: 1)
        }, set: { value in
            guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
            colors[key] = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
            drafts[key] = colors[key]
            UserDefaults.standard.set(colors, forKey: paletteKey)
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle(RCLocalizedString("Customize Menu Colors", comment: ""), isOn: $enabled)
                .toggleStyle(.switch)
            Text(RCLocalizedString("Menu Colors Description", comment: "")).font(.caption).foregroundStyle(.secondary)
            ForEach(fields, id: \.0) { field in
                HStack {
                    Text(RCLocalizedString(field.1, comment: ""))
                    Spacer()
                    MenuColorWell(selection: binding(field.0, fallback: field.2), label: RCLocalizedString(field.1, comment: ""))
                        .frame(width: 32, height: 24)
                    TextField("#RRGGBB", text: Binding(get: {
                        drafts[field.0] ?? colors[field.0] ?? field.2
                    }, set: { value in
                        drafts[field.0] = String(value.prefix(32))
                        if let normalized = MenuColorHex.normalize(value) {
                            colors[field.0] = normalized
                            UserDefaults.standard.set(colors, forKey: paletteKey)
                        }
                    }))
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .accessibilityLabel(RCLocalizedString(field.1, comment: "") + " HEX")
                    .onSubmit {
                        if let normalized = MenuColorHex.normalize(drafts[field.0] ?? colors[field.0] ?? field.2) { drafts[field.0] = normalized }
                    }
                    if let draft = drafts[field.0], MenuColorHex.normalize(draft) == nil {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(.red)
                            .help(RCLocalizedString("Enter Six Digit Hex", comment: ""))
                    }
                }
                .disabled(!enabled)
            }
            Button(RCLocalizedString("Reset Menu Colors", comment: "")) {
                colors = [:]
                drafts = [:]
                enabled = false
                UserDefaults.standard.removeObject(forKey: "RCMenuCustomColors")
                UserDefaults.standard.removeObject(forKey: "RCMenuCustomColorsLight")
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .onAppear { reloadPalette() }
        .onChange(of: colorScheme) { _, _ in reloadPalette() }
        .onChange(of: enabled) { _, on in
            if on {
                for field in fields where colors[field.0] == nil { colors[field.0] = field.2 }
                UserDefaults.standard.set(colors, forKey: paletteKey)
            }
        }
    }
}

enum MenuColorHex {
    static func normalize(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard digits.utf8.count == 6, digits.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        return "#" + digits.uppercased()
    }
}

private struct MenuColorWell: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var selection: Color
    let label: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.showPanel(_:)))
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.borderWidth = 1
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.isEnabled = isEnabled
        if !isEnabled, Coordinator.active === context.coordinator {
            NSColorPanel.shared.orderOut(nil)
            NSColorPanel.shared.setTarget(nil)
            NSColorPanel.shared.setAction(nil)
            Coordinator.active = nil
        }
        button.layer?.backgroundColor = NSColor(selection).cgColor
        button.layer?.borderColor = NSColor.separatorColor.cgColor
        button.setAccessibilityLabel(label)
        if Coordinator.active === context.coordinator, !context.coordinator.isUpdating, NSColorPanel.shared.color != NSColor(selection) {
            NSColorPanel.shared.color = NSColor(selection)
        }
    }
    static func dismantleNSView(_ button: NSButton, coordinator: Coordinator) {
        if Coordinator.active === coordinator {
            NSColorPanel.shared.setTarget(nil)
            NSColorPanel.shared.setAction(nil)
            NSColorPanel.shared.orderOut(nil)
            Coordinator.active = nil
        }
    }
    @MainActor final class Coordinator: NSObject {
        static weak var active: Coordinator?
        var parent: MenuColorWell
        var isUpdating = false
        init(_ parent: MenuColorWell) { self.parent = parent }
        @objc func showPanel(_ sender: NSButton) {
            let panel = NSColorPanel.shared
            Self.active = self
            panel.setTarget(self)
            panel.setAction(#selector(colorChanged(_:)))
            panel.showsAlpha = false
            panel.isContinuous = true
            panel.color = NSColor(parent.selection)
            panel.title = parent.label
            if let screen = sender.window?.screen ?? NSScreen.main {
                var frame = panel.frame
                let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
                frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX-frame.width))
                frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY-frame.height))
                panel.setFrame(frame, display: false)
            }
            panel.makeKeyAndOrderFront(sender)
        }
        @objc func colorChanged(_ sender: NSColorPanel) {
            guard Self.active === self else { return }
            isUpdating = true
            parent.selection = Color(nsColor: sender.color.withAlphaComponent(1))
            isUpdating = false
        }
    }
}
