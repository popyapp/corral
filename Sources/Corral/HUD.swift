import SwiftUI

/// Which screen edge the panel is attached to.
enum HUDAnchor: String, CaseIterable, Identifiable {
    case top, right

    var id: String { rawValue }

    var label: String {
        switch self {
        case .top: return "Top"
        case .right: return "Right Edge"
        }
    }
}

/// The outline of a panel that grows out of the edge of the screen.
///
/// One detail carries the whole effect, and it is the one that looks like a
/// mistake in isolation: the shape *flares outward* where it meets the screen
/// edge, in a concave curve, so the black widens into the bezel instead of
/// stopping against it. Without that flare the same panel reads as a black
/// rectangle someone parked under the menu bar. With it, the screen's own
/// border appears to grow the panel.
///
/// The far corners are the opposite — ordinary convex rounding, and larger, so
/// the eye reads one end as attached and the other as free.
struct HUDShape: Shape {
    var anchor: HUDAnchor
    /// The concave flare where the panel meets the screen edge.
    var flare: CGFloat = 11
    /// Convex rounding on the two corners hanging free.
    var radius: CGFloat = 20

    func path(in rect: CGRect) -> Path {
        switch anchor {
        case .top:
            return Self.hangingFromTop(width: rect.width, height: rect.height,
                                       flare: flare, radius: radius)
        case .right:
            // The same outline, turned a quarter turn. Building it once and
            // rotating keeps the two anchors from drifting apart the first time
            // one of the radii is tuned.
            let turned = Self.hangingFromTop(width: rect.height, height: rect.width,
                                             flare: flare, radius: radius)
            return turned.applying(
                CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: rect.width, ty: 0)
            )
        }
    }

    /// Attached along `y == 0`, hanging down.
    private static func hangingFromTop(
        width w: CGFloat, height h: CGFloat, flare: CGFloat, radius: CGFloat
    ) -> Path {
        // Nothing here may exceed what it is drawn in: a collapsed bar is only
        // a few points taller than its own corner radius.
        let flare = max(0, min(flare, w / 2, h / 2))
        let radius = max(0, min(radius, (w - 2 * flare) / 2, h - flare))

        var path = Path()
        // Top-left, out at the screen edge.
        path.move(to: CGPoint(x: 0, y: 0))
        // Curving inward and down: the concave flare.
        path.addArc(
            center: CGPoint(x: 0, y: flare),
            radius: flare,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: flare, y: h - radius))
        path.addArc(
            center: CGPoint(x: flare + radius, y: h - radius),
            radius: radius,
            startAngle: .degrees(180),
            endAngle: .degrees(90),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: w - flare - radius, y: h))
        path.addArc(
            center: CGPoint(x: w - flare - radius, y: h - radius),
            radius: radius,
            startAngle: .degrees(90),
            endAngle: .degrees(0),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: w - flare, y: flare))
        path.addArc(
            center: CGPoint(x: w, y: flare),
            radius: flare,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

// ─ Palette ──────────────────────────────────────────────────────────────────

/// The panel's own colours, which are not the app's.
///
/// Corral's window is a document: it follows the system appearance because it
/// sits among other windows and should look like it belongs. The panel is the
/// opposite — it is meant to read as part of the hardware, and hardware is
/// black in both appearances. So this palette is fixed, and deliberately not
/// theme-aware.
enum HUD {
    /// Not `Color.black`: a true zero reads as a hole on an OLED and as a
    /// smudge next to the bezel on everything else. This is close enough to
    /// disappear into the frame and still show its own edges.
    static let surface = Color(red: 0.043, green: 0.043, blue: 0.047)
    /// One step up, for cards sitting on the surface. Depth comes from light,
    /// not from borders — there is not a single stroke inside the panel.
    static let raised = Color(red: 0.106, green: 0.106, blue: 0.118)

    static let primary = Color.white
    static let secondary = Color.white.opacity(0.62)
    static let faint = Color.white.opacity(0.34)

    /// Radius hierarchy, three steps and no more: the shell, the cards inside
    /// it, and anything round.
    static let shellRadius: CGFloat = 20
    static let cardRadius: CGFloat = 10
}

// ─ The gauge that is also the edge ──────────────────────────────────────────

/// A progress line drawn along the panel's free edge.
///
/// The point of it is that it is not an extra control. The panel already has an
/// outline; filling part of that outline says how full the fullest thing is
/// without adding a single element to the layout. A bar would have to be given
/// room, a label and a place in the reading order; this is just the edge, lit.
struct EdgeGauge: View {
    var anchor: HUDAnchor
    var fraction: Double
    var tint: Color
    var thickness: CGFloat = 2.5

    var body: some View {
        GeometryReader { geo in
            let filled = max(0, min(1, fraction))
            ZStack(alignment: alignment) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(tint)
                    .frame(
                        width: anchor == .top ? geo.size.width * filled : nil,
                        height: anchor == .top ? nil : geo.size.height * filled
                    )
            }
        }
        .frame(
            width: anchor == .top ? nil : thickness,
            height: anchor == .top ? thickness : nil
        )
    }

    /// The line grows from the corner nearest the screen edge, so a nearly
    /// empty gauge still reads as attached to the panel rather than floating in
    /// the middle of it.
    private var alignment: Alignment {
        anchor == .top ? .leading : .top
    }
}
