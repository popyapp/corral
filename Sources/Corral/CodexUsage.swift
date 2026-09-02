import Foundation

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

    init(root: URL = CodexRollouts.defaultRoot) {
        self.root = root
    }

    func usage() -> ToolUsage? {
        for file in CodexRollouts.newest(under: root) {
            if let found = Self.scan(file) { return found }
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
    private var byFile: [String: [ModelTurn]] = [:]
    private var sizes: [String: UInt64] = [:]

    init(root: URL = CodexRollouts.defaultRoot) {
        self.root = root
    }

    var turns: [ModelTurn] { byFile.values.flatMap { $0 } }

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
