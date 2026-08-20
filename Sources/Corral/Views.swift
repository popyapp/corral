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
                AgentList()
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

            Stat(value: "\(model.totals.agents)", label: "agents")
            Stat(value: model.totals.residentBytes.byteString, label: "memory")
            Stat(value: "\(model.totals.projects)", label: "projects")
            if model.totals.oldest > 0 {
                Stat(value: model.totals.oldest.durationString, label: "oldest")
            }

            Spacer(minLength: 8)

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
                .help("Stop the \(model.staleGroups.count) agents that have been idle over an hour")
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
            Spacer()
            if let last = model.lastRefresh {
                Text("updated \(Date().timeIntervalSince(last) < 3 ? "just now" : "\(Int(Date().timeIntervalSince(last)))s ago")")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
            }
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

    private var activity: Activity { model.activity(for: group.root.pid) }
    private var severity: Theme.Severity { .of(activity) }
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
        .onTapGesture { model.selection = group.root.pid }
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
            Image(systemName: group.root.tool.symbol)
                .font(.system(size: 14))
                .foregroundStyle(accent)
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
            idleBadge

            Button {
                model.toggleExpanded(group.root.pid)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(Theme.faint)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide details" : "Show child processes and paths")

            Button {
                confirmingStop = true
            } label: {
                Image(systemName: "stop.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(hovering ? Theme.Severity.abandoned.color : Theme.faint)
            }
            .buttonStyle(.plain)
            .help("Stop this agent and its children")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
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

    private var idleBadge: some View {
        VStack(alignment: .trailing, spacing: 1) {
            HStack(spacing: 4) {
                Circle().fill(severity.color).frame(width: 6, height: 6)
                Text(idleValue)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(severity.color)
            }
            Text(idleLabel)
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.faint)
        }
        .frame(minWidth: 62, alignment: .trailing)
        .help(idleHelp)
    }

    private var idleValue: String {
        guard let idle = activity.idleFor else {
            return String(format: "%.0f%%", activity.cpuLoad * 100)
        }
        return idle.durationString
    }

    private var idleLabel: String {
        activity.idleFor == nil ? "cpu" : severity.label
    }

    /// Being explicit about provenance matters: an idle time measured from the
    /// terminal is real history, one measured from our own uptime is not.
    private var idleHelp: String {
        guard activity.idleFor != nil else { return "Currently using CPU" }
        if activity.idleIsMeasuredFromTerminal {
            return "No output to \(group.root.tty ?? "its terminal") for this long"
        }
        return "Quiet since Corral started watching — it may have been idle far longer"
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
