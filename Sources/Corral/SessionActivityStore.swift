import Foundation

/// Answers "what is this agent doing" for any tool Corral knows how to read.
///
/// The inventory refreshes every two seconds. Opening three session logs per
/// agent at that rate would be absurd, and none of this changes faster than a
/// person can read a line, so an answer is held briefly and reused. A tool with
/// no reader — Claude Desktop, Windsurf, the Cursor editor's helper processes —
/// simply has nothing to say, which is not an error.
final class SessionActivityStore {

    private let readers: [Tool: SessionActivityReader]
    private let ttl: TimeInterval
    private var cache: [String: (readAt: Date, value: SessionActivity?)] = [:]

    init(
        readers: [Tool: SessionActivityReader] = [
            .claudeCode: ClaudeSessionActivityReader(),
            .codex: CodexSessionActivityReader(),
            .cursorAgent: CursorSessionActivityReader(),
        ],
        ttl: TimeInterval = 3
    ) {
        self.readers = readers
        self.ttl = ttl
    }

    func activity(
        for tool: Tool, inProject cwd: String?, startedAt: Date, now: Date = Date()
    ) -> SessionActivity? {
        guard let cwd, cwd != "/", let reader = readers[tool] else { return nil }
        let key = "\(tool.rawValue)\u{1}\(startedAt.timeIntervalSince1970)\u{1}\(cwd)"
        if let cached = cache[key], now.timeIntervalSince(cached.readAt) < ttl {
            return cached.value
        }
        let value = reader.activity(inProject: cwd, startedAt: startedAt)
        cache[key] = (now, value)
        return value
    }

    /// Drop entries for projects that are no longer on screen, so a long-lived
    /// window does not accumulate one per directory ever visited.
    func forget(keeping live: Set<String>) {
        cache = cache.filter { key, _ in
            live.contains(String(key.split(separator: "\u{1}").last ?? ""))
        }
    }
}
