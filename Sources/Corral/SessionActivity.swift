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

    /// A block of bytes cut at its newlines, as slices that share its storage.
    ///
    /// `Data.split(separator:)` is the obvious way to write this and is the
    /// reason an early version of the model tally took four minutes. `Data`
    /// conforms to `Collection`, so the generic `split` walks it one byte at a
    /// time through that abstraction; measured over the transcripts on this
    /// machine it managed 17 MB/s, which for data already in the page cache is
    /// two orders of magnitude off. `memchr` on the raw buffer does the same
    /// job at memory speed.
    ///
    /// A trailing empty slice, from a block that ends in a newline, is left in:
    /// callers filter it, and dropping it here would hide whether the block was
    /// terminated.
    static func split(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        var bounds: [Int] = []
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var from = 0
            while from < raw.count {
                guard let hit = memchr(base + from, 0x0A, raw.count - from) else { break }
                let at = UnsafeRawPointer(hit) - base
                bounds.append(at)
                from = at + 1
            }
        }

        var lines: [Data] = []
        lines.reserveCapacity(bounds.count + 1)
        var start = data.startIndex
        for offset in bounds {
            let end = data.startIndex + offset
            lines.append(data[start..<end])
            start = end + 1
        }
        lines.append(data[start...])
        return lines
    }

    /// The lines of a file, newest first, without ever holding more than a
    /// chunk of it — and without turning any of it into a `String`.
    ///
    /// For counting rather than glancing. `lines(of:limit:)` above answers
    /// "what happened last" by decoding a window at the end, and that is the
    /// right shape for a window that stays small. Adding up a week of
    /// transcripts is a different job: the answer is spread over tens of
    /// megabytes, the caller stops as soon as it reads back past its own
    /// horizon, and how far back that is cannot be known before looking.
    ///
    /// So this walks backwards a chunk at a time and hands over one line at a
    /// time, as bytes. `JSONSerialization` takes `Data` directly, so a caller
    /// that only wants to parse never pays to build a string it would throw
    /// away — which on this corpus is most of them.
    ///
    /// Returning `true` from `each` stops the walk.
    static func backwards(
        of url: URL,
        chunk: Int = 4 << 20,
        each: (Data) -> Bool
    ) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard var upper = try? handle.seekToEnd() else { return }

        // A line that begins before the chunk we are holding. Kept and glued to
        // the front of the next read rather than parsed in half.
        var carry = Data()

        while upper > 0 {
            let lower = upper > UInt64(chunk) ? upper - UInt64(chunk) : 0
            guard (try? handle.seek(toOffset: lower)) != nil,
                  var data = try? handle.read(upToCount: Int(upper - lower))
            else { return }
            if !carry.isEmpty { data.append(carry) }

            var lines = split(data)
            // At the start of the file there is nothing earlier for the first
            // line to be a continuation of.
            carry = lower > 0 && !lines.isEmpty ? Data(lines.removeFirst()) : Data()

            for line in lines.reversed() where !line.isEmpty {
                if each(line) { return }
            }
            upper = lower
        }
    }

    /// Whatever has been appended to a file since it was last read, as lines of
    /// bytes. The counterpart to `backwards` for a file already seen once.
    static func appendedLines(to url: URL, after offset: UInt64) -> (lines: [Data], next: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], offset) }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return ([], offset) }

        let start = end < offset ? 0 : offset
        guard end > start,
              (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(),
              let lastBreak = data.lastIndex(of: 0x0A)
        else { return ([], start) }

        let complete = data[..<data.index(after: lastBreak)]
        let next = start + UInt64(complete.count)
        return (split(Data(complete)).filter { !$0.isEmpty }, next)
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
    /// Where the agent process is running. Nil for an app with no project of
    /// its own — a desktop app sits at `/`, which names nothing.
    let project: String?
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
    /// Every pid in the group, root and descendants.
    ///
    /// For the one tool that does write a pid down. Kiro CLI's session lock
    /// names the engine process holding it, and that engine is a descendant of
    /// the agent Corral lists — so the match is exact where every other reader
    /// has to reason from paths and times.
    var pids: Set<pid_t> = []
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
