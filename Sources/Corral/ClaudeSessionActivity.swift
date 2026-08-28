import Foundation

/// Reads Claude Code's own session transcript.
///
/// Claude Code appends one JSON object per line to
/// `~/.claude/projects/<project>/<session>.jsonl`, and every entry carries the
/// `cwd` it was written in — which is the same working directory Corral already
/// reads off the process, so the two join without either side guessing.
struct ClaudeSessionActivityReader: SessionActivityReader {

    private let root: URL

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")) {
        self.root = root
    }

    /// Claude Code names a project's folder after its path, with every
    /// character that is not a letter, a digit or a dash replaced by one.
    ///
    /// The mapping is lossy — `popy_app` and `popy-app` both land on
    /// `popy-app` — so this is only a way to find the right folder quickly.
    /// What settles it is the `cwd` recorded inside the entries themselves.
    static func directoryName(for cwd: String) -> String {
        String(cwd.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
    }

    func reading(_ lookup: SessionLookup) -> SessionActivityReading? {
        for file in transcripts(for: lookup) where !lookup.claimed.contains(file.path) {
            if let hit = scan(file, expecting: lookup.project, startedAt: lookup.startedAt) {
                return SessionActivityReading(activity: hit, source: file.path)
            }
        }
        return nil
    }

    /// The session files for a project, most recently written first.
    ///
    /// More than one is normal — every `claude` you start in a directory adds
    /// another, and old ones are never cleaned up. Nothing in a transcript
    /// records a pid, so the file cannot be tied to the process directly; what
    /// rules the old ones out is time, in `scan`.
    private func transcripts(for lookup: SessionLookup) -> [URL] {
        let folder = root.appendingPathComponent(Self.directoryName(for: lookup.project))
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var candidates = contents
            .filter { $0.pathExtension == "jsonl" }
            .sorted { modified($0) > modified($1) }
            .prefix(5)
            .map { $0 }

        // A name beats every heuristic — when the file is really there.
        // CLAUDE_CODE_SESSION_ID is the session the process was launched as,
        // and a session that has since been resumed or forked writes somewhere
        // else, so this is a promotion rather than a shortcut.
        if let id = lookup.sessionId {
            let named = folder.appendingPathComponent("\(id).jsonl")
            if FileManager.default.fileExists(atPath: named.path) {
                candidates.removeAll { $0.path == named.path }
                candidates.insert(named, at: 0)
            }
        }
        return candidates
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    /// Walk a transcript backwards and report the newest entry that says
    /// something. Entries the session wrote about itself — mode changes, title
    /// updates, file snapshots — are not activity and are skipped.
    private func scan(_ file: URL, expecting cwd: String, startedAt: Date) -> SessionActivity? {
        for line in FileTail.lines(of: file) {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  record["type"] as? String == "assistant"
            else { continue }

            // The folder name is a lossy guess, so the recorded path is worth
            // checking — but only for a different *project*. An entry written
            // after the session cd'd into a subdirectory records that
            // subdirectory, and it is still the same session.
            if let recorded = record["cwd"] as? String, !Self.belongs(recorded, to: cwd) {
                return nil
            }

            guard let at = Self.timestamp(record["timestamp"]),
                  let summary = Self.summarise(record)
            else { continue }

            // A session this process is running cannot have stopped talking
            // before the process existed. That one comparison is what separates
            // the live transcript from the pile of abandoned ones a long-lived
            // project accumulates — a resumed session keeps writing to its old
            // file, so its *last* entry is recent even when its first is not.
            guard at >= startedAt else { return nil }

            return SessionActivity(
                summary: summary,
                at: at,
                fromSubagent: record["isSidechain"] as? Bool ?? false
            )
        }
        return nil
    }

    /// What a single assistant turn amounts to, in one line.
    ///
    /// Blocks are read from the end: a turn that thought, then spoke, then
    /// called a tool is, right now, running that tool — and that is the more
    /// useful thing to say.
    static func summarise(_ record: [String: Any]) -> String? {
        guard let message = record["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]]
        else { return nil }

        for block in blocks.reversed() {
            switch block["type"] as? String {
            case "tool_use":
                if let name = block["name"] as? String { return "Running \(name)" }
            case "text":
                if let line = (block["text"] as? String).flatMap({ SessionActivity.firstLine($0) }) {
                    return line
                }
            case "thinking":
                return "Thinking"
            default:
                continue
            }
        }
        return nil
    }

    /// Whether a path recorded in an entry places it in this project.
    static func belongs(_ recorded: String, to project: String) -> Bool {
        recorded == project || recorded.hasPrefix(project.hasSuffix("/") ? project : project + "/")
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func timestamp(_ raw: Any?) -> Date? {
        guard let text = raw as? String else { return nil }
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

extension SessionActivity {
    /// The first line of a message worth reading, as plain text, capped.
    ///
    /// An agent's reply can be a page long and is written in Markdown, so the
    /// first *line* is not always the first thing it says — a reply can open
    /// with a heading, a bullet or a whole code block. Code blocks are skipped
    /// entirely: a row saying `let x = 1` describes nothing. The syntax comes
    /// off what is left before the cap, so a message is never truncated in the
    /// middle of a delimiter.
    static func firstLine(_ text: String, limit: Int = 120) -> String? {
        var insideFence = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if MarkdownText.isFence(line) {
                insideFence.toggle()
                continue
            }
            guard !insideFence else { continue }
            guard !MarkdownText.isStructural(line) else { continue }
            let plain = MarkdownText.plain(line)
            guard !plain.isEmpty else { continue }
            return plain.count <= limit ? plain : String(plain.prefix(limit - 1)) + "…"
        }
        return nil
    }
}
