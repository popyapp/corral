import SwiftUI

/// The Usage tab in the window.
///
/// The same facts as the edge panel, with room. The panel has to answer in one
/// glance while you are working somewhere else, so it shows the fullest thing
/// and hides the rest behind a hover. Here nothing is hidden: every allowance
/// window, every agent, and the dates the figures were taken.
///
/// It also has the one thing the panel cannot have. The popover ignores the
/// mouse on purpose — it is a tooltip — so it can only *say* that Claude needs
/// setting up. A window can offer the button.
struct UsagePane: View {
    @EnvironmentObject private var model: CorralViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if model.vendorUsages.isEmpty {
                    nothingRunning
                } else {
                    rings
                    allowances
                    contexts
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // ─ The top row ──────────────────────────────────────────────────────────

    private var rings: some View {
        HStack(alignment: .top, spacing: 26) {
            ForEach(model.vendorUsages) { usage in
                VStack(spacing: 7) {
                    RingGauge(
                        fraction: usage.fraction,
                        tint: Meter.tint(for: usage.fraction),
                        tool: usage.tool,
                        diameter: 54,
                        lineWidth: 4,
                        fill: Theme.rowBackground,
                        track: Color.primary.opacity(0.10)
                    )
                    Text(String(format: "%.0f%%", (usage.fraction * 100).rounded()))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    // The ring is one number out of two different kinds, so it
                    // never appears without the word for which kind it is.
                    Text(usage.headline)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.faint)
                }
            }
            Spacer()
        }
    }

    // ─ Allowances ───────────────────────────────────────────────────────────

    private var allowances: some View {
        VStack(alignment: .leading, spacing: 10) {
            PaneLabel("Allowance")
            ForEach(model.vendorUsages) { AllowancePanel(usage: $0) }
        }
    }

    // ─ Contexts ─────────────────────────────────────────────────────────────

    private var contexts: some View {
        VStack(alignment: .leading, spacing: 10) {
            PaneLabel("Context")
            let rows = model.contexts
            if rows.isEmpty {
                Text("No running agent has said anything Corral can measure yet.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.faint)
            } else {
                // Every one of them. The panel stops at four because it is a
                // strip on the edge of a screen; a window that truncated a list
                // of twelve would just be a worse panel.
                ForEach(rows, id: \.group.id) { row in
                    PaneContextRow(group: row.group, use: row.use)
                }
            }
        }
    }

    private var nothingRunning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing to measure")
                .font(.system(size: 14, weight: .semibold))
            Text("Usage appears once an agent is running, or once a tool has "
                + "written down what your account has left.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.subtle)
        }
        .frame(maxWidth: 420, alignment: .leading)
        .padding(.top, 40)
    }
}

// ─ Pieces ───────────────────────────────────────────────────────────────────

private struct PaneLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(Theme.faint)
    }
}

/// One vendor's allowance, or the reason there isn't one.
private struct AllowancePanel: View {
    let usage: VendorUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ToolGlyph(tool: usage.tool, size: 15)
                Text(usage.name)
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
                if let plan = usage.account?.plan {
                    Pill(text: plan, color: Theme.accent(for: usage.tool))
                }
                if let account = usage.account {
                    Text(freshness(of: account))
                        .font(.system(size: 10.5))
                        .foregroundStyle(isStale(account) ? Theme.Severity.stale.color : Theme.faint)
                }
            }

            if let account = usage.account {
                ForEach(account.limits, id: \.label) { PaneLimitRow(limit: $0) }
            } else {
                missing
            }
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                .fill(Theme.rowBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }

    /// Why there is nothing here — and, where there is something to be done
    /// about it, the button that does it. This is the whole reason the window
    /// carries this section as well as the panel.
    @ViewBuilder
    private var missing: some View {
        if let target = StatusLineSetup.Target.of(usage.tool) {
            VStack(alignment: .leading, spacing: 9) {
                Text(explanation(for: target))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.subtle)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Set Up \(target.name) Reporting…") { StatusLineSetup.offer(target) }
                    .controlSize(.small)
            }
        } else {
            Text("\(usage.name) does not record what your account has left on this Mac.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.subtle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The two agents publish different things, and the offer has to be honest
    /// about which. Promising Cursor's limits and then never showing them would
    /// be worse than not offering at all.
    private func explanation(for target: StatusLineSetup.Target) -> String {
        switch target.tool {
        case .cursorAgent:
            return "Cursor does not publish what your account has left anywhere on this "
                + "Mac. It will report how full each session's context is, which is "
                + "otherwise unreadable — its conversation store is ordered by an "
                + "encrypted index Corral does not open."
        default:
            return "Claude Code keeps its limits off disk, but it hands them to a status "
                + "line command on every update. Corral can be that command — no "
                + "network, no account, nothing leaves this Mac."
        }
    }

    private func freshness(of usage: ToolUsage) -> String {
        let age = Date().timeIntervalSince(usage.observedAt)
        return age < 90 ? "just now" : "as of \(age.durationString) ago"
    }

    private func isStale(_ usage: ToolUsage) -> Bool {
        Date().timeIntervalSince(usage.observedAt) > 3600
    }
}

private struct PaneLimitRow: View {
    let limit: UsageLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                Spacer()
                if let resets = limit.resetsAt {
                    Text("resets \(Self.reset.string(from: resets))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.faint)
                }
                Text(remaining)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Meter.tint(for: limit.usedFraction))
            }
            Meter(
                fraction: limit.usedFraction,
                tint: Meter.tint(for: limit.usedFraction),
                height: 5,
                track: Color.primary.opacity(0.09)
            )
        }
    }

    private var title: String {
        switch limit.label {
        case "5-hour": return "Current session"
        case "7-day": return "All models"
        default: return limit.label
        }
    }

    private var remaining: String {
        let left = (1 - limit.usedFraction) * 100
        return left <= 0 ? "none left" : String(format: "%.0f%% left", left.rounded())
    }

    private static let reset: DateFormatter = {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct PaneContextRow: View {
    let group: AgentGroup
    let use: ContextUse
    @EnvironmentObject private var model: CorralViewModel

    var body: some View {
        HStack(spacing: 10) {
            ToolGlyph(
                tool: group.root.tool,
                executablePath: group.root.executablePath,
                terminal: group.root.tty != nil,
                size: 15
            )
            Text(group.root.projectName ?? group.root.tool.displayName)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 170, alignment: .leading)

            Meter(
                fraction: use.fraction,
                tint: Meter.tint(for: use.fraction),
                height: 5,
                track: Color.primary.opacity(0.09)
            )
            .frame(maxWidth: .infinity)

            Text(size)
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(Theme.faint)
                .frame(width: 96, alignment: .trailing)
            Text(String(format: "%.0f%%", (use.fraction * 100).rounded()))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Meter.tint(for: use.fraction))
                .frame(width: 40, alignment: .trailing)
            Text(model.groupActivity(for: group).state.label)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.color(for: model.groupActivity(for: group).state))
                .frame(width: 70, alignment: .trailing)
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

    /// Where the uncertainty goes: a window Corral inferred rather than read is
    /// still the best answer available, but somebody who wonders should be able
    /// to find out which it was.
    private var detail: String {
        use.windowIsCertain
            ? "\(use.usedTokens) of \(use.windowTokens) tokens, as the session reported it"
            : "\(use.usedTokens) tokens. The window size was taken from your configured "
                + "model — a session started on a different one would be measured against "
                + "the wrong size. Setting up Claude usage replaces this with the real one."
    }
}
