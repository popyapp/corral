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

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions")) {
        self.root = root
    }

    func activity(inProject cwd: String, startedAt: Date) -> SessionActivity? {
        for file in recentSessions() where Self.projectPath(of: file) == cwd {
            if let hit = scan(file) { return hit }
        }
        return nil
    }

    /// Rollouts are filed by date, so the newest are the deepest. Walking the
    /// tree and sorting by modification time is simpler than reasoning about
    /// the date folders, and there are few enough files for it to be cheap.
    private func recentSessions(limit: Int = 8) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [(URL, Date)] = []
        for case let url as URL in walker
        where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
            let at = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            files.append((url, at))
        }
        return files.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
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

    private func scan(_ file: URL) -> SessionActivity? {
        for line in FileTail.lines(of: file) {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = record["payload"] as? [String: Any],
                  let summary = Self.summarise(payload),
                  let at = ClaudeSessionActivityReader.timestamp(record["timestamp"])
            else { continue }
            return SessionActivity(summary: summary, at: at, fromSubagent: false)
        }
        return nil
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
