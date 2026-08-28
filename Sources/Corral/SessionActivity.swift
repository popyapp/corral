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
protocol SessionActivityReader {
    /// The most recent activity for the session a process started at
    /// `startedAt` is running in `cwd`.
    ///
    /// The start time is what separates two agents working in the same
    /// project. Nothing in these logs records a pid, so the closest thing to an
    /// identity a session has is when it began.
    func activity(inProject cwd: String, startedAt: Date) -> SessionActivity?
}
