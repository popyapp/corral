import SwiftUI

/// The right-edge rail: one ring per vendor, stacked.
///
/// A ring rather than a bar because the rail is narrow and a ring reads at a
/// glance from the corner of your eye — you see how much of the circle is gone
/// without reading anything. The percentage under it is for when you do look.
///
/// One ring per *vendor*, not per agent. Twelve agents would be twelve rings
/// and the rail would become a list, which is what the window is for.
struct RailView: View {
    @EnvironmentObject var model: CorralViewModel

    /// Which ring the pointer is over, if any — worked out in AppKit and passed
    /// in, rather than found here.
    ///
    /// SwiftUI's `onHover` cannot do this job. It installs a tracking area that
    /// is live only while its own app is frontmost, and this rail is meant to
    /// be read *while you are working somewhere else* — which is every moment
    /// that matters. `RailInterceptor` tracks with `.activeAlways` instead, and
    /// `RailLayout` is the arithmetic the two of them share.
    var hovering: Int?

    /// Closed, the rail is a line. It spends nearly all of its life that way,
    /// so that is the state it has to be designed for: a permanent mark on
    /// somebody's screen earns its place by being almost nothing until it is
    /// looked at.
    var expanded: Bool

    /// One animation, not two.
    ///
    /// This view does not animate anything, and that is the point. The window
    /// is what moves — AppKit grows it from a line to the full width — and this
    /// only ever draws the correct thing for whatever width it has been given.
    ///
    /// It used to animate as well: a spring on the container, a transition on
    /// the rings. Two animation systems then owned the same geometry, with
    /// different curves and different durations, and they disagreed for the
    /// whole quarter second in between. What that looked like was the closed
    /// line drifting left and vanishing while the panel opened around it.
    ///
    /// So there is nothing here to fight with. The surface is drawn at whatever
    /// size the window currently is — at five points it *is* the line, which is
    /// why there is no separate closed shape any more. The rings are laid out
    /// at their final width, pinned to the edge the rail is attached to, and
    /// clipped. As the window widens they are uncovered from the right, which
    /// is a drawer being pulled out, and it is free: the clip does it.
    var body: some View {
        // An overlay, not a stack. A `ZStack` sizes itself to its widest child,
        // so a fixed-width column of rings inside one would hold the whole view
        // at the open width even while the window was five points across — and
        // an oversized child gets *centred*, so the rings would have been
        // trimmed off both sides instead of uncovered from one. An overlay does
        // not change the size of what it is over, so the shape keeps taking the
        // window's width and the rings hang off the side of it, aligned to the
        // edge the rail is attached to and cut off at the window's frame.
        HUDShape(anchor: .right)
            .fill(HUD.surface)
            .overlay(alignment: .trailing) {
                if expanded {
                    VStack(spacing: RailLayout.spacing) {
                        ForEach(Array(model.vendorUsages.enumerated()), id: \.element.id) {
                            index, usage in
                            RailItem(usage: usage, highlighted: index == hovering)
                        }
                    }
                    .padding(.vertical, RailLayout.margin)
                    .padding(.leading, 12)
                    .padding(.trailing, 8)
                    // Its final width, whatever the window is doing right now.
                    // Laying the rings out inside something that is still
                    // growing would reflow them on every frame of the opening.
                    .frame(width: Self.width)
                }
            }
            .clipped()
    }

    /// The closed line, in points. Matches `HUDMetrics.size`.
    static let lineWidth: CGFloat = 5

    static func height(for count: Int) -> CGFloat { RailLayout.height(for: count) }
    static let width: CGFloat = 74
}

/// Where each ring sits, in one place.
///
/// The rail is laid out by SwiftUI and hit-tested by AppKit, so the two have to
/// agree about it exactly. Rather than have each measure separately and drift,
/// both read these.
enum RailLayout {
    static let itemHeight: CGFloat = 66
    static let spacing: CGFloat = 15
    static let margin: CGFloat = 18

    /// How much of the screen's height the rail is kept away from at each end.
    /// Used to place it by its middle, so that opening and closing does not
    /// move it.
    static let railMargin: CGFloat = 60

    static func height(for count: Int) -> CGFloat {
        let items = max(1, count)
        return CGFloat(items) * itemHeight + CGFloat(items - 1) * spacing + margin * 2
    }

    /// The middle of one ring, measured down from the top of the rail.
    static func centre(of index: Int) -> CGFloat {
        margin + CGFloat(index) * (itemHeight + spacing) + itemHeight / 2
    }

    /// Which ring a point falls in, measured down from the top of the rail.
    static func index(atDepth y: CGFloat, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let stride = itemHeight + spacing
        let offset = y - margin
        guard offset >= 0 else { return nil }
        let index = Int(offset / stride)
        guard index < count else { return nil }
        // Inside the gap between two rings is not inside either of them.
        return offset - CGFloat(index) * stride <= itemHeight ? index : nil
    }
}

private struct RailItem: View {
    let usage: VendorUsage
    var highlighted = false

    var body: some View {
        VStack(spacing: 3) {
            RingGauge(
                fraction: usage.fraction,
                tint: Meter.tint(for: usage.fraction),
                tool: usage.tool
            )
            Text(String(format: "%.0f%%", (usage.fraction * 100).rounded()))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(HUD.primary)
        }
        .frame(height: RailLayout.itemHeight)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(highlighted ? 0.07 : 0))
        )
        .animation(.easeOut(duration: 0.12), value: highlighted)
    }
}

/// A circular gauge with the tool's own icon at the centre.
struct RingGauge: View {
    let fraction: Double
    let tint: Color
    let tool: Tool
    var diameter: CGFloat = 42
    var lineWidth: CGFloat = 3
    /// Passed in rather than fixed: this ring appears both on the panel's black
    /// and in a window that follows the system appearance, and a track that
    /// looked right on one would disappear on the other.
    var fill: Color = HUD.raised
    var track: Color = Color.white.opacity(0.10)

    var body: some View {
        ZStack {
            Circle()
                .fill(fill)
            Circle()
                .strokeBorder(track, lineWidth: lineWidth)
            Circle()
                .inset(by: lineWidth / 2)
                // Never exactly zero: an arc of no length draws nothing, and a
                // ring with no mark at all looks like a ring that failed to
                // load rather than one at the start of its range.
                .trim(from: 0, to: max(0.004, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                // Starting from the top, the way a dial is read.
                .rotationEffect(.degrees(-90))
            ToolGlyph(tool: tool, size: diameter * 0.40)
        }
        .frame(width: diameter, height: diameter)
    }
}

// ─ The popover ──────────────────────────────────────────────────────────────

/// What one ring is made of, shown beside it.
///
/// Deliberately not interactive — it appears on hover and goes when the pointer
/// leaves, like a rich tooltip. Making it clickable would mean tracking the
/// mouse across the gap between two windows, and every version of that is
/// fragile in a way the user feels as the panel flickering.
struct UsagePopoverView: View {
    let usage: VendorUsage
    @EnvironmentObject var model: CorralViewModel

    var body: some View {
        HStack(spacing: 0) {
            card
            // The tail, aimed at the ring this belongs to. Without it the card
            // is a second window that happened to appear nearby.
            Pointer()
                .fill(HUD.surface)
                .frame(width: Self.pointerWidth, height: 18)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ToolGlyph(tool: usage.tool, size: 17)
                Text("\(usage.name) Usage")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(HUD.primary)
            }
            .padding(.bottom, 13)

            if let account = usage.account {
                ForEach(account.limits, id: \.label) { limit in
                    LimitBlock(limit: limit)
                }
                Text(freshness(of: account))
                    .font(.system(size: 10))
                    .foregroundStyle(isStale(account) ? Meter.tint(for: 0.7) : HUD.faint)
                    .padding(.top, 2)
            } else {
                // Said plainly rather than left blank, and said *here*. A ring
                // with no allowance under it reads as "nothing used"; this says
                // "not published", and for Claude it says how to change that —
                // this popover is where somebody is looking when they wonder.
                Text(missingNote)
                    .font(.system(size: 10.5))
                    .foregroundStyle(HUD.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let week = usage.breakdowns.first(where: { $0.window == "7-day" }) {
                Rectangle()
                    .fill(Color.white.opacity(0.09))
                    .frame(height: 1)
                    .padding(.vertical, 12)

                ModelBlock(breakdown: week)
            }

            if !usage.sessions.isEmpty {
                Rectangle()
                    .fill(Color.white.opacity(0.09))
                    .frame(height: 1)
                    .padding(.vertical, 12)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(usage.sessions.prefix(4), id: \.group.id) { row in
                        AgentLine(group: row.group, use: row.use)
                    }
                    if usage.sessions.count > 4 {
                        Text("and \(usage.sessions.count - 4) more")
                            .font(.system(size: 10))
                            .foregroundStyle(HUD.faint)
                    }
                }
            }
        }
        .padding(15)
        .frame(width: UsagePopoverView.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(HUD.surface)
        )
    }

    /// Why there is no allowance here, and what to do about it when there is
    /// something to do.
    private var missingNote: String {
        switch usage.tool {
        case .claudeCode, .claudeDesktop:
            return "Claude Code keeps its limits off disk, but it will hand them to a "
                + "status line. Turn it on under \u{201C}Report Usage to Corral\u{201D}."
        case .cursorAgent, .cursor:
            return "Cursor does not publish what your account has left, here or "
                + "anywhere else on this Mac."
        default:
            return "\(usage.name) does not record its limits on this Mac."
        }
    }

    static let width: CGFloat = 300
    static let pointerWidth: CGFloat = 8
    /// What the window has to be, card plus tail.
    static var totalWidth: CGFloat { width + pointerWidth }

    private func freshness(of usage: ToolUsage) -> String {
        let age = Date().timeIntervalSince(usage.observedAt)
        return age < 90 ? "just now" : "as of \(age.durationString) ago"
    }

    private func isStale(_ usage: ToolUsage) -> Bool {
        Date().timeIntervalSince(usage.observedAt) > 3600
    }
}

/// The popover's tail, pointing right at the rail.
private struct Pointer: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// One allowance window: what it is, when it comes back, and how much is gone.
private struct LimitBlock: View {
    let limit: UsageLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(HUD.primary)
                Spacer()
                if let resets = limit.resetsAt {
                    Text("Resets \(Self.reset.string(from: resets))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(HUD.secondary)
                }
            }
            Meter(fraction: limit.usedFraction, tint: Meter.tint(for: limit.usedFraction), height: 5)
            // The bar fills as the allowance is spent, and the line underneath
            // says what is left. Those are the two halves of the same fact, and
            // the second one is the half you act on: nobody decides anything
            // from "73% used" that they would not decide faster from "27% left".
            Text(remaining)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(HUD.secondary)
        }
        .padding(.bottom, 12)
    }

    private var remaining: String {
        let left = (1 - limit.usedFraction) * 100
        // Past the limit there is nothing left, and saying "-3% left" would be
        // arithmetic rather than an answer.
        return left <= 0
            ? "none left · waiting for the reset"
            : String(format: "%.0f%% left", left.rounded())
    }

    /// The tools name their windows by length; a person names them by what
    /// they are for. Only the two that have an ordinary name get one.
    private var title: String {
        switch limit.label {
        case "5-hour": return "Current session"
        case "7-day": return "All models"
        default: return limit.label
        }
    }

    /// An absolute time, not "in 20.6d". A reset is something you plan around,
    /// and "Wednesday 11:59 PM" is a thing you can plan around in a way that a
    /// duration is not.
    private static let reset: DateFormatter = {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// Which models did the work, under the allowance they were spent against.
///
/// Sits below the limits on purpose and is worded to stay clearly separate from
/// them. A limit is the vendor's arithmetic over an allowance; these are tokens
/// counted off this machine, and the vendors weight models against each other
/// in ways nothing local can see — so a model with 40% of the output has not
/// necessarily taken 40% of the week. "of output" is the whole caption, and it
/// is the honest one.
private struct ModelBlock: View {
    let breakdown: ModelBreakdown

    private static let shown = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Output by model")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(HUD.primary)
                Spacer()
                Text("last 7 days")
                    .font(.system(size: 10.5))
                    .foregroundStyle(HUD.secondary)
            }

            ForEach(breakdown.models.prefix(Self.shown)) { use in
                HStack(spacing: 8) {
                    Text(use.shortName)
                        .font(.system(size: 11))
                        .foregroundStyle(HUD.secondary)
                        .lineLimit(1)
                        // Middle, not tail: the `[1m]` at the end of a name is
                        // the difference between a 200K window and a 1M one.
                        .truncationMode(.middle)
                        .frame(width: 104, alignment: .leading)

                    Meter(
                        fraction: breakdown.share(use),
                        tint: HUD.primary.opacity(0.55),
                        height: 4
                    )
                    .frame(maxWidth: .infinity)

                    Text(String(format: "%.0f%%", (breakdown.share(use) * 100).rounded()))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(HUD.primary)
                        .frame(width: 34, alignment: .trailing)
                }
                .help("\(use.model): \(use.outputSummary) out, \(use.inputSummary) in")
            }

            if breakdown.models.count > Self.shown {
                Text("and \(breakdown.models.count - Self.shown) more")
                    .font(.system(size: 10))
                    .foregroundStyle(HUD.faint)
            }
        }
    }
}

/// One agent underneath the vendor: which project, how full, what it is doing.
private struct AgentLine: View {
    let group: AgentGroup
    let use: ContextUse
    @EnvironmentObject var model: CorralViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(group.root.projectName ?? group.root.tool.displayName)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(HUD.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(state.label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.color(for: state))
            }
            HStack(spacing: 6) {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(HUD.faint)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(when)
                    .font(.system(size: 10))
                    .foregroundStyle(HUD.faint)
            }
            Meter(fraction: use.fraction, tint: Meter.tint(for: use.fraction), height: 3)
        }
    }

    private var state: AgentState { model.groupActivity(for: group).state }

    private var subtitle: String {
        let where_ = group.root.tty != nil ? "Terminal" : group.root.tool.displayName
        return "\(where_) · context \(String(format: "%.0f%%", (use.fraction * 100).rounded()))"
    }

    private var when: String {
        guard let activity = model.sessionActivity(for: group) else { return "" }
        let age = Date().timeIntervalSince(activity.at)
        return age < 90 ? "just now" : "\(age.durationString) ago"
    }
}
