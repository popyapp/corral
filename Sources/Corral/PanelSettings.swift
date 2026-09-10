import Combine
import Foundation

/// Where the usage panel lives, if anywhere.
enum PanelPlacement: String, CaseIterable, Identifiable {
    case top, right, left, off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .top: return "Top of Screen"
        case .right: return "Right Edge"
        case .left: return "Left Edge"
        case .off: return "Off"
        }
    }

    var anchor: HUDAnchor? {
        switch self {
        case .top: return .top
        case .right: return .right
        case .left: return .left
        case .off: return nil
        }
    }
}

/// Which of Corral's three surfaces you want.
///
/// The window, the menu bar item and the usage panel each answer the same
/// question at a different cost of attention, and nobody wants all three. The
/// point of making them independent is that the panel has to work with the menu
/// bar item turned off — otherwise "hide the menu bar item" means "lose the
/// app", and the setting is a trap.
///
/// One rule holds them together, in the menus: you cannot turn off the last way
/// back in. See `wouldStrandTheApp`.
@MainActor
final class PanelSettings: ObservableObject {
    static let shared = PanelSettings()

    private static let placementKey = "usagePanelPlacement"
    private static let menuBarKey = "showsMenuBarItem"
    private static let positionKey = "usagePanelPosition"

    /// Defaults to the top edge, which is the arrangement the panel was drawn
    /// for: the flare where it meets the bezel only pays off against a black
    /// notch. The right edge is the same panel turned a quarter turn, for the
    /// displays and the people that suit better.
    @Published var placement: PanelPlacement {
        didSet { UserDefaults.standard.set(placement.rawValue, forKey: Self.placementKey) }
    }

    @Published var showsMenuBarItem: Bool {
        didSet { UserDefaults.standard.set(showsMenuBarItem, forKey: Self.menuBarKey) }
    }

    /// Where along its edge the panel sits, 0…1 from the left or the top.
    ///
    /// A fraction rather than a coordinate so it lands in the same *visual*
    /// place on a screen of a different size. Someone who drags it a third of
    /// the way along wants it a third of the way along on the laptop too, not
    /// four hundred points from the corner of a display that is not that wide.
    @Published var position: Double {
        didSet { UserDefaults.standard.set(position, forKey: Self.positionKey) }
    }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Self.placementKey: PanelPlacement.top.rawValue,
            Self.menuBarKey: true,
            Self.positionKey: 0.5,
        ])
        placement = defaults.string(forKey: Self.placementKey)
            .flatMap(PanelPlacement.init(rawValue:)) ?? .top
        showsMenuBarItem = defaults.bool(forKey: Self.menuBarKey)
        position = min(max(defaults.double(forKey: Self.positionKey), 0), 1)
    }

    /// True when turning this off would leave no way to reach Corral at all.
    ///
    /// Both surfaces off, with the window closed, is an app that is running and
    /// cannot be summoned — reachable only by force-quitting and launching it
    /// again. The offer is refused rather than made and then regretted.
    func wouldStrandTheApp(turningOffMenuBar: Bool) -> Bool {
        turningOffMenuBar ? placement == .off : !showsMenuBarItem
    }
}
