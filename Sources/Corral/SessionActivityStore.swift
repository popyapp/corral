import Foundation

/// Works out what every listed agent is doing, in one pass over all of them.
///
/// One pass rather than one lookup per row, because the interesting case is two
/// agents in the same project. Nothing in any of these logs records a pid, so
/// asked separately both agents match the same file and the list confidently
/// says the idle one is doing what the busy one is doing. Answering together
/// lets a log be claimed once: the agent that was active most recently gets
/// first pick, and an agent left with nothing says nothing, which is the honest
/// outcome when we cannot tell.
///
/// A tool with no reader — Claude Desktop, Windsurf, the Cursor editor's
/// helpers — simply has nothing to say. That is not an error.
final class SessionActivityStore {

    private let readers: [Tool: SessionActivityReader]
    private let ttl: TimeInterval
    private var current: [pid_t: SessionActivity] = [:]
    private var computedAt: Date = .distantPast

    init(
        readers: [Tool: SessionActivityReader] = [
            .claudeCode: ClaudeSessionActivityReader(),
            .codex: CodexSessionActivityReader(),
            .cursorAgent: CursorSessionActivityReader(),
        ],
        ttl: TimeInterval = 3
    ) {
        self.readers = readers
        self.ttl = ttl
    }

    /// Recompute the whole assignment. The inventory refreshes every two
    /// seconds and this opens files, so it holds its answer briefly — none of
    /// it changes faster than a person can read a line.
    func refresh(
        _ groups: [AgentGroup],
        sessionId: (AgentGroup) -> String?,
        now: Date = Date()
    ) {
        guard now.timeIntervalSince(computedAt) >= ttl else { return }
        computedAt = now

        var claimed = Set<String>()
        var next: [pid_t: SessionActivity] = [:]

        // Most recently active first. When two agents in a project both fit a
        // log, the one that has just been typing at is the better guess for the
        // one that has just been written to.
        let ordered = groups.sorted {
            ($0.root.lastTerminalActivity ?? $0.root.startedAt)
                > ($1.root.lastTerminalActivity ?? $1.root.startedAt)
        }

        for group in ordered {
            guard let reader = readers[group.root.tool],
                  let project = group.root.workingDirectory, project != "/"
            else { continue }

            let reading = reader.reading(
                SessionLookup(
                    project: project,
                    startedAt: group.root.startedAt,
                    sessionId: sessionId(group),
                    claimed: claimed
                )
            )
            guard let reading else { continue }
            claimed.insert(reading.source)
            next[group.root.pid] = reading.activity
        }

        current = next
    }

    func activity(for pid: pid_t) -> SessionActivity? { current[pid] }
}
