import AppKit
import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case agents, disk
    var id: String { rawValue }
    var title: String { self == .agents ? "Agents" : "On disk" }
    var symbol: String { self == .agents ? "cpu" : "internaldrive" }
}

/// The window: the two things you came for — what is running right now, and
/// what it has left behind.
struct RootView: View {
    @EnvironmentObject private var model: CorralViewModel
    @EnvironmentObject private var disk: DiskViewModel
    @State private var pane: Pane = .agents

    var body: some View {
        ZStack {
            Theme.windowBackground
            VStack(spacing: 0) {
                Picker("", selection: $pane) {
                    ForEach(Pane.allCases) { pane in
                        Label(pane.title, systemImage: pane.symbol).tag(pane)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
                .padding(.top, 11)

                switch pane {
                case .agents: ContentView()
                case .disk: DiskView()
                }
            }
        }
        // A running version must never be offered for deletion, so the disk
        // side is told what the agent side can see.
        .onAppear { disk.runningVersions = model.runningVersions }
        .onChange(of: model.runningVersions) { disk.runningVersions = $0 }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: CorralViewModel
    @State private var confirmingReclaim = false

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(confirmingReclaim: $confirmingReclaim)
            Divider().opacity(0.5)
            if let banner = model.banner {
                BannerView(banner: banner)
            }
            if model.groups.isEmpty {
                EmptyState()
            } else {
                FilterBar()
                if model.searchHidEverything {
                    NoMatches(query: model.query) { model.query = "" }
                } else {
                    AgentList()
                }
            }
        }
        .confirmationDialog(
            "Stop \(model.staleGroups.count) idle agents?",
            isPresented: $confirmingReclaim,
            titleVisibility: .visible
        ) {
            Button("Quit them (\(model.reclaimableBytes.byteString))") {
                model.stopAllStale(force: false)
            }
            Button("Force Quit", role: .destructive) {
                model.stopAllStale(force: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "These have had no terminal activity for over an hour. "
                + "Quitting asks them to exit cleanly; Force Quit ends them immediately "
                + "and loses anything in flight."
            )
        }
    }
}

// ─ Header ───────────────────────────────────────────────────────────────────

private struct HeaderView: View {
    @EnvironmentObject private var model: CorralViewModel
    @Binding var confirmingReclaim: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Corral")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(model.groups.isEmpty ? "nothing running" : "\(model.totals.processes) processes")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.faint)
            }

            Divider().frame(height: 26).opacity(0.4)

            // Each figure the graph can plot doubles as its selector.
            HStack(alignment: .center, spacing: 22) {
                plottable(.agents, "\(model.totals.agents)", "agents")
                plottable(.memory, model.totals.residentBytes.byteString, "memory")
                plottable(.projects, "\(model.totals.projects)", "projects")
                plottable(
                    .cpu,
                    String(format: "%.1f", model.trends.cpu.latest ?? 0),
                    "cores"
                )
                if model.totals.oldest > 0 {
                    // Nothing records a history for this one, so it is a
                    // readout rather than a selector.
                    Stat(value: model.totals.oldest.durationString, label: "oldest")
                }
            }

            Spacer(minLength: 12)

            HeaderGraph()
                .frame(minWidth: 130, maxWidth: 320, maxHeight: 40)

            if !model.staleGroups.isEmpty {
                Button {
                    confirmingReclaim = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wind")
                        Text("Reclaim \(model.reclaimableBytes.byteString)")
                            .monospacedDigit()
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Severity.stale.color)
                .help(reclaimHelp)
            }

            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now — the list updates every 2 seconds anyway")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func plottable(_ metric: TrendMetric, _ value: String, _ label: String) -> some View {
        Button {
            model.trendMetric = metric
        } label: {
            Stat(value: value, label: label, selected: model.trendMetric == metric)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("Plot \(metric.label.lowercased()) in the graph")
    }

    /// The button says how much it frees; the tooltip has to say what it will
    /// do, to what, and why those and not the others.
    private var reclaimHelp: String {
        let count = model.staleGroups.count
        let names = model.staleGroups.prefix(4).map { model.label(for: $0) }
        let listed = names.joined(separator: ", ")
        let more = count > names.count ? " and \(count - names.count) more" : ""
        return """
        Quit \(count) agent\(count == 1 ? "" : "s") that have written nothing         to their terminal for over an hour, freeing \(model.reclaimableBytes.byteString):         \(listed)\(more).

        Each is asked to exit cleanly, together with the child processes it         started — dev servers, MCP servers, the caffeinate that has been keeping         this Mac awake. Agents that are working, and any waiting on a build they         started, are never included.
        """
    }
}

/// The header's one graph.
///
/// It sits in the gap on the right rather than under the numbers because a
/// chart 68 points wide is a decoration; one this size can actually be read.
/// Which figure it plots is chosen by clicking that figure, and clicking the
/// graph itself changes how far back it looks.
private struct HeaderGraph: View {
    @EnvironmentObject private var model: CorralViewModel

    var body: some View {
        let metric = model.trendMetric
        let series = model.trends.series(for: metric).series(model.trendRange)

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(metric.label.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(Theme.trend)
                Text(model.trendRange.label)
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.faint)
                Spacer(minLength: 4)
                Text(reading(metric))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.subtle)
            }

            if series.count >= 3 {
                TrendGraph(buckets: series, zeroBased: metric.zeroBased)
                    .frame(maxWidth: .infinity)
            } else {
                // Two samples is a segment, not a trend. Saying it is still
                // filling is better than drawing a shape that means nothing.
                HStack {
                    Text("collecting…")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.faint)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.cycleTrendRange() }
        .pointerCursor()
        .help(
            "\(metric.label) over the last \(model.trendRange.label), in "
            + "30-second steps. Click to switch between 15m, 1h and 3h; click a "
            + "figure on the left to plot it instead. A missing column is a "
            + "stretch when Corral was not running."
        )
    }

    /// The current value, in the metric's own units — the graph has no axis, so
    /// the number beside it is what gives the bars a scale.
    private func reading(_ metric: TrendMetric) -> String {
        let latest = model.trends.series(for: metric).latest ?? 0
        switch metric {
        case .cpu: return String(format: "%.2f cores", latest)
        case .memory: return UInt64(max(0, latest)).byteString
        case .agents, .projects: return String(format: "%.0f", latest)
        }
    }
}

private struct BannerView: View {
    @EnvironmentObject private var model: CorralViewModel
    let banner: CorralViewModel.Banner

    var body: some View {
        let color: Color = banner.kind == .success
            ? Theme.Severity.active.color
            : Theme.Severity.stale.color
        HStack(spacing: 8) {
            Image(systemName: banner.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            Text(banner.text).font(.system(size: 11.5))
            Spacer()
            Button {
                model.banner = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(color.opacity(0.10))
    }
}

// ─ Filter bar ───────────────────────────────────────────────────────────────

private struct FilterBar: View {
    @EnvironmentObject private var model: CorralViewModel

    var body: some View {
        HStack(spacing: 6) {
            chip(title: "All", count: model.groups.count, tool: nil)
            ForEach(model.presentTools) { tool in
                chip(title: tool.displayName, count: model.count(of: tool), tool: tool)
            }
            Spacer(minLength: 10)
            StateLegendButton()
            SearchField(text: $model.query, placeholder: "Project, tool, pid…")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
    }

    private func chip(title: String, count: Int, tool: Tool?) -> some View {
        let selected = model.toolFilter == tool
        let color = tool.map(Theme.accent(for:)) ?? Color.primary
        return Button {
            model.toolFilter = selected ? nil : tool
        } label: {
            HStack(spacing: 5) {
                if let tool { Image(systemName: tool.symbol).font(.system(size: 9)) }
                Text(title).font(.system(size: 11, weight: .medium))
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(selected ? color : Theme.faint)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(color.opacity(selected ? 0.15 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(color.opacity(selected ? 0.4 : 0), lineWidth: 1)
            )
            .foregroundStyle(selected ? color : Theme.subtle)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

/// What the coloured dot means, in the app rather than in a README nobody has
/// open. Five states that look similar at a glance need somewhere to be
/// explained, and the honest limits of the detection belong in the same place.
private struct StateLegendButton: View {
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("What the status colours mean")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            StateLegend()
        }
    }
}

private struct StateLegend: View {
    private static let rows: [(AgentState, String)] = [
        (.working, "Using the CPU, or writing to its terminal right now."),
        (.waiting, "Parked, but a build, test run or MCP server it started is busy. Waiting on its own work."),
        (.idle, "Nothing for under an hour. Normal between prompts."),
        (.stale, "Nothing for an hour to a day. Worth a look."),
        (.abandoned, "Nothing for over a day. Almost certainly forgotten."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Agent status")
                .font(.system(size: 12, weight: .semibold))

            VStack(alignment: .leading, spacing: 9) {
                ForEach(Self.rows, id: \.0) { state, description in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(Theme.color(for: state))
                            .frame(width: 7, height: 7)
                            .padding(.top, 4)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(state.label)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.color(for: state))
                            Text(description)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.subtle)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 6) {
                Text("How it is measured")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.faint)
                Text(
                    "Corral watches two things: CPU use, and the last write to the "
                    + "agent's terminal. It cannot see the network, so an agent "
                    + "waiting on a reply from the model is doing neither. CLI agents "
                    + "animate a thinking indicator while they wait, which counts as "
                    + "output — so that gap usually stays green."
                )
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.subtle)
                .fixedSize(horizontal: false, vertical: true)
                Text(
                    "An agent with no controlling terminal has only CPU to go on, and "
                    + "its idle time can only reach back to when Corral opened. Those "
                    + "rows say so when you hover them, and are never bulk-stopped."
                )
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.subtle)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 330)
    }
}

// ─ List ─────────────────────────────────────────────────────────────────────

private struct AgentList: View {
    @EnvironmentObject private var model: CorralViewModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(model.visibleGroups) { group in
                    AgentRow(group: group)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 16)
        }
    }
}

private struct AgentRow: View {
    @EnvironmentObject private var model: CorralViewModel
    let group: AgentGroup
    @State private var hovering = false
    @State private var confirmingStop = false

    /// Always the group's activity, never the root process alone — see
    /// `GroupActivity`.
    private var activity: GroupActivity { model.groupActivity(for: group) }
    private var state: AgentState { activity.state }
    private var stateColor: Color { Theme.color(for: state) }
    private var accent: Color { Theme.accent(for: group.root.tool) }
    private var isExpanded: Bool { model.expanded.contains(group.root.pid) }

    var body: some View {
        VStack(spacing: 0) {
            summary
            if isExpanded {
                Divider().opacity(0.35).padding(.leading, 46)
                DetailPanel(group: group)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                .fill(Theme.rowBackground.opacity(hovering ? 1 : 0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                .strokeBorder(
                    model.selection == group.root.pid ? accent.opacity(0.55) : Theme.hairline,
                    lineWidth: 1
                )
        )
        .overlay(alignment: .leading) {
            // A colour spine: the tool, readable at a glance down the list.
            RoundedRectangle(cornerRadius: 2)
                .fill(accent)
                .frame(width: 3)
                .padding(.vertical, 10)
                .padding(.leading, 1)
        }
        .onHover { hovering = $0 }
        .confirmationDialog(
            "Stop \(model.label(for: group))?",
            isPresented: $confirmingStop,
            titleVisibility: .visible
        ) {
            Button("Quit") { model.stop(group, force: false) }
            Button("Force Quit", role: .destructive) { model.stop(group, force: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(stopMessage)
        }
        .contextMenu {
            Button("Quit") { model.stop(group, force: false) }
            Button("Force Quit") { model.stop(group, force: true) }
            Divider()
            Button("Reveal Project in Finder") { model.revealInFinder(group) }
            Button("Copy Details") { model.copyDetails(group) }
        }
    }

    private var stopMessage: String {
        let childCount = group.children.count
        let children = childCount == 0
            ? ""
            : " and \(childCount) child process\(childCount == 1 ? "" : "es") it started"
        return "This ends the agent\(children), freeing \(group.totalResidentBytes.byteString). "
            + "Quit lets it exit cleanly; Force Quit is immediate and loses anything in flight."
    }

    // ─ Summary line ─────────────────────────────────────────────────────────

    private var summary: some View {
        HStack(spacing: 12) {
            ToolGlyph(
                tool: group.root.tool,
                executablePath: group.root.executablePath,
                terminal: group.root.tty != nil,
                size: 18
            )
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    // The project is the identity. The tool and version are
                    // context — the exact inversion of what Activity Monitor
                    // shows you, which is a version number and nothing else.
                    Text(model.label(for: group))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if group.root.tool.isProjectScoped, group.root.projectName == nil {
                        Pill(text: "no project", color: Theme.faint)
                    }
                    Pill(text: group.root.title, color: accent)
                }
                HStack(spacing: 6) {
                    Text(group.root.displayPath ?? group.root.executablePath ?? "—")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer(minLength: 8)

            metric(group.totalResidentBytes.byteString, "memory")
            metric(group.root.uptime.durationString, "up")
            stateBadge

            // A disclosure *indicator*, not a button. It used to be the only
            // way to open the details, which put an 18-point target next to
            // Stop — the one control in the row you must never hit by mistake.
            // The whole bar opens the details now, so this only has to say
            // that it can be opened.
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .foregroundStyle(Theme.faint.opacity(hovering ? 1 : 0.6))
                .frame(width: 14)
                .animation(.easeInOut(duration: 0.15), value: isExpanded)

            Button {
                confirmingStop = true
            } label: {
                Image(systemName: "stop.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(hovering ? Theme.Severity.abandoned.color : Theme.faint)
                    // A comfortable target, and its own shape so the padding
                    // is clickable rather than just decorative.
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(stopHelp)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            model.selection = group.root.pid
            model.toggleExpanded(group.root.pid)
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isExpanded ? "Hide details" : "Show child processes and paths")
    }

    private var stopHelp: String {
        let count = group.children.count
        guard count > 0 else { return "Stop this agent" }
        return "Stop this agent and the \(count) process\(count == 1 ? "" : "es") "
            + "it started"
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
            Text(label.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.faint)
        }
        .frame(minWidth: 52, alignment: .trailing)
    }

    private var stateBadge: some View {
        VStack(alignment: .trailing, spacing: 1) {
            HStack(spacing: 4) {
                Circle().fill(stateColor).frame(width: 6, height: 6)
                Text(badgeValue)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(stateColor)
            }
            Text(badgeLabel)
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.faint)
        }
        .frame(minWidth: 66, alignment: .trailing)
        .help(stateHelp)
    }

    private var badgeValue: String {
        switch state {
        case .starting:
            return "—"
        case .working:
            // A percentage only when there is one worth printing; an agent
            // streaming a reply spends almost no CPU doing it, and "0%" next
            // to "working" reads as a contradiction.
            return activity.root.cpuLoad >= AgentInventory.idleThreshold
                ? String(format: "%.0f%%", activity.root.cpuLoad * 100)
                : "now"
        case .waiting:
            return String(format: "%.0f%%", (activity.busiestChild?.load ?? 0) * 100)
        case .idle, .stale, .abandoned:
            return activity.idleFor?.durationString ?? "—"
        }
    }

    /// For a waiting group the label names *what* it is waiting on, which is
    /// the useful half: "dev server" and "tooling" call for different reactions.
    private var badgeLabel: String {
        switch state {
        case .working:
            return activity.root.cpuLoad >= AgentInventory.idleThreshold ? "cpu" : "working"
        case .waiting:
            return activity.busiestChild?.role.label ?? "waiting"
        default:
            return state.label
        }
    }

    /// The whole explanation, in the place someone will look for it. Provenance
    /// is part of it: an idle time measured from the terminal is real history,
    /// one measured from Corral's own uptime is not.
    private var stateHelp: String {
        switch state {
        case .starting:
            return "Just appeared — Corral needs a second sample before it can "
                + "say whether this is working or parked."
        case .working:
            if activity.root.cpuLoad >= AgentInventory.idleThreshold {
                return "Using \(String(format: "%.0f%%", activity.root.cpuLoad * 100)) "
                    + "of one core right now."
            }
            return "Writing to \(group.root.tty ?? "its terminal") right now — "
                + "streaming a reply, or animating its thinking indicator."
        case .waiting:
            let role = activity.busiestChild?.role.label ?? "a child process"
            return "The agent itself is parked, but the \(role) it started is "
                + "using the CPU. It is waiting on its own work, not idle."
        case .idle, .stale, .abandoned:
            let where_ = group.root.tty ?? "its terminal"
            let provenance = activity.idleIsMeasuredFromTerminal
                ? "No output to \(where_) for this long — measured from the "
                    + "terminal, so it counts time before Corral was open."
                : "Quiet since Corral started watching. It may have been idle "
                    + "far longer; with no controlling terminal there is no "
                    + "earlier evidence to read."
            let advice = state == .abandoned
                ? " Over a day — almost certainly forgotten."
                : (state == .stale ? " Worth a look." : "")
            return provenance + advice
        }
    }
}

// ─ Detail panel ─────────────────────────────────────────────────────────────

private struct DetailPanel: View {
    @EnvironmentObject private var model: CorralViewModel
    let group: AgentGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 26) {
                field("PID", "\(group.root.pid)")
                field("Parent", "\(group.root.ppid)")
                if let tty = group.root.tty { field("Terminal", tty) }
                field("CPU time", group.root.cpuSeconds.cpuTimeString)
                field("Started", group.root.startedAt.formatted(date: .abbreviated, time: .shortened))
            }

            if let path = group.root.executablePath {
                field("Executable", path, monospaced: true)
            }
            if !group.root.arguments.isEmpty {
                field("Command", group.root.arguments.joined(separator: " "), monospaced: true)
            }

            if !group.children.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("CHILD PROCESSES (\(group.children.count))")
                        .font(.system(size: 8.5, weight: .semibold))
                        .tracking(0.7)
                        .foregroundStyle(Theme.faint)
                    ForEach(group.children) { child in
                        ChildRow(child: child)
                    }
                }
                .padding(.top, 2)
            }

            HStack(spacing: 8) {
                Button("Reveal Project") { model.revealInFinder(group) }
                    .disabled(group.root.workingDirectory == nil)
                Button("Copy Details") { model.copyDetails(group) }
                Spacer()
            }
            .font(.system(size: 11))
            .buttonStyle(.bordered)
            .padding(.top, 2)
        }
        .padding(.horizontal, 46)
        .padding(.vertical, 12)
    }

    private func field(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(Theme.faint)
            Text(value)
                .font(.system(size: 11, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}

private struct ChildRow: View {
    let child: AgentProcess

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: child.role.symbol)
                .font(.system(size: 9))
                .foregroundStyle(Theme.faint)
                .frame(width: 14)
            Text(child.comm)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            Pill(text: child.role.label, color: roleColor)
            Text("pid \(child.pid)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.faint)
            Spacer()
            Text(child.residentBytes.byteString)
                .font(.system(size: 10.5, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.subtle)
        }
    }

    private var roleColor: Color {
        switch child.role {
        case .mcpServer: return Theme.accent(for: .codex)
        case .powerAssertion: return Theme.Severity.stale.color
        default: return Theme.faint
        }
    }
}

// ─ Empty state ──────────────────────────────────────────────────────────────

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.Severity.active.color)
            Text("Nothing running")
                .font(.system(size: 15, weight: .medium))
            Text("No Claude, Codex or Cursor processes are using your machine.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.faint)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
