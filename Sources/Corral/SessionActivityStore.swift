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
    private var contexts: [pid_t: ContextUse] = [:]
    private var computedAt: Date = .distantPast

    init(
        readers: [Tool: SessionActivityReader] = [
            .claudeCode: ClaudeSessionActivityReader(),
            .codex: CodexSessionActivityReader(),
            // The CLI agent and the editor keep their conversations in
            // different places; the agent Corral lists from a terminal is the
            // CLI one.
            .cursorAgent: CursorCLISessionActivityReader(),
            .cursor: CursorSessionActivityReader(),
            // One reader for two roots: a `kiro-cli` you typed, and the
            // engines Kiro Crew starts for its own sessions, which Corral lists
            // under the Crew app. Both write the same session files, and the
            // lock in each names a pid the group already contains.
            .kiroCLI: KiroSessionActivityReader(),
            .kiroCrew: KiroSessionActivityReader(),
            .antigravity: AntigravitySessionActivityReader(),
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
        var nextContexts: [pid_t: ContextUse] = [:]

        // Most recently active first. When two agents in a project both fit a
        // log, the one that has just been typing at is the better guess for the
        // one that has just been written to.
        let ordered = groups.sorted {
            ($0.root.lastTerminalActivity ?? $0.root.startedAt)
                > ($1.root.lastTerminalActivity ?? $1.root.startedAt)
        }

        for group in ordered {
            // A group whose root is a helper — a background service, an
            // updater that outlived its app — is not running a conversation,
            // and a reader that matches by app rather than by project would
            // otherwise hand the app's conversation to the wrong row.
            guard group.root.role == .agent, let reader = readers[group.root.tool] else { continue }
            // `/` is where a desktop app sits, and it names no project. The
            // readers that need one say nothing; the ones that match by pid
            // do not need it.
            let project = group.root.workingDirectory.flatMap { $0 == "/" ? nil : $0 }

            let reading = reader.reading(
                SessionLookup(
                    project: project,
                    startedAt: group.root.startedAt,
                    sessionId: sessionId(group),
                    claimed: claimed,
                    pids: Set(group.all.map(\.pid))
                )
            )
            guard let reading else { continue }
            claimed.insert(reading.source)
            next[group.root.pid] = reading.activity
            nextContexts[group.root.pid] = reading.context
        }

        current = next
        contexts = nextContexts
    }

    func activity(for pid: pid_t) -> SessionActivity? { current[pid] }

    /// How full this agent's context window is, when its log said.
    ///
    /// Keyed by the same claim as the activity line, so an agent that could not
    /// be told apart from its neighbour has no context either — the alternative
    /// is putting a confident percentage against the wrong conversation.
    func context(for pid: pid_t) -> ContextUse? { contexts[pid] }
}
