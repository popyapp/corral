import AppKit
import SwiftUI

/// Light or dark, independent of the system.
///
/// Corral already followed the system appearance — every surface it draws is a
/// semantic colour, so a Mac in dark mode always got a dark Corral. What was
/// missing is the choice: a monitor you leave open all day is exactly the kind
/// of window someone wants dark on a light desktop, or the reverse.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// nil hands the decision back to macOS.
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Owns the choice and applies it to the whole app.
///
/// Set on `NSApp` rather than per-window: the menu bar's menu, the About panel
/// and the confirmation sheets are all windows Corral does not own directly,
/// and a per-window override would leave them in the system's appearance while
/// the main window sat in the chosen one.
@MainActor
final class AppearanceController: ObservableObject {
    static let shared = AppearanceController()

    private static let key = "appearanceMode"

    @Published var mode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.key)
            apply()
        }
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.key)
        mode = stored.flatMap(AppearanceMode.init(rawValue:)) ?? .system
    }

    func apply() {
        NSApp.appearance = mode.appearance
    }
}
