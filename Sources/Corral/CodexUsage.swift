import Foundation
import SQLite3

/// Finding Codex's rollout logs.
///
/// Rollouts are filed by date — `~/.codex/sessions/<yyyy>/<mm>/<dd>/` — so the
/// newest are the deepest. Walking the tree and sorting by modification time is
/// simpler than reasoning about the date folders, and there are few enough
/// files for it to be cheap.
enum CodexRollouts {

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    }

    static func newest(under root: URL, limit: Int = 8) -> [URL] {
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
}

/// Reads the rate limits Codex keeps for itself.
///
/// Codex writes a `token_count` event after every turn and hangs the account's
/// limits off it: the percentage used, how long the window runs, and the
/// instant it resets. So the numbers a usage panel wants are already on this
/// machine, put there by the tool, and nothing has to be asked of a server.
///
/// What that costs is freshness, and it is not a small cost. The figures are a
/// by-product of the last turn Codex took — on the machine this was written on
/// the newest rollout was nine days old — so what comes back is a dated
/// snapshot, never a live reading. `ToolUsage.observedAt` carries the date and
/// the panel is required to show it.
struct CodexUsageReader: UsageReader {

    private let root: URL
    private let auth: URL

    init(root: URL = CodexRollouts.defaultRoot, auth: URL = CodexAccount.defaultAuth) {
        self.root = root
        self.auth = auth
    }

    func usage() -> ToolUsage? {
        for file in CodexRollouts.newest(under: root) {
            guard let found = Self.scan(file) else { continue }
            // The plan Codex signed in with beats the plan a turn once saw.
            // A rollout says what the account was when the turn ran; someone
            // who upgraded yesterday and has not run Codex since would read
            // "free" under numbers that are now a Plus account's, for as long
            // as they did not open Codex — which is exactly the moment they
            // are looking at this panel to see what changed.
            guard let plan = CodexAccount.plan(in: auth) else { return found }
            return ToolUsage(
                tool: found.tool, limits: found.limits, plan: plan, observedAt: found.observedAt
            )
        }
        return nil
    }

    /// The newest `token_count` entry in one rollout.
    ///
    /// Read from the end, and the first one wins: earlier entries in the same
    /// file describe the same account at an earlier point in the session, which
    /// is strictly worse information.
    static func scan(_ file: URL) -> ToolUsage? {
        for line in FileTail.lines(of: file) {
            guard let payload = tokenCount(line),
                  let raw = payload.body["rate_limits"] as? [String: Any]
            else { continue }
            let limits = Self.limits(from: raw)
            // An entry with no window in it — a plan with nothing metered, or a
            // shape we do not recognise — is not a usage reading. Keep looking
            // rather than reporting an empty gauge as if it meant zero.
            guard !limits.isEmpty else { continue }
            return ToolUsage(
                tool: .codex,
                limits: limits,
                plan: raw["plan_type"] as? String,
                observedAt: payload.at
            )
        }
        return nil
    }

    /// Codex reports one or two windows: `primary` is the long one every plan
    /// has, `secondary` the shorter burst window, and it is null on plans that
    /// do not meter one.
    static func limits(from raw: [String: Any]) -> [UsageLimit] {
        ["secondary", "primary"].compactMap { key in
            guard let window = raw[key] as? [String: Any],
                  let used = JSONNumber.double(window["used_percent"])
            else { return nil }
            return UsageLimit(
                label: UsageWindow.label(minutes: JSONNumber.int(window["window_minutes"]) ?? 0),
                usedFraction: used / 100,
                resetsAt: JSONNumber.double(window["resets_at"])
                    .map { Date(timeIntervalSince1970: $0) }
            )
        }
    }

    /// A `token_count` line, with the timestamp of the record that wrapped it.
    static func tokenCount(_ line: String) -> (body: [String: Any], at: Date)? {
        guard let data = line.data(using: .utf8),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = record["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let at = ClaudeSessionActivityReader.timestamp(record["timestamp"])
        else { return nil }
        return (payload, at)
    }
}

// ─ The plan, from the sign-in ───────────────────────────────────────────────

/// What Codex signed in as.
///
/// Codex keeps its sign-in in `~/.codex/auth.json`, and the identity token in
/// it is a JWT whose payload names the ChatGPT plan — `chatgpt_plan_type`,
/// under the `https://api.openai.com/auth` claim. That file is refreshed on
/// every login and token renewal, so it knows about an upgrade the moment
/// Codex does, where the rollouts only learn on the next turn.
///
/// Only the one claim is read. The token is not verified — nothing is being
/// trusted on the strength of it, it is a label for a pill — and it is not
/// held: the payload is decoded, the plan copied out, and the rest dropped.
/// Nothing here is sent anywhere.
enum CodexAccount {

    static var defaultAuth: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    }

    static func plan(in auth: URL = defaultAuth) -> String? {
        guard let data = try? Data(contentsOf: auth),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["id_token"] as? String
        else { return nil }
        return plan(inIdentityToken: token)
    }

    /// The plan claim out of a JWT, or nothing.
    static func plan(inIdentityToken token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let payload = base64URLDecode(String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let plan = auth["chatgpt_plan_type"] as? String, !plan.isEmpty
        else { return nil }
        return plan
    }

    /// JWTs use the URL-safe alphabet and drop the padding; Foundation wants
    /// the standard one, padded.
    private static func base64URLDecode(_ text: String) -> Data? {
        var standard = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while standard.count % 4 != 0 { standard += "=" }
        return Data(base64Encoded: standard)
    }
}

// ─ Context ──────────────────────────────────────────────────────────────────

enum CodexContext {

    /// How full this session's context window is, from a `token_count` payload.
    ///
    /// Codex states the window size itself, which makes this the easy half of
    /// the problem — Claude Code does not, and `ClaudeContext` is the price of
    /// that. The figure to read is `last_token_usage.input_tokens`: what the
    /// model was handed on the most recent turn, cached portion included.
    /// `total_token_usage` is the session's running total and would climb past
    /// the window inside an hour.
    static func use(_ payload: [String: Any]) -> ContextUse? {
        guard let info = payload["info"] as? [String: Any],
              let window = JSONNumber.int(info["model_context_window"]), window > 0,
              let last = info["last_token_usage"] as? [String: Any],
              let used = JSONNumber.int(last["input_tokens"])
        else { return nil }
        return ContextUse(usedTokens: used, windowTokens: window, windowIsCertain: true)
    }
}

// ─ Which models did the work ────────────────────────────────────────────────

extension CodexRollouts {

    /// Rollouts written to inside a window, with their sizes.
    static func changed(since cutoff: Date, under root: URL) -> [(URL, UInt64)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [(URL, UInt64)] = []
        for case let url as URL in walker
        where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let at = values.contentModificationDate, at >= cutoff,
                  let size = values.fileSize
            else { continue }
            found.append((url, UInt64(size)))
        }
        return found
    }
}

/// Codex's newer session store.
///
/// Rollout files are not the whole picture any more. Alongside them Codex keeps
/// a SQLite database with a row per session — the model, the tokens, when it
/// was last touched — and it carries a `rollout_migration_state` table, which
/// is Codex's own record that the JSONL files are on their way out. That table
/// is empty today and the two sources agree exactly: the same two sessions,
/// 475,858 and 129,099 tokens, matching the rollouts to the token. The day the
/// migration runs, a reader that only knows about rollouts goes quiet without
/// failing, which is the worst way for a thing to stop working.
///
/// What it cannot give is a split. `tokens_used` is one number, and no table in
/// any of Codex's databases separates input from output — so anything built on
/// this is honestly about totals, and says so rather than filling in an output
/// figure it does not have.
enum CodexThreads {

    struct Session {
        let model: String
        let tokens: Int
        let at: Date
        /// The rollout this session also wrote, when it wrote one.
        let rollout: String?
    }

    /// The newest state database under Codex's directory.
    ///
    /// The digit in `state_5.sqlite` is a schema version and it has already
    /// moved; naming one here would mean going quiet on the next migration,
    /// which is the exact failure this file exists to avoid.
    static func database(under root: URL) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path)
        else { return nil }
        let versioned = names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"),
                  let version = Int(name.dropFirst(6).dropLast(7))
            else { return nil }
            return (version, name)
        }
        guard let newest = versioned.max(by: { $0.0 < $1.0 }) else { return nil }
        return root.appendingPathComponent(newest.1)
    }

    /// Sessions touched since a cutoff.
    ///
    /// Opened read-only, and that is not a detail. Codex may be writing to this
    /// file at the moment it is read; Corral's business here is to look. The
    /// columns are named one by one for the same reason — the table also holds
    /// the first message of every session, its title, the branch and the origin
    /// URL, and none of that is any of Corral's business either.
    static func sessions(in file: URL, since cutoff: Date) -> [Session] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return []
        }
        defer { sqlite3_close(handle) }
        // A moment's patience if Codex is mid-write, then give up. A usage
        // panel is not worth blocking a refresh over.
        //
        // Read-only and a live writer are compatible here, which was worth
        // checking rather than hoping: a connection opened this way reads rows
        // sitting in an uncheckpointed write-ahead log while the writer still
        // holds its own connection open. Measured, because the case it covers —
        // Codex running — is the case that matters, and the failure would have
        // been an empty panel rather than an error.
        sqlite3_busy_timeout(handle, 200)

        var statement: OpaquePointer?
        let sql = """
            SELECT model, tokens_used, updated_at_ms, rollout_path FROM threads
            WHERE updated_at_ms >= ? AND tokens_used > 0
            """
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return []
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(cutoff.timeIntervalSince1970 * 1000))

        var found: [Session] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let model = sqlite3_column_text(statement, 0) else { continue }
            let rollout = sqlite3_column_text(statement, 3).map { String(cString: $0) }
            found.append(Session(
                model: String(cString: model),
                tokens: Int(sqlite3_column_int64(statement, 1)),
                at: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 2)) / 1000),
                rollout: rollout
            ))
        }
        return found
    }
}

/// Counts Codex's rollouts into per-model totals.
///
/// Codex writes the model per *turn* rather than per session — `turn_context`
/// carries it, and `/model` mid-session changes it — so attribution is a matter
/// of reading forwards and remembering the last one seen. The tokens come from
/// the `token_count` event that follows: its `last_token_usage` is that turn's
/// own consumption, where `total_token_usage` is the session's running sum and
/// would count every earlier turn again on every later one. Summing the deltas
/// reproduces the session total exactly — checked against both rollouts on the
/// machine this was written on, 129,099 and 475,858 tokens, to the token.
///
/// Simpler than the Claude side and allowed to be. Rollouts are one file per
/// session and a few hundred kilobytes each, so a changed file is re-read whole
/// rather than from a remembered offset, and there are no duplicate records to
/// reconcile.
final class CodexModelTally {

    private let root: URL
    private let state: URL
    private var byFile: [String: [ModelTurn]] = [:]
    private var sizes: [String: UInt64] = [:]

    /// Sessions the rollouts did not account for. Not cached between passes:
    /// there are a handful of rows and the query is a millisecond, where the
    /// rollout files are the thing worth remembering a position in.
    private var unrolled: [ModelTurn] = []

    /// `root` is where the rollouts are, `state` the directory above it, which
    /// is where Codex keeps its databases.
    init(root: URL = CodexRollouts.defaultRoot, state: URL? = nil) {
        self.root = root
        self.state = state ?? root.deletingLastPathComponent()
    }

    var turns: [ModelTurn] { byFile.values.flatMap { $0 } + unrolled }

    func refresh(now: Date = Date(), horizon: TimeInterval = 7 * 86_400) {
        let cutoff = now.addingTimeInterval(-horizon)
        var live: Set<String> = []

        for (url, size) in CodexRollouts.changed(since: cutoff, under: root) {
            let path = url.path
            live.insert(path)
            guard sizes[path] != size else { continue }
            byFile[path] = Self.scan(url).filter { $0.at >= cutoff }
            sizes[path] = size
        }

        byFile = byFile.filter { live.contains($0.key) }
        sizes = sizes.filter { live.contains($0.key) }
        unrolled = Self.sessionsWithoutARollout(under: state, since: cutoff)
    }

    /// Sessions from the database that no rollout file describes.
    ///
    /// A session that wrote a rollout is counted from it and not from here: the
    /// rollout has a turn-by-turn split, this has one total for the whole
    /// thread pinned to the moment it was last touched. Better information wins
    /// where there is any, and the existence of the file is the test — if it is
    /// on disk it is either already counted or already outside the window, and
    /// in both cases the row would be a duplicate.
    static func sessionsWithoutARollout(under state: URL, since cutoff: Date) -> [ModelTurn] {
        guard let database = CodexThreads.database(under: state) else { return [] }
        return CodexThreads.sessions(in: database, since: cutoff)
            .filter { session in
                guard let rollout = session.rollout else { return true }
                return !FileManager.default.fileExists(atPath: rollout)
            }
            .map { ModelTurn(at: $0.at, model: $0.model, totalTokens: $0.tokens) }
    }

    /// One rollout, forwards.
    ///
    /// A `token_count` before any `turn_context` cannot be attributed to a
    /// model, and is dropped rather than filed under a guess. It does not
    /// happen in practice — the turn context is written when the turn opens —
    /// but a row invented for it would be indistinguishable from a real one.
    static func scan(_ url: URL) -> [ModelTurn] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var model: String?
        var turns: [ModelTurn] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = record["payload"] as? [String: Any]
            else { continue }

            if record["type"] as? String == "turn_context",
               let named = payload["model"] as? String, !named.isEmpty {
                model = named
            }

            guard payload["type"] as? String == "token_count",
                  let model,
                  let at = ClaudeSessionActivityReader.timestamp(record["timestamp"]),
                  let info = payload["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any]
            else { continue }

            // `input_tokens` already contains the cached portion — the sample
            // this was written against reports 29,363 in with 28,416 of them
            // cached, and a total of 29,490 for 127 out. Adding the cached
            // figure again would count most of the turn twice.
            let input = JSONNumber.int(last["input_tokens"]) ?? 0
            let output = JSONNumber.int(last["output_tokens"]) ?? 0
            guard input > 0 || output > 0 else { continue }
            turns.append(ModelTurn(at: at, model: model, inputTokens: input, outputTokens: output))
        }
        return turns
    }
}
