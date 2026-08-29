import Foundation

/// The last thing an agent was seen doing, taken from the session log the tool
/// writes for itself.
///
/// The process view can tell you an agent has been quiet for forty minutes. It
/// cannot tell you whether that is a long test run or a question waiting for an
/// answer, and those two need opposite things from you. Every tool here already
/// writes down what it is doing; this reads it back.
///
/// Nothing is sent anywhere and nothing is written. These are files the tools
/// keep on this machine, read as the user who owns them.
struct SessionActivity: Equatable {
    /// One line, already short enough to sit next to a process.
    let summary: String
    /// When the *tool* wrote it, which is not when Corral read it.
    let at: Date
    /// The line came from a subagent rather than the main thread of the session.
    let fromSubagent: Bool
}

// ─ Reading the tail of a very large file ────────────────────────────────────

enum FileTail {

    /// The last complete lines of a file, newest first.
    ///
    /// Session logs are append-only and get big — one Claude transcript on the
    /// machine this was written on is 23 MB — while the answer is always within
    /// the last few entries. So this seeks to the end and reads a window back.
    ///
    /// The first line of that window is dropped: a byte offset almost never
    /// lands on a line boundary, and half a JSON object parses as nothing.
    static func lines(of url: URL, limit: Int = 256 * 1024) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return [] }
        let window = UInt64(limit)
        let start = end > window ? end - window : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8)
        else { return [] }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if start > 0 && !lines.isEmpty { lines.removeFirst() }
        return lines.reversed()
    }

    /// The first line of a file, for logs that record what a session *is* in
    /// their opening entry and what it is *doing* at the far end.
    static func firstLine(of url: URL, limit: Int = 16 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
    }
}

// ─ What each tool writes ────────────────────────────────────────────────────

/// Reads one tool's session logs. Implementations must be cheap enough to call
/// on every refresh and must never throw — a log we cannot read is a line we
/// do not show, not an error the user has to deal with.
/// Everything a reader is told about the agent it is describing.
struct SessionLookup {
    /// Where the agent process is running.
    let project: String
    /// When the process started. A session cannot have stopped writing before
    /// its own process existed, which is what rules out abandoned logs.
    let startedAt: Date
    /// A session identifier taken from the process, when it gave one up. Exact
    /// when it resolves to a real log; it does not always, because a resumed
    /// session can end up writing somewhere other than where it began.
    let sessionId: String?
    /// Logs already handed to another agent in this round. Nothing in these
    /// files records a pid, so without this two agents in one project are both
    /// described by whichever of them typed last — which is worse than saying
    /// nothing, because it reads as fact.
    let claimed: Set<String>
}

struct SessionActivityReading {
    let activity: SessionActivity
    /// Identifies the log this came out of, so it is not used twice.
    let source: String

    /// How full the session's context window is, when the same log said.
    ///
    /// Carried here rather than behind a protocol of its own because it is
    /// written in the very records this reader is already walking. Splitting it
    /// out would mean a second reader opening the same file to read the same
    /// 256 KB again, for the sake of keeping two words apart.
    let context: ContextUse?

    init(activity: SessionActivity, source: String, context: ContextUse? = nil) {
        self.activity = activity
        self.source = source
        self.context = context
    }
}

protocol SessionActivityReader {
    func reading(_ lookup: SessionLookup) -> SessionActivityReading?
}
