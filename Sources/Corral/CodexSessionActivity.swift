import Foundation

/// Reads Codex's rollout logs.
///
/// Codex appends JSON lines to
/// `~/.codex/sessions/<yyyy>/<mm>/<dd>/rollout-<time>-<id>.jsonl`. Unlike
/// Claude Code, the working directory is recorded once, in the `session_meta`
/// entry at the very top of the file — so a session is identified by its first
/// line and described by its last ones.
struct CodexSessionActivityReader: SessionActivityReader {

    private let root: URL

    init(root: URL = CodexRollouts.defaultRoot) {
        self.root = root
    }

    func reading(_ lookup: SessionLookup) -> SessionActivityReading? {
        for file in CodexRollouts.newest(under: root)
        where !lookup.claimed.contains(file.path) && Self.projectPath(of: file) == lookup.project {
            if let hit = scan(file), hit.activity.at >= lookup.startedAt {
                return SessionActivityReading(
                    activity: hit.activity, source: file.path, context: hit.context
                )
            }
        }
        return nil
    }

    static func projectPath(of file: URL) -> String? {
        guard let line = FileTail.firstLine(of: file),
              let data = line.data(using: .utf8),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              record["type"] as? String == "session_meta",
              let payload = record["payload"] as? [String: Any]
        else { return nil }
        return payload["cwd"] as? String
    }

    /// The newest line that says something, and the newest that counts tokens.
    ///
    /// They are different entries — Codex reports the window in its own
    /// `token_count` event, which is emitted after the turn the activity line
    /// came from — so the walk carries on until it has both, or runs out.
    private func scan(_ file: URL) -> (activity: SessionActivity, context: ContextUse?)? {
        var found: SessionActivity?
        var context: ContextUse?

        for line in FileTail.lines(of: file) {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = record["payload"] as? [String: Any]
            else { continue }

            if context == nil, payload["type"] as? String == "token_count" {
                context = CodexContext.use(payload)
            }

            if found == nil,
               let summary = Self.summarise(payload),
               let at = ClaudeSessionActivityReader.timestamp(record["timestamp"]) {
                found = SessionActivity(summary: summary, at: at, fromSubagent: false)
            }

            if found != nil && context != nil { break }
        }

        guard let found else { return nil }
        return (found, context)
    }

    /// Codex splits one turn across two entries — an `event_msg` for the UI and
    /// a `response_item` for the model's own history — so the same sentence
    /// appears twice. Either is fine; whichever is newer is read first.
    static func summarise(_ payload: [String: Any]) -> String? {
        switch payload["type"] as? String {
        case "agent_message":
            return (payload["message"] as? String).flatMap { SessionActivity.firstLine($0) }
        case "custom_tool_call", "function_call", "local_shell_call":
            if let name = payload["name"] as? String { return "Running \(name)" }
            return "Running a tool"
        case "task_complete":
            return (payload["last_agent_message"] as? String)
                .flatMap { SessionActivity.firstLine($0) } ?? "Finished"
        case "task_started":
            return "Working"
        default:
            return nil
        }
    }
}
