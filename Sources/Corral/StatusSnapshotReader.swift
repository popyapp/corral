import Foundation

/// Reads back what `Corral --statusline` was told, for one tool.
///
/// Two answers come out of the same files, and they are the two an agent
/// otherwise keeps to itself. The account's limits, which are on no disk
/// anywhere until the status line hands them over — Claude Code sends these,
/// Cursor does not. And the *stated* size of the context window, which settles
/// by fact what `ClaudeContext` can only work out by inference, and which for
/// Cursor's CLI is the only way to know it at all: that agent's conversation
/// store is ordered by an encrypted index Corral deliberately does not open.
///
/// Everything here degrades to nothing. Before the status line is set up there
/// are no files; on a plan with no metered limits there are files with no
/// limits in them. Both are ordinary, and both mean a row Corral does not draw.
struct StatusSnapshotReader: UsageReader {

    /// Whose files to read. Snapshots from every tool share a folder, so this
    /// is what keeps one agent's numbers from being reported under another's
    /// name.
    let tool: Tool
    private let directory: URL

    init(tool: Tool, directory: URL = StatusLine.directory) {
        self.tool = tool
        self.directory = directory
    }

    /// The account's limits, from whichever session reported most recently.
    ///
    /// Any session will do: the limits belong to the account, so every session
    /// sees the same numbers. The newest is used because it is the least stale,
    /// not because it is more authoritative.
    func usage() -> ToolUsage? {
        let recent = snapshots()
            .filter { !$0.limits.isEmpty }
            .max { $0.writtenAt < $1.writtenAt }
        guard let recent else { return nil }

        return ToolUsage(
            tool: tool,
            limits: recent.limits.map {
                UsageLimit(label: $0.label, usedFraction: $0.usedFraction, resetsAt: $0.resetsAt)
            },
            plan: nil,
            observedAt: recent.writtenAt
        )
    }

    /// One session's snapshot, when it has one.
    func snapshot(for sessionId: String) -> StatusSnapshot? {
        // Composed from *this* reader's directory. It used to ask `StatusLine`
        // for the path, which always answered with the real one — so the
        // injected directory was honoured when listing and ignored when looking
        // one up. Two behaviours from one parameter is the kind of thing that
        // is only ever found by a test, and was.
        let named = directory.appendingPathComponent(
            StatusLine.fileName(for: tool, session: sessionId)
        )
        if let snapshot = decode(named) { return snapshot }
        // The same fallback the listing has: a file written before the prefix
        // existed is Claude Code's. Without it, looking a session up by name
        // would miss exactly the files `snapshots()` can see.
        guard tool == .claudeCode else { return nil }
        return decode(directory.appendingPathComponent("\(sessionId).json"))
    }

    /// The context window a session reported, as a fact rather than a guess.
    func context(for sessionId: String) -> ContextUse? {
        guard let snapshot = snapshot(for: sessionId),
              let used = snapshot.contextUsed,
              let window = snapshot.contextWindow, window > 0
        else { return nil }
        return ContextUse(usedTokens: used, windowTokens: window, windowIsCertain: true)
    }

    // ─ Files ────────────────────────────────────────────────────────────────

    private func snapshots() -> [StatusSnapshot] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        // Filtered by name before opening anything: the tool is in the filename
        // exactly so that reading one agent's snapshots does not mean parsing
        // every other agent's as well.
        return files.filter { $0.pathExtension == "json" && mine($0) }.compactMap(decode)
    }

    /// Whether a file is this reader's.
    ///
    /// The name is checked before anything is opened, so reading one agent's
    /// snapshots does not mean parsing every other agent's as well. Files from
    /// before the prefix existed have no tool in the name and belong to Claude
    /// Code, which was the only tool writing them.
    private func mine(_ file: URL) -> Bool {
        let name = file.lastPathComponent
        if name.hasPrefix("\(tool.rawValue)-") { return true }
        let known = Tool.allCases.map { "\($0.rawValue)-" }
        return tool == .claudeCode && !known.contains(where: name.hasPrefix)
    }

    private func decode(_ file: URL) -> StatusSnapshot? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let snapshot = try? decoder.decode(StatusSnapshot.self, from: data) else { return nil }
        // The filename is a convention; the file itself is the authority.
        return snapshot.tool == tool ? snapshot : nil
    }
}
