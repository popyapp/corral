import Combine
import Foundation
import SwiftUI

@MainActor
final class CorralViewModel: ObservableObject {

    @Published private(set) var groups: [AgentGroup] = []
    @Published private(set) var totals = AgentInventory.Totals(
        agents: 0, processes: 0, residentBytes: 0,
        projects: 0, idleAgents: 0, oldest: 0
    )
    @Published var selection: pid_t?
    @Published var expanded: Set<pid_t> = []
    @Published var toolFilter: Tool?
    @Published private(set) var lastRefresh: Date?
    @Published var banner: Banner?

    struct Banner: Identifiable, Equatable {
        enum Kind { case success, warning }
        let id = UUID()
        let kind: Kind
        let text: String
    }

    /// How long an agent must have been idle before Corral suggests stopping
    /// it. An hour is long enough that you have clearly moved on, and short
    /// enough to catch a morning's worth of abandoned sessions.
    static let staleThreshold: TimeInterval = 3_600

    private let inventory = AgentInventory()
    private var timer: Timer?

    init() {
        refresh()
        // Two seconds is fast enough that the numbers feel live and slow
        // enough that scanning ~500 processes costs nothing noticeable.
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { timer?.invalidate() }

    // ─ Data ─────────────────────────────────────────────────────────────────

    func refresh() {
        inventory.refresh()
        groups = inventory.groups
        totals = inventory.totals
        lastRefresh = inventory.lastRefresh
        if let selection, !groups.contains(where: { $0.root.pid == selection }) {
            self.selection = nil
        }
    }

    func activity(for pid: pid_t) -> Activity { inventory.activity(for: pid) }

    var visibleGroups: [AgentGroup] {
        guard let toolFilter else { return groups }
        return groups.filter { $0.root.tool == toolFilter }
    }

    /// Tools actually present right now, for the filter bar. Showing a filter
    /// for a tool that isn't installed is just noise.
    var presentTools: [Tool] {
        let counts = Dictionary(grouping: groups, by: { $0.root.tool })
        return Tool.allCases.filter { counts[$0]?.isEmpty == false }
    }

    func count(of tool: Tool) -> Int {
        groups.filter { $0.root.tool == tool }.count
    }

    /// Agents idle for longer than the threshold — the ones worth reclaiming.
    var staleGroups: [AgentGroup] {
        groups.filter { group in
            guard let idle = activity(for: group.root.pid).idleFor else { return false }
            return activity(for: group.root.pid).idleIsMeasuredFromTerminal
                && idle >= Self.staleThreshold
        }
    }

    var reclaimableBytes: UInt64 {
        staleGroups.reduce(0) { $0 + $1.totalResidentBytes }
    }

    func group(withPid pid: pid_t) -> AgentGroup? {
        groups.first { $0.root.pid == pid }
    }

    var selectedGroup: AgentGroup? { selection.flatMap(group(withPid:)) }

    // ─ Actions ──────────────────────────────────────────────────────────────

    func stop(_ group: AgentGroup, force: Bool) {
        let outcome = Terminator.stop(group, method: force ? .force : .graceful)
        report(outcome, subject: label(for: group))
        refresh()
    }

    func stopAllStale(force: Bool) {
        let targets = staleGroups
        guard !targets.isEmpty else { return }
        var stopped = 0
        var survived = 0
        var bytes: UInt64 = 0
        for group in targets {
            let outcome = Terminator.stop(group, method: force ? .force : .graceful)
            stopped += outcome.stopped.count
            survived += outcome.survived.count + outcome.refused.count
            bytes += outcome.reclaimedBytes
        }
        banner = Banner(
            kind: survived == 0 ? .success : .warning,
            text: survived == 0
                ? "Stopped \(targets.count) idle agents · \(bytes.byteString) reclaimed"
                : "Stopped \(stopped) processes · \(survived) ignored the request — try Force Quit"
        )
        refresh()
    }

    private func report(_ outcome: Terminator.Outcome, subject: String) {
        if outcome.isCompleteSuccess {
            banner = Banner(
                kind: .success,
                text: "Stopped \(subject) · \(outcome.reclaimedBytes.byteString) reclaimed"
            )
        } else if !outcome.survived.isEmpty {
            banner = Banner(
                kind: .warning,
                text: "\(outcome.survived.count) process(es) ignored the quit request — Force Quit will end them"
            )
        } else {
            banner = Banner(kind: .warning, text: "Could not stop \(subject)")
        }
    }

    func label(for group: AgentGroup) -> String {
        if let project = group.root.projectName { return project }
        return group.root.tool.displayName
    }

    func revealInFinder(_ group: AgentGroup) {
        guard let path = group.root.workingDirectory else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    func copyDetails(_ group: AgentGroup) {
        let root = group.root
        var lines = [
            "\(root.title)  pid \(root.pid)  ppid \(root.ppid)",
            "cwd:  \(root.workingDirectory ?? "—")",
            "exec: \(root.executablePath ?? "—")",
            "args: \(root.arguments.joined(separator: " "))",
        ]
        if let tty = root.tty { lines.append("tty:  \(tty)") }
        for child in group.children {
            lines.append("  └ \(child.comm) (\(child.role.label)) pid \(child.pid)")
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
        banner = Banner(kind: .success, text: "Copied details for \(label(for: group))")
    }

    func toggleExpanded(_ pid: pid_t) {
        if expanded.contains(pid) { expanded.remove(pid) } else { expanded.insert(pid) }
    }
}

#if canImport(AppKit)
import AppKit
#endif
