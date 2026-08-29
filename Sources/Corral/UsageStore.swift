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
