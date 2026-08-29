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
    @Published var query: String = ""
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var trends = Trends()
    /// How far back the header graph looks. Clicking it cycles the range.
    @Published var trendRange: TrendRange = .hour
    /// Which figure the header graph plots. Clicking a number selects it.
    @Published var trendMetric: TrendMetric = .cpu

    /// How the list is ordered. Remembered between launches — a sort you have
    /// to set again every morning is worse than no sort at all.
    @Published var sort: AgentSort = .uptime {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: Self.sortKey) }
    }
    @Published var sortReversed = false {
        didSet { UserDefaults.standard.set(sortReversed, forKey: Self.reversedKey) }
    }

    private static let sortKey = "agentSort"
    private static let reversedKey = "agentSortReversed"
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
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Self.sortKey),
           let restored = AgentSort(rawValue: raw) {
            sort = restored
        }
        sortReversed = defaults.bool(forKey: Self.reversedKey)
        refresh()
        // Two seconds is fast enough that the numbers feel live and slow
        // enough that scanning ~500 processes costs nothing noticeable.
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { timer?.invalidate() }

    #if DEBUG
    /// Test seam: a fixed set of groups, no process scan and no refresh timer.
    ///
    /// The designated initialiser scans the machine and starts a 2-second
    /// timer, which makes ordering untestable — the answer would depend on
    /// whatever happened to be running.
    init(groupsForTesting groups: [AgentGroup], sort: AgentSort = .uptime) {
        self.groups = groups
        self.sort = sort
        self.sortReversed = false
    }
    #endif

    // ─ Data ─────────────────────────────────────────────────────────────────

    func refresh() {
        inventory.refresh()
        groups = inventory.groups
        totals = inventory.totals
        runningVersions = Set(groups.compactMap { $0.root.version })
        lastRefresh = inventory.lastRefresh
        recordTrends()
        if let selection, !groups.contains(where: { $0.root.pid == selection }) {
            self.selection = nil
        }
    }

    /// One sample per refresh into each header series.
    ///
    /// CPU is summed across every process in every group, so the number is
    /// "cores these agents are using", not a share of the machine — two agents
    /// compiling flat out read as 2.0, which is the honest figure and the one
    /// that explains a hot fan.
    private func recordTrends() {
        let now = Date()
        let load = groups.flatMap(\.all).reduce(0.0) { $0 + activity(for: $1.pid).cpuLoad }
        trends.cpu.record(load, at: now)
        trends.memory.record(Double(totals.residentBytes), at: now)
        trends.agents.record(Double(totals.agents), at: now)
        trends.projects.record(Double(totals.projects), at: now)
    }

    func cycleTrendRange() { trendRange = trendRange.next }

    func activity(for pid: pid_t) -> Activity { inventory.activity(for: pid) }

    /// What a row should show. Always prefer this over `activity(for:)`: the
    /// root process alone cannot tell a parked agent from one waiting on the
    /// build it started.
    /// What the agent last said or did, from the session log the tool keeps.
    func sessionActivity(for group: AgentGroup) -> SessionActivity? {
        inventory.sessionActivity(for: group)
    }

    /// How full this agent's conversation is.
    func sessionContext(for group: AgentGroup) -> ContextUse? {
        inventory.sessionContext(for: group)
    }

    /// What each account has left, as of the last time that tool wrote it down.
    var accountUsages: [ToolUsage] { inventory.accountUsages }

    /// Everything Corral knows about one vendor, gathered for the rail.
    ///
    /// Grouped by vendor rather than by tool because the account is the vendor's:
    /// Claude Code and the Claude desktop app spend the same allowance, and two
    /// rings for one budget would be two rings saying the same number.
    var vendorUsages: [VendorUsage] {
        let accounts = Dictionary(
            accountUsages.map { ($0.tool.vendor, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var sessions: [String: [(group: AgentGroup, use: ContextUse)]] = [:]
        for row in contexts {
            sessions[row.group.root.tool.vendor, default: []].append(row)
        }

        // Every vendor that is either running something or has an allowance we
        // can read. A vendor doing neither has nothing to put in a ring.
        var order: [String] = []
        var representative: [String: Tool] = [:]
        for group in groups {
            let vendor = group.root.tool.vendor
            if representative[vendor] == nil {
                representative[vendor] = group.root.tool
                order.append(vendor)
            }
        }
        for usage in accountUsages where representative[usage.tool.vendor] == nil {
            representative[usage.tool.vendor] = usage.tool
            order.append(usage.tool.vendor)
        }

        return order.compactMap { vendor in
            guard let tool = representative[vendor] else { return nil }
            let usage = VendorUsage(
                tool: tool,
                account: accounts[vendor],
                sessions: sessions[vendor] ?? []
            )
            // A vendor with neither a limit nor a measurable conversation would
            // be an empty ring, which reads as "nothing used" rather than
            // "nothing known".
            return usage.hasSomethingToShow ? usage : nil
        }
    }

    /// The single fullest thing Corral is tracking, whatever kind it is.
    ///
    /// The collapsed panel shows one line, and this is it. Allowances and
    /// context windows are compared against each other on purpose: they are
    /// different problems, but "what is closest to running out" has one answer
    /// and it is the only thing worth a permanent strip on someone's screen.
    /// Which of the two it turned out to be is what opening the panel is for.
    var fullest: (fraction: Double, label: String, tool: Tool)? {
        var best: (fraction: Double, label: String, tool: Tool)?

        func offer(_ fraction: Double, _ label: String, _ tool: Tool) {
            guard best == nil || fraction > best!.fraction else { return }
            best = (fraction, label, tool)
        }

        for usage in accountUsages {
            for limit in usage.limits {
                offer(limit.usedFraction, "\(usage.tool.displayName) \(limit.label)", usage.tool)
            }
        }
        for row in contexts {
            offer(
                row.use.fraction,
                row.group.root.projectName ?? row.group.root.tool.displayName,
                row.group.root.tool
            )
        }
        return best
    }

    /// Agents whose context we can report, fullest first.
    ///
    /// Fullest first because that is the one about to need something done about
    /// it, and because a panel you glance at should put the answer at the top.
    var contexts: [(group: AgentGroup, use: ContextUse)] {
        groups
            .compactMap { group in
                sessionContext(for: group).map { (group: group, use: $0) }
            }
            .sorted { $0.use.fraction > $1.use.fraction }
    }

    func groupActivity(for group: AgentGroup) -> GroupActivity {
        inventory.groupActivity(for: group)
    }

    var visibleGroups: [AgentGroup] {
        var result = groups
        if let toolFilter { result = result.filter { $0.root.tool == toolFilter } }

        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty { result = result.filter { matches($0, needle) } }
        return ordered(result)
    }

    /// The list re-sorts every two seconds, so ties must break the same way
    /// every time. Swift's sort is not stable, and without the pid tiebreak two
    /// agents with equal memory — or the many that sit at 0% CPU — would swap
    /// places on every refresh and the whole list would flicker.
    private func ordered(_ groups: [AgentGroup]) -> [AgentGroup] {
        let result = groups.sorted { a, b in
            switch sort {
            case .uptime:
                if a.root.startedAt != b.root.startedAt {
                    return a.root.startedAt < b.root.startedAt
                }
            case .memory:
                if a.totalResidentBytes != b.totalResidentBytes {
                    return a.totalResidentBytes > b.totalResidentBytes
                }
            case .cpu:
                let (left, right) = (load(of: a), load(of: b))
                if left != right { return left > right }
            case .project:
                let comparison = label(for: a)
                    .localizedCaseInsensitiveCompare(label(for: b))
                if comparison != .orderedSame { return comparison == .orderedAscending }
            }
            return a.root.pid < b.root.pid
        }
        return sortReversed ? result.reversed() : result
    }

    /// A group's CPU is the whole tree's: an agent parked while its build burns
    /// a core is a busy row, and sorting by CPU should surface it.
    func load(of group: AgentGroup) -> Double {
        group.all.reduce(0.0) { $0 + activity(for: $1.pid).cpuLoad }
    }

    /// Picking the order already in use reverses it.
    func apply(sort option: AgentSort) {
        if sort == option {
            sortReversed.toggle()
        } else {
            sort = option
            sortReversed = false
        }
    }

    /// Search across everything that identifies an agent — the project name and
    /// its full path, the tool, the version, the pid, and the names of what it
    /// spawned. Typing "3000" should find the agent whose dev server you are
    /// looking for just as well as typing "api".
    private func matches(_ group: AgentGroup, _ needle: String) -> Bool {
        let root = group.root
        var haystacks: [String] = [
            root.tool.displayName,
            root.tool.vendor,
            "\(root.pid)",
            root.comm,
        ]
        if let project = root.projectName { haystacks.append(project) }
        if let path = root.workingDirectory { haystacks.append(path) }
        if let version = root.version { haystacks.append(version) }
        if let exec = root.executablePath { haystacks.append(exec) }
        if let tty = root.tty { haystacks.append(tty) }
        haystacks.append(root.arguments.joined(separator: " "))

        for child in group.children {
            haystacks.append(child.comm)
            haystacks.append(child.role.label)
            haystacks.append(child.arguments.joined(separator: " "))
        }
        return haystacks.contains { $0.lowercased().contains(needle) }
    }

    /// True when a search is on but hid everything — worth saying so rather
    /// than showing an empty pane that looks like nothing is running.
    var searchHidEverything: Bool {
        !groups.isEmpty && visibleGroups.isEmpty
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
    ///
    /// A group whose child is mid-compile is excluded even when the agent's own
    /// terminal has been silent for hours: a long build produces no output, and
    /// bulk-stopping it would throw away the work it is waiting for.
    var staleGroups: [AgentGroup] {
        groups.filter { group in
            let activity = groupActivity(for: group)
            guard !activity.state.isBusy else { return false }
            guard let idle = activity.idleFor else { return false }
            return activity.idleIsMeasuredFromTerminal && idle >= Self.staleThreshold
        }
    }

    var reclaimableBytes: UInt64 {
        staleGroups.reduce(0) { $0 + $1.totalResidentBytes }
    }

    func group(withPid pid: pid_t) -> AgentGroup? {
        groups.first { $0.root.pid == pid }
    }

    var selectedGroup: AgentGroup? { selection.flatMap(group(withPid:)) }

    /// Version strings currently executing. The disk side uses this so a
    /// version in use is never offered for deletion, however old its number.
    @Published private(set) var runningVersions: Set<String> = []

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
