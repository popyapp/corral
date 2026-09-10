import Foundation

/// Where Kiro CLI keeps its sessions.
///
/// One session is three files under `~/.kiro/sessions/cli/`, all named after
/// the session id:
///
///  - `<id>.json` — the session itself: the working directory, a title, when
///    it was last written, the model, how full the context window is, and a
///    record per turn of what that turn cost. Rewritten whole after every turn.
///  - `<id>.jsonl` — the event log: one line per prompt, assistant message
///    and tool result. Append-only, and the only place that says what the
///    agent is doing right now.
///  - `<id>.lock` — `{"pid": …, "started_at": …}` while the session is open.
///    The pid is the engine process (`kiro-cli-chat acp`) holding the
///    session, which is a descendant of the `kiro-cli` Corral lists. That
///    is the one exact link between a process and a log any of these tools
///    provides; every other reader has to reason from paths and times.
///
/// Kiro Crew's agents are Kiro CLI engines too — it starts `kiro-cli acp` per
/// session — so its sessions land here as well, lock files included.
enum KiroSessions {

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kiro/sessions/cli")
    }

    /// Whether Kiro CLI has ever written a session here. The difference
    /// between "nothing to show yet" and "Corral cannot read this".
    static func hasAnySession(under root: URL = defaultRoot) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.contains { $0.hasSuffix(".json") }
    }

    struct Lock {
        let pid: pid_t
        let startedAt: Date?
    }

    static func lock(at url: URL) -> Lock? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = JSONNumber.int(root["pid"]), pid > 0
        else { return nil }
        return Lock(pid: pid_t(pid), startedAt: timestamp(root["started_at"]))
    }

    /// Kiro writes microseconds — `2026-09-09T23:17:16.411392Z` — where the
    /// other tools write milliseconds. Foundation's parser takes both, but
    /// the fallback trims to three digits in case a platform's does not.
    static func timestamp(_ raw: Any?) -> Date? {
        guard let text = raw as? String else { return nil }
        if let date = ClaudeSessionActivityReader.timestamp(text) { return date }
        guard let dot = text.firstIndex(of: "."),
              let zone = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" })
        else { return nil }
        let fraction = text[text.index(after: dot)..<zone]
        let trimmed = text[..<dot] + "." + fraction.prefix(3) + text[zone...]
        return ClaudeSessionActivityReader.timestamp(String(trimmed))
    }

    /// The session files under a root, newest first.
    static func sessionFiles(under root: URL, limit: Int = 12) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .map { url -> (URL, Date) in
                let at = (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate)
                    ?? .distantPast
                return (url, at)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }
}

/// What one session file says.
///
/// Read whole rather than tailed: the file is rewritten after every turn and
/// is a few kilobytes, so there is no end to seek to and nothing to gain by
/// trying.
struct KiroSessionFile {

    /// One turn's costs, as Kiro recorded them.
    struct Turn: Equatable {
        let at: Date
        let model: String
        /// Kiro bills in credits. The token fields exist in the file and are
        /// zero on the plans this was written against, so both are kept and
        /// whichever is non-zero is what gets counted.
        let credits: Double
        let inputTokens: Int
        let outputTokens: Int
    }

    let id: String
    let cwd: String?
    let title: String?
    let updatedAt: Date?
    /// How full the window was after the last turn, 0…100 as Kiro writes it.
    let contextPercentage: Double?
    let windowTokens: Int?
    let turns: [Turn]

    static func read(_ url: URL) -> KiroSessionFile? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return parse(root)
    }

    static func parse(_ root: [String: Any]) -> KiroSessionFile? {
        guard let id = root["session_id"] as? String else { return nil }
        let state = root["session_state"] as? [String: Any] ?? [:]
        let metadata = state["conversation_metadata"] as? [String: Any] ?? [:]
        let rts = state["rts_model_state"] as? [String: Any] ?? [:]
        let info = rts["model_info"] as? [String: Any] ?? [:]

        // The percentage after the last turn is the one to show. The model
        // state carries its own figure, which on a real session lagged the
        // turn's by a compaction — so it is the fallback, not the answer.
        let last = metadata["last_context_usage"] as? [String: Any]
        let percentage = JSONNumber.double(last?["percentage"])
            ?? JSONNumber.double(rts["context_usage_percentage"])

        let turns = (metadata["user_turn_metadatas"] as? [[String: Any]] ?? [])
            .compactMap(turn)

        return KiroSessionFile(
            id: id,
            cwd: root["cwd"] as? String,
            title: root["title"] as? String,
            updatedAt: KiroSessions.timestamp(root["updated_at"]),
            contextPercentage: percentage,
            windowTokens: JSONNumber.int(info["context_window_tokens"]),
            turns: turns
        )
    }

    private static func turn(_ raw: [String: Any]) -> Turn? {
        guard let at = KiroSessions.timestamp(raw["end_timestamp"]),
              let model = raw["model"] as? String, !model.isEmpty
        else { return nil }
        let credits = (raw["metering_usage"] as? [[String: Any]] ?? [])
            .filter { $0["unit"] as? String == "credit" }
            .reduce(0.0) { $0 + (JSONNumber.double($1["value"]) ?? 0) }
        let input = ["input_token_count", "cache_read_input_token_count", "cache_write_input_token_count"]
            .reduce(0) { $0 + (JSONNumber.int(raw[$1]) ?? 0) }
        let output = JSONNumber.int(raw["output_token_count"]) ?? 0
        guard credits > 0 || input > 0 || output > 0 else { return nil }
        return Turn(at: at, model: model, credits: credits, inputTokens: input, outputTokens: output)
    }

    /// How full the window is.
    ///
    /// Kiro states the window's size and a percentage of it, not a count, so
    /// the count here is arithmetic on those two. The size is certain — the
    /// file names it — which is the fact the bar's end depends on.
    var context: ContextUse? {
        guard let percentage = contextPercentage, let window = windowTokens, window > 0
        else { return nil }
        return ContextUse(
            usedTokens: Int((percentage / 100 * Double(window)).rounded()),
            windowTokens: window,
            windowIsCertain: true
        )
    }

    var modelTurns: [ModelTurn] {
        turns.map { turn in
            turn.inputTokens > 0 || turn.outputTokens > 0
                ? ModelTurn(
                    at: turn.at, model: turn.model,
                    inputTokens: turn.inputTokens, outputTokens: turn.outputTokens,
                    credits: turn.credits
                )
                : ModelTurn(at: turn.at, model: turn.model, credits: turn.credits)
        }
    }
}

// ─ What the agent is doing ──────────────────────────────────────────────────

/// Reads Kiro CLI's session for a running agent.
struct KiroSessionActivityReader: SessionActivityReader {

    private let root: URL

    init(root: URL = KiroSessions.defaultRoot) {
        self.root = root
    }

    func reading(_ lookup: SessionLookup) -> SessionActivityReading? {
        // By pid first. A lock naming a process in this group is proof, and
        // the newest such session is the one the person is looking at when
        // there are several — Kiro Crew keeps a few open at once.
        let named = lockedSessions(for: lookup)
        if let best = named.max(by: { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }) {
            return reading(of: best)
        }

        // Then by project, the way the other readers work: a session in this
        // directory, written since this process started, not yet spoken for.
        guard let project = lookup.project else { return nil }
        for url in KiroSessions.sessionFiles(under: root)
        where !lookup.claimed.contains(url.path) {
            guard let session = KiroSessionFile.read(url), session.cwd == project,
                  let at = session.updatedAt, at >= lookup.startedAt
            else { continue }
            return reading(of: session)
        }
        return nil
    }

    /// Sessions whose lock names a pid in the group.
    ///
    /// A lock written before the agent existed cannot be this agent's, however
    /// its pid reads: pids are recycled, and a session that ended without
    /// removing its lock would otherwise attach itself to whatever process
    /// inherited the number.
    private func lockedSessions(for lookup: SessionLookup) -> [KiroSessionFile] {
        guard !lookup.pids.isEmpty else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.hasSuffix(".lock") }.compactMap { name -> KiroSessionFile? in
            let url = root.appendingPathComponent(name)
            guard let lock = KiroSessions.lock(at: url), lookup.pids.contains(lock.pid) else {
                return nil
            }
            if let started = lock.startedAt, started < lookup.startedAt.addingTimeInterval(-1) {
                return nil
            }
            let json = url.deletingPathExtension().appendingPathExtension("json")
            guard !lookup.claimed.contains(json.path) else { return nil }
            return KiroSessionFile.read(json)
        }
    }

    private func reading(of session: KiroSessionFile) -> SessionActivityReading? {
        let json = root.appendingPathComponent("\(session.id).json")
        let log = root.appendingPathComponent("\(session.id).jsonl")
        let at = session.updatedAt
            ?? (try? json.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? Date()

        let summary = Self.latestSummary(in: log)
            ?? session.title.flatMap { SessionActivity.firstLine($0) }
            ?? "Working"

        return SessionActivityReading(
            activity: SessionActivity(summary: summary, at: at, fromSubagent: false),
            source: json.path,
            context: session.context
        )
    }

    /// The newest line of the event log that says something.
    static func latestSummary(in log: URL) -> String? {
        for line in FileTail.lines(of: log) {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let summary = summarise(record) { return summary }
        }
        return nil
    }

    /// One event, in a line.
    ///
    /// The log has three kinds of line. A prompt or a tool result at the end
    /// means the model is between them, working on what it was just given;
    /// an assistant message says what it decided, read from the end the same
    /// way Claude's is — a turn that thought, spoke and then called a tool is
    /// running that tool.
    static func summarise(_ record: [String: Any]) -> String? {
        let data = record["data"] as? [String: Any] ?? [:]
        switch record["kind"] as? String {
        case "Prompt", "ToolResults":
            return "Working"
        case "AssistantMessage":
            let blocks = data["content"] as? [[String: Any]] ?? []
            for block in blocks.reversed() {
                switch block["kind"] as? String {
                case "toolUse":
                    if let name = (block["data"] as? [String: Any])?["name"] as? String {
                        return "Running \(name)"
                    }
                case "text":
                    if let line = (block["data"] as? String).flatMap({ SessionActivity.firstLine($0) }) {
                        return line
                    }
                case "thinking":
                    return "Thinking"
                default:
                    continue
                }
            }
            return nil
        default:
            return nil
        }
    }
}

// ─ What the work cost ───────────────────────────────────────────────────────

/// Counts Kiro's sessions into per-model totals.
///
/// Kiro writes a record per turn with the model and what the turn cost, in
/// credits — the token fields are there and are zero. So this is a tally of
/// credits, and `ModelBreakdown` says so when it draws them: a bar labelled
/// "output" over a number that is not output would be the lie this whole
/// panel is arranged to avoid.
///
/// Sessions are small files rewritten whole, so a changed one is re-read
/// entirely and there is no offset to remember. Only files touched inside the
/// window are opened at all.
final class KiroModelTally {

    private let root: URL
    private var byFile: [String: [ModelTurn]] = [:]
    private var stamps: [String: (size: Int, modified: Date)] = [:]

    init(root: URL = KiroSessions.defaultRoot) {
        self.root = root
    }

    var turns: [ModelTurn] { byFile.values.flatMap { $0 } }

    func refresh(now: Date = Date(), horizon: TimeInterval = 7 * 86_400) {
        let cutoff = now.addingTimeInterval(-horizon)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []

        var live: Set<String> = []
        for url in files where url.pathExtension == "json" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let modified = values.contentModificationDate, modified >= cutoff,
                  let size = values.fileSize
            else { continue }
            let path = url.path
            live.insert(path)
            if let known = stamps[path], known.size == size, known.modified == modified { continue }
            byFile[path] = (KiroSessionFile.read(url)?.modelTurns ?? []).filter { $0.at >= cutoff }
            stamps[path] = (size, modified)
        }

        byFile = byFile.filter { live.contains($0.key) }
        stamps = stamps.filter { live.contains($0.key) }
    }
}
