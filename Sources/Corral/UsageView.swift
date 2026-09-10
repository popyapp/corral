import SwiftUI

/// The panel's contents, in both of its sizes.
///
/// Collapsed it says one thing: the fullest number Corral is tracking and what
/// it belongs to. Not a summary — a sentence. A strip that lives permanently on
/// someone's screen has to be readable without being looked at, and two facts
/// side by side already need looking at.
///
/// Expanded it separates the two questions it can answer, because they are
/// answered by different things and fixed by different things. An *allowance*
/// is the account's, shared by every session you have anywhere, and out of your
/// hands until a clock turns over. A *context window* is this one conversation
/// filling up, and it is the only one of the two you can do something about
/// right now.
struct HUDPanelView: View {
    let anchor: HUDAnchor
    let expanded: Bool
    @EnvironmentObject var model: CorralViewModel

    var body: some View {
        ZStack {
            HUDShape(anchor: anchor)
                .fill(HUD.surface)

            if expanded {
                UsageDetail(anchor: anchor)
                    .padding(insets)
            } else {
                CollapsedLine(anchor: anchor)
                    .padding(insets)
            }
        }
        .overlay(alignment: gaugeAlignment) { gauge }
    }

    /// Keeps content off the flared corners, which are the widest part of the
    /// shape and the part that is not really there.
    private var insets: EdgeInsets {
        switch anchor {
        case .top:
            return EdgeInsets(top: 4, leading: 22, bottom: 10, trailing: 22)
        case .right:
            return EdgeInsets(top: 22, leading: 10, bottom: 22, trailing: 6)
        case .left:
            return EdgeInsets(top: 22, leading: 6, bottom: 22, trailing: 10)
        }
    }

    private var gaugeAlignment: Alignment {
        switch anchor {
        case .top: return .bottom
        case .right: return .leading
        case .left: return .trailing
        }
    }

    @ViewBuilder
    private var gauge: some View {
        let fullest = model.fullest
        EdgeGauge(
            anchor: anchor,
            fraction: fullest?.fraction ?? 0,
            tint: Meter.tint(for: fullest?.fraction ?? 0)
        )
        .padding(
            anchor == .top ? .horizontal : .vertical,
            HUD.shellRadius + 11
        )
        .padding(anchor == .top ? .bottom : (anchor == .left ? .trailing : .leading), 3)
    }
}

// ─ Collapsed ────────────────────────────────────────────────────────────────

private struct CollapsedLine: View {
    let anchor: HUDAnchor
    @EnvironmentObject var model: CorralViewModel

    var body: some View {
        if let fullest = model.fullest {
            switch anchor {
            case .top:
                HStack(spacing: 9) {
                    ToolGlyph(tool: fullest.tool, size: 15)
                    Text(percent(fullest.fraction))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(HUD.primary)
                    Spacer(minLength: 8)
                    Text(fullest.label)
                        .font(.system(size: 12))
                        .foregroundStyle(HUD.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            case .right, .left:
                VStack(spacing: 5) {
                    ToolGlyph(tool: fullest.tool, size: 16)
                    Text(percent(fullest.fraction))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(HUD.primary)
                }
            }
        } else {
            Image(systemName: "gauge.low")
                .font(.system(size: 13))
                .foregroundStyle(HUD.faint)
        }
    }

    private func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", (fraction * 100).rounded())
    }
}

// ─ Expanded ─────────────────────────────────────────────────────────────────

private struct UsageDetail: View {
    let anchor: HUDAnchor
    @EnvironmentObject var model: CorralViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    allowances
                    contexts
                }
                .padding(.bottom, 10)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "gauge.with.needle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(HUD.faint)
            Text("Usage")
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(HUD.primary)
            Spacer()
            Button {
                EdgePanelController.shared.collapse()
            } label: {
                Image(systemName: anchor == .top ? "chevron.up"
                      : (anchor == .left ? "chevron.left" : "chevron.right"))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(HUD.faint)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.bottom, 12)
    }

    // ─ Allowance ────────────────────────────────────────────────────────────

    private var allowances: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Allowance")

            let usages = model.accountUsages
            if usages.isEmpty {
                Note("No tool on this Mac writes its allowance down.")
            } else {
                ForEach(usages, id: \.tool) { AllowanceCard(usage: $0) }
            }

            if !silent.isEmpty { Note(silentNote) }
        }
    }

    /// Tools that are running but keep no allowance on disk.
    ///
    /// Named rather than left out. A panel that silently omits Claude Code
    /// reads as "Claude Code is fine"; saying why nothing is shown is the
    /// difference between a gap and an answer.
    private var silent: [String] {
        let reported = Set(model.accountUsages.map(\.tool))
        var names: [String] = []
        for group in model.groups where !reported.contains(group.root.tool) {
            let vendor = group.root.tool.vendor
            if !names.contains(vendor) { names.append(vendor) }
        }
        return names.sorted()
    }

    private var silentNote: String {
        let list = ListFormatter.localizedString(byJoining: silent)
        let verb = silent.count == 1
            ? "does not record its limits"
            : "do not record their limits"
        return "\(list) \(verb) on this Mac."
    }

    // ─ Context ──────────────────────────────────────────────────────────────

    private var contexts: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Context")

            let rows = model.contexts
            if rows.isEmpty {
                Note("No running agent has said anything Corral can measure yet.")
            } else {
                ForEach(rows, id: \.group.id) { row in
                    ContextRow(group: row.group, use: row.use)
                }
            }
        }
    }
}

// ─ Pieces ───────────────────────────────────────────────────────────────────

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(HUD.faint)
    }
}

private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(HUD.faint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One account's windows, with the age of the reading under them.
///
/// A raised surface and no border at all: depth here comes from light, the way
/// it does on the panels this was drawn after. A stroke would put a second line
/// next to the gauge and the two would compete.
private struct AllowanceCard: View {
    let usage: ToolUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                ToolGlyph(tool: usage.tool, size: 14)
                Text(usage.tool.displayName)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(HUD.primary)
                Spacer()
                if let plan = usage.plan {
                    Text(plan)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(HUD.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                }
            }

            ForEach(usage.limits, id: \.label) { LimitBar(limit: $0) }

            Text(freshness)
                .font(.system(size: 9.5))
                .foregroundStyle(isStale ? Meter.tint(for: 0.7) : HUD.faint)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: HUD.cardRadius, style: .continuous)
                .fill(HUD.raised)
        )
    }

    /// The age of the reading, always. These figures are a by-product of the
    /// last turn the tool took, so one from last week looks exactly like one
    /// from a minute ago unless the panel says otherwise.
    private var age: TimeInterval { Date().timeIntervalSince(usage.observedAt) }
    private var isStale: Bool { age > 3600 }

    private var freshness: String {
        age < 90 ? "just now" : "as of \(age.durationString) ago"
    }
}

private struct LimitBar: View {
    let limit: UsageLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(limit.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(HUD.secondary)
                Spacer()
                if let resets = limit.resetsAt, resets > Date() {
                    Text("resets in \(resets.timeIntervalSinceNow.durationString)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(HUD.faint)
                }
                Text(String(format: "%.0f%%", (limit.usedFraction * 100).rounded()))
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Meter.tint(for: limit.usedFraction))
            }
            Meter(fraction: limit.usedFraction, tint: Meter.tint(for: limit.usedFraction))
        }
    }
}

private struct ContextRow: View {
    let group: AgentGroup
    let use: ContextUse

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                ToolGlyph(
                    tool: group.root.tool,
                    executablePath: group.root.executablePath,
                    terminal: group.root.tty != nil,
                    size: 13
                )
                Text(group.root.projectName ?? group.root.tool.displayName)
                    .font(.system(size: 11))
                    .foregroundStyle(HUD.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text(size)
                    .font(.system(size: 9.5))
                    .monospacedDigit()
                    .foregroundStyle(HUD.faint)
                Text(String(format: "%.0f%%", (use.fraction * 100).rounded()))
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Meter.tint(for: use.fraction))
            }
            Meter(fraction: use.fraction, tint: Meter.tint(for: use.fraction))
        }
        .help(detail)
    }

    private var size: String {
        "\(thousands(use.usedTokens)) / \(thousands(use.windowTokens))"
    }

    private func thousands(_ value: Int) -> String {
        value >= 1_000_000
            ? String(format: "%.1fM", Double(value) / 1_000_000)
            : "\(value / 1000)k"
    }

    /// The tooltip is where the uncertainty goes. A window Corral inferred
    /// rather than read is still the best answer available, and burying the
    /// caveat in a row this narrow would cost more than it is worth — but it
    /// should be findable by anyone who wonders.
    private var detail: String {
        use.windowIsCertain
            ? "\(use.usedTokens) of \(use.windowTokens) tokens"
            : "\(use.usedTokens) tokens. Window size taken from your configured "
                + "model — a session started on a different one would be measured "
                + "against the wrong size."
    }
}

/// A thin bar. Clamped where it draws, never where it is stored.
struct Meter: View {
    let fraction: Double
    var tint: Color = Theme.trend
    var height: CGFloat = 3.5
    /// See `RingGauge.track` — the same bar is drawn on two very different
    /// backgrounds.
    var track: Color = Color.white.opacity(0.10)

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: height)
    }

    /// Green until it is worth noticing, amber while there is still room, red
    /// once the thing you are watching is nearly gone.
    static func tint(for fraction: Double) -> Color {
        switch fraction {
        case ..<0.6: return Color(red: 0.30, green: 0.78, blue: 0.50)
        case ..<0.85: return Color(red: 0.96, green: 0.72, blue: 0.26)
        default: return Color(red: 0.94, green: 0.40, blue: 0.36)
        }
    }
}
