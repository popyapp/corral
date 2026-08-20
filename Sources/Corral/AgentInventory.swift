import Darwin
import Foundation

/// Builds the picture the app shows: which agents are running, what each one
/// spawned, and how busy it has been.
///
/// Kept free of SwiftUI so the CLI and the MCP server can use exactly the same
/// numbers the window shows.
final class AgentInventory {

    /// A process is called idle when it has used less than this fraction of one
    /// core since the previous sample. An agent waiting for you to type still
    /// ticks over slightly; 0.5% is comfortably above that noise and far below
    /// anything actually working.
    static let idleThreshold = 0.005

    private struct Sample {
        let cpuSeconds: Double
        let takenAt: Date
    }

    private var previous: [pid_t: Sample] = [:]
    private var idleSince: [pid_t: Date] = [:]

    private(set) var groups: [AgentGroup] = []
    private(set) var activity: [pid_t: Activity] = [:]
    private(set) var lastRefresh: Date?

    // ─ Refresh ──────────────────────────────────────────────────────────────

    @discardableResult
    func refresh() -> [AgentGroup] {
        let raws = ProcessScanner.scan()
        let now = Date()

        // Pass 1 — recognise agents.
        var matches: [pid_t: ToolCatalog.Match] = [:]
        var byPid: [pid_t: ProcessScanner.Raw] = [:]
        for raw in raws {
            byPid[raw.pid] = raw
            if let match = ToolCatalog.identify(raw) {
                matches[raw.pid] = match
            }
        }

        // Pass 2 — adopt descendants of an agent, however deep. An agent starts
        // an MCP server which starts a node process; all of it is that agent's
        // footprint and all of it dies when you kill the group.
        var childrenOf: [pid_t: [pid_t]] = [:]
        for raw in raws where raw.ppid > 0 {
            childrenOf[raw.ppid, default: []].append(raw.pid)
        }

        var roots: [pid_t] = matches.compactMap { pid, match in
            match.role == .agent ? pid : nil
        }
        // Electron helpers are matched directly but belong under their app.
        for (pid, match) in matches where match.role != .agent {
            let hasRecognisedAncestor = ancestors(of: pid, in: byPid)
                .contains { matches[$0]?.role == .agent }
            if !hasRecognisedAncestor { roots.append(pid) }
            _ = match
        }

        var built: [AgentGroup] = []
        var claimed = Set<pid_t>()

        for pid in roots.sorted() {
            guard let raw = byPid[pid], let match = matches[pid], !claimed.contains(pid) else {
                continue
            }
            claimed.insert(pid)

            let root = makeProcess(raw, tool: match.tool, role: match.role, version: match.version)

            var children: [AgentProcess] = []
            for descendant in descendants(of: pid, in: childrenOf) where !claimed.contains(descendant) {
                guard let childRaw = byPid[descendant] else { continue }
                claimed.insert(descendant)
                // A descendant that is itself a recognised agent (an agent you
                // launched from another agent's shell) keeps its own identity.
                let childMatch = matches[descendant]
                children.append(
                    makeProcess(
                        childRaw,
                        tool: childMatch?.tool ?? match.tool,
                        role: childMatch?.role
                            ?? ToolCatalog.classifyChild(childRaw, parent: match.tool),
                        version: childMatch?.version
                    )
                )
            }
            built.append(AgentGroup(root: root, children: children.sorted { $0.pid < $1.pid }))
        }

        updateActivity(for: built, at: now)
        groups = built.sorted {
            // Longest-running first: the thing you forgot about is the thing
            // you came here to find.
            $0.root.startedAt < $1.root.startedAt
        }
        lastRefresh = now
        return groups
    }

    private func makeProcess(
        _ raw: ProcessScanner.Raw,
        tool: Tool,
        role: ProcessRole,
        version: String?
    ) -> AgentProcess {
        AgentProcess(
            pid: raw.pid,
            ppid: raw.ppid,
            tool: tool,
            role: role,
            comm: raw.comm,
            executablePath: raw.executablePath,
            arguments: raw.arguments,
            workingDirectory: raw.workingDirectory,
            residentBytes: raw.residentBytes,
            cpuSeconds: raw.cpuSeconds,
            startedAt: raw.startedAt,
            version: version,
            tty: raw.tty,
            lastTerminalActivity: raw.lastTerminalActivity
        )
    }

    // ─ Tree helpers ─────────────────────────────────────────────────────────

    private func ancestors(of pid: pid_t, in byPid: [pid_t: ProcessScanner.Raw]) -> [pid_t] {
        var result: [pid_t] = []
        var current = byPid[pid]?.ppid ?? 0
        // launchd is pid 1 and every chain ends there; the bound also stops a
        // corrupt table from spinning us forever.
        var hops = 0
        while current > 1, hops < 64 {
            result.append(current)
            current = byPid[current]?.ppid ?? 0
            hops += 1
        }
        return result
    }

    private func descendants(of pid: pid_t, in childrenOf: [pid_t: [pid_t]]) -> [pid_t] {
        var result: [pid_t] = []
        var queue = childrenOf[pid] ?? []
        var seen = Set<pid_t>()
        while let next = queue.popLast() {
            guard seen.insert(next).inserted else { continue }
            result.append(next)
            queue.append(contentsOf: childrenOf[next] ?? [])
        }
        return result
    }

    // ─ Idle detection ───────────────────────────────────────────────────────

    private func updateActivity(for groups: [AgentGroup], at now: Date) {
        var next: [pid_t: Sample] = [:]
        var computed: [pid_t: Activity] = [:]

        for process in groups.flatMap(\.all) {
            let sample = Sample(cpuSeconds: process.cpuSeconds, takenAt: now)
            next[process.pid] = sample

            guard let old = previous[process.pid] else {
                // First sighting: we have nothing to compare against, so we say
                // so rather than guessing. A freshly-seen process is not idle.
                computed[process.pid] = Activity(
                    cpuLoad: 0, quietSince: nil,
                    lastTerminalActivity: process.lastTerminalActivity
                )
                continue
            }

            let elapsed = now.timeIntervalSince(old.takenAt)
            guard elapsed > 0.1 else {
                computed[process.pid] = activity[process.pid]
                    ?? Activity(
                        cpuLoad: 0, quietSince: nil,
                        lastTerminalActivity: process.lastTerminalActivity
                    )
                next[process.pid] = old   // keep the older baseline
                continue
            }

            let load = max(0, (process.cpuSeconds - old.cpuSeconds) / elapsed)
            if load < Self.idleThreshold {
                // Idle now — keep the timestamp from when it first went quiet.
                let since = idleSince[process.pid] ?? old.takenAt
                idleSince[process.pid] = since
                computed[process.pid] = Activity(
                    cpuLoad: load, quietSince: since,
                    lastTerminalActivity: process.lastTerminalActivity
                )
            } else {
                idleSince[process.pid] = nil
                computed[process.pid] = Activity(
                    cpuLoad: load, quietSince: nil,
                    lastTerminalActivity: process.lastTerminalActivity
                )
            }
        }

        // Forget processes that have exited, so a recycled pid starts clean.
        let live = Set(next.keys)
        previous = next
        idleSince = idleSince.filter { live.contains($0.key) }
        activity = computed
    }

    func activity(for pid: pid_t) -> Activity {
        activity[pid] ?? Activity(cpuLoad: 0, quietSince: nil, lastTerminalActivity: nil)
    }

    // ─ Totals ───────────────────────────────────────────────────────────────

    struct Totals {
        let agents: Int
        let processes: Int
        let residentBytes: UInt64
        let projects: Int
        let idleAgents: Int
        let oldest: TimeInterval
    }

    var totals: Totals {
        let all = groups.flatMap(\.all)
        let projects = Set(groups.compactMap { $0.root.workingDirectory }.filter { $0 != "/" })
        return Totals(
            agents: groups.count,
            processes: all.count,
            residentBytes: all.reduce(0) { $0 + $1.residentBytes },
            projects: projects.count,
            idleAgents: groups.filter { activity(for: $0.root.pid).isIdle }.count,
            oldest: groups.map(\.root.uptime).max() ?? 0
        )
    }
}
