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
                Text(RCLocalizedString("Appearance", comment: "")).font(.title2.weight(.semibold))
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
        }
        .onReceive(NotificationCenter.default.publisher(for: .RCLanguageDidChange)) { _ in languageRevision += 1 }
        .padding(30)
        .frame(width: 700, height: 340, alignment: .topLeading)
        .background(.ultraThinMaterial)
    }
}
