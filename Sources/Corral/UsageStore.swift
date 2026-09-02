import Foundation

/// Keeps each tool's account usage, on a much slower clock than the list.
///
/// Separate from `SessionActivityStore` because the two answer questions at
/// different scopes and move at different speeds. An activity line describes
/// one process and changes every few seconds; an account limit describes every
/// session of that tool on every machine, and only moves when one of them takes
/// a turn. Polling it at the list's refresh rate would re-read the same file
/// thirty times a minute to watch a number that changes on the hour.
///
/// Nothing here reaches the network. Every figure is one a tool already wrote
/// down on this machine, which is also why every figure arrives with the date
/// the tool wrote it.
final class UsageStore {

    private let readers: [UsageReader]
    private let ttl: TimeInterval
    private var current: [Tool: ToolUsage] = [:]
    private var computedAt: Date = .distantPast

    /// Codex reports its limits into its own logs unasked. Claude Code does
    /// not record them anywhere — but it hands them to a status line command,
    /// so `StatusSnapshotReader` reads back what `Corral --statusline` was told.
    /// That one has nothing to say until the user turns it on; see
    /// `StatusLineSetup`.
    ///
    /// Cursor is absent, and not by oversight: it publishes what an account has
    /// left to no file on this machine and not to its status line either. Its
    /// context still shows per agent, which is a different question with a real
    /// local answer.
    init(
        readers: [UsageReader] = [
            CodexUsageReader(),
            StatusSnapshotReader(tool: .claudeCode),
        ],
        ttl: TimeInterval = 60
    ) {
        self.readers = readers
        self.ttl = ttl
    }

    func refresh(now: Date = Date()) {
        guard now.timeIntervalSince(computedAt) >= ttl else { return }
        computedAt = now

        var next: [Tool: ToolUsage] = [:]
        for reader in readers {
            guard let usage = reader.usage() else { continue }
            next[usage.tool] = usage
        }
        current = next
    }

    func usage(for tool: Tool) -> ToolUsage? { current[tool] }

    /// Everything we have, in a stable order so the panel does not reshuffle
    /// itself between refreshes.
    var all: [ToolUsage] {
        Tool.allCases.compactMap { current[$0] }
    }
}

/// Per-model breakdowns, computed away from the main thread.
///
/// Separate from `UsageStore` because of what it costs. An account limit is one
/// small file read to its end; a model breakdown is arithmetic over every
/// transcript touched in the last week — 82 MB of the 296 MB those files
/// occupy, on the machine this was written on. The list refreshes on a two
/// second timer on the main thread, and a scan like that there is a visible
/// freeze.
///
/// So this never computes anything on the caller's thread. `refresh` starts a
/// pass if one is due and returns; readers get whatever the last completed pass
/// produced, which for the first second or two after launch is nothing. That is
/// the honest state rather than a stalled window: the panel simply has no rows
/// to draw yet.
///
/// The tallies underneath keep the incremental state that makes later passes
/// cheap, and are touched only by the worker — one pass at a time, which
/// `working` enforces.
final class ModelUsageStore {

    /// The spans reported, whatever windows a vendor happens to meter.
    ///
    /// Five hours and seven days for everyone, and deliberately not derived
    /// from the limits sitting above them. Codex meters a 30-day window, and
    /// following it would mean keeping a month of transcripts in memory to fill
    /// one row. These are a companion to the limits — what you have been
    /// spending, by model — not a decomposition of them, which is a thing no
    /// local data can produce.
    static let windows = [300, 10_080]

    private let ttl: TimeInterval
    private let queue = DispatchQueue(label: "app.popy.corral.model-usage", qos: .utility)
    private let lock = NSLock()

    private let claude: ClaudeModelTally
    private let codex: CodexModelTally

    private var current: [Tool: [ModelBreakdown]] = [:]
    private var computedAt: Date = .distantPast
    private var working = false

    /// Whether a pass has ever finished.
    ///
    /// Not the same question as whether there is anything to show, and the
    /// panel needs both: for the first seconds after launch an empty result
    /// means "still counting", and after that it means "nothing has run".
    /// Telling someone with no session logs that Corral is still counting
    /// would be a promise it never keeps.
    private var counted = false

    init(
        claude: ClaudeModelTally = ClaudeModelTally(),
        codex: CodexModelTally = CodexModelTally(),
        ttl: TimeInterval = 90
    ) {
        self.claude = claude
        self.codex = codex
        self.ttl = ttl
    }

    func refresh(now: Date = Date()) {
        lock.lock()
        let due = !working && now.timeIntervalSince(computedAt) >= ttl
        if due { working = true }
        lock.unlock()
        guard due else { return }

        queue.async { [self] in
            let horizon = TimeInterval(Self.windows.max() ?? 10_080) * 60
            claude.refresh(now: now, horizon: horizon)
            codex.refresh(now: now, horizon: horizon)

            var next: [Tool: [ModelBreakdown]] = [:]
            next[.claudeCode] = Self.breakdowns(of: claude.turns, now: now)
            next[.codex] = Self.breakdowns(of: codex.turns, now: now)

            lock.lock()
            current = next.filter { !$0.value.isEmpty }
            computedAt = Date()
            working = false
            counted = true
            lock.unlock()
        }
    }

    /// One breakdown per window, and only the windows that saw work. A row
    /// reading "5-hour: nothing" is noise next to one that has something in it.
    private static func breakdowns(of turns: [ModelTurn], now: Date) -> [ModelBreakdown] {
        windows.compactMap { minutes in
            let breakdown = ModelTally.breakdown(
                of: turns,
                window: UsageWindow.label(minutes: minutes),
                since: now.addingTimeInterval(-TimeInterval(minutes) * 60),
                observedAt: now
            )
            return breakdown.isEmpty ? nil : breakdown
        }
    }

    func breakdowns(for tool: Tool) -> [ModelBreakdown] {
        lock.lock()
        defer { lock.unlock() }
        return current[tool] ?? []
    }

    /// Everything, for the vendor grouping the rail does.
    var all: [Tool: [ModelBreakdown]] {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    var hasCounted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return counted
    }
}
