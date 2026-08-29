import Foundation

/// What a coding agent will tell you about itself, if you ask in the one place
/// it answers.
///
/// Neither Claude Code nor Cursor writes what it has left to disk — the figures
/// their own interfaces show come from a server. But both *hand* them to a
/// status line command on every update, in a JSON object on stdin, and the two
/// objects agree field for field on the part that matters. So
/// `Corral --statusline` is a status line that also writes down what it was
/// told, and the app reads it back. No network, no token, no account.
///
/// They do not agree on everything. Claude Code includes `rate_limits`, so the
/// account's five-hour and weekly windows come through; Cursor does not publish
/// them anywhere, so for Cursor this is the context window and nothing else.
/// That is a real difference and the panel says so rather than showing a gap.
///
/// The trade is that it has to be turned on: an agent only runs a status line
/// command that is named in its own settings. See `StatusLineSetup`, which asks
/// first.
struct StatusSnapshot: Codable {
    struct Window: Codable {
        let label: String
        let usedFraction: Double
        let resetsAt: Date?
    }

    /// Which agent reported this.
    ///
    /// Written down rather than inferred. Two tools drop files into the same
    /// folder in the same shape, and a snapshot that could not say where it came
    /// from would be attributed to whichever reader looked first — Cursor's
    /// conversation shown as Claude's allowance.
    let tool: Tool

    let sessionId: String
    let cwd: String?
    /// Tokens in the window right now, and how big the window is. The size is
    /// *stated* here, which is the difference between this and reading a
    /// transcript — see `ClaudeContext`, where it has to be worked out.
    let contextUsed: Int?
    let contextWindow: Int?
    let limits: [Window]
    let writtenAt: Date

    init(
        tool: Tool, sessionId: String, cwd: String?,
        contextUsed: Int?, contextWindow: Int?,
        limits: [Window], writtenAt: Date
    ) {
        self.tool = tool
        self.sessionId = sessionId
        self.cwd = cwd
        self.contextUsed = contextUsed
        self.contextWindow = contextWindow
        self.limits = limits
        self.writtenAt = writtenAt
    }

    /// Snapshots written before there was a second tool carry no `tool` at all.
    ///
    /// They are Claude Code's, because nothing else was writing them. Without
    /// this they simply fail to decode, and every limit the panel is showing
    /// disappears at the moment of an upgrade — until each session happens to
    /// take another turn. They age out on their own within the week.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tool = try container.decodeIfPresent(Tool.self, forKey: .tool) ?? .claudeCode
        sessionId = try container.decode(String.self, forKey: .sessionId)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        contextUsed = try container.decodeIfPresent(Int.self, forKey: .contextUsed)
        contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow)
        limits = try container.decodeIfPresent([Window].self, forKey: .limits) ?? []
        writtenAt = try container.decode(Date.self, forKey: .writtenAt)
    }
}

enum StatusLine {

    /// Where snapshots land.
    ///
    /// Application Support rather than the home directory: this is app state,
    /// not something a person edits, and it should be somewhere the system
    /// already knows to back up and clean.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Corral/status", isDirectory: true)
    }

    /// Which agent invoked us, from `--statusline <name>`.
    ///
    /// Named on the command line rather than sniffed from the payload. The two
    /// objects are near enough identical that any rule for telling them apart
    /// would be guessing, and it would start guessing wrong the first time
    /// either tool added a field.
    static func tool(from arguments: [String]) -> Tool {
        guard let flag = arguments.firstIndex(of: "--statusline"),
              arguments.count > flag + 1
        else { return .claudeCode }
        switch arguments[flag + 1].lowercased() {
        case "cursor", "cursor-agent", "cursoragent": return .cursorAgent
        default: return .claudeCode
        }
    }

    /// The status line itself: read the object, keep the few fields Corral
    /// uses, print a line.
    ///
    /// Deliberately *not* a copy of the whole object. What arrives includes the
    /// transcript path, the working directory, the branch and any open pull
    /// request — a running description of what someone is working on. Corral
    /// needs four numbers and a session id, so four numbers and a session id
    /// are what it keeps.
    static func run(tool: Tool) {
        guard let data = try? FileHandle.standardInput.readToEnd(),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = root["session_id"] as? String
        else { return }

        let snapshot = StatusSnapshot(
            tool: tool,
            sessionId: session,
            cwd: root["cwd"] as? String,
            contextUsed: context(root)?.used,
            contextWindow: context(root)?.window,
            limits: limits(root),
            writtenAt: Date()
        )
        save(snapshot)
        print(line(for: snapshot, cwd: root["cwd"] as? String))
    }

    // ─ Reading what arrived ─────────────────────────────────────────────────

    /// Both tools spell the context window the same way, which is the whole
    /// reason one reader serves both.
    static func context(_ root: [String: Any]) -> (used: Int, window: Int)? {
        guard let window = root["context_window"] as? [String: Any],
              let size = JSONNumber.int(window["context_window_size"]), size > 0,
              let used = JSONNumber.int(window["total_input_tokens"])
        else { return nil }
        return (used, size)
    }

    /// `rate_limits` comes from Claude Code, and only for subscribers, and only
    /// once the session has made a request. Cursor never sends it. Absent is
    /// ordinary and is not an error — it is a row the panel does not draw.
    static func limits(_ root: [String: Any]) -> [StatusSnapshot.Window] {
        guard let limits = root["rate_limits"] as? [String: Any] else { return [] }
        return [("five_hour", "5-hour"), ("seven_day", "7-day")].compactMap { key, label in
            guard let window = limits[key] as? [String: Any],
                  let used = JSONNumber.double(window["used_percentage"])
            else { return nil }
            return StatusSnapshot.Window(
                label: label,
                usedFraction: used / 100,
                resetsAt: JSONNumber.double(window["resets_at"])
                    .map { Date(timeIntervalSince1970: $0) }
            )
        }
    }

    // ─ Keeping it ───────────────────────────────────────────────────────────

    /// Named by tool as well as session, so two agents can never land on the
    /// same file — and so a reader can tell whose a file is without opening it.
    static func fileName(for tool: Tool, session: String) -> String {
        "\(tool.rawValue)-\(session).json"
    }

    static func file(for tool: Tool, session: String) -> URL {
        directory.appendingPathComponent(fileName(for: tool, session: session))
    }

    private static func save(_ snapshot: StatusSnapshot) {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(
            to: file(for: snapshot.tool, session: snapshot.sessionId),
            options: .atomic
        )
        prune(in: directory)
    }

    /// Sessions end without saying so, and nothing else would ever remove their
    /// files. A week is long enough that a snapshot outlives any pause someone
    /// takes and short enough that the folder cannot grow without bound.
    private static func prune(in directory: URL, olderThan age: TimeInterval = 7 * 86_400) {
        let cutoff = Date().addingTimeInterval(-age)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for file in files where file.pathExtension == "json" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date()
            if modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    // ─ What the terminal shows ──────────────────────────────────────────────

    /// The line the agent prints at the bottom of the session.
    ///
    /// Whatever this returns *becomes* the user's status line, so it has to be
    /// worth the row it takes: the project, how full the conversation is, and
    /// how much of the account is gone. Nothing that is not known is mentioned.
    static func line(for snapshot: StatusSnapshot, cwd: String?) -> String {
        var parts: [String] = []
        if let cwd, !cwd.isEmpty {
            parts.append((cwd as NSString).lastPathComponent)
        }
        if let used = snapshot.contextUsed, let window = snapshot.contextWindow, window > 0 {
            parts.append("ctx \(percent(Double(used) / Double(window)))")
        }
        for limit in snapshot.limits {
            let name = limit.label == "5-hour" ? "session" : "week"
            parts.append("\(name) \(percent(limit.usedFraction))")
        }
        return parts.joined(separator: " · ")
    }

    private static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", (fraction * 100).rounded())
    }
}
