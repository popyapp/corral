import Foundation

/// Works out how full a Claude Code session's context window is.
///
/// Half of this is easy. The number of tokens the model was handed is written
/// down after every turn, and it is the input plus both cache figures — the
/// cached portion is still context, it is just context nobody paid full price
/// for a second time.
///
/// The other half is the size of the window that number is measured against,
/// and Claude Code does not say. `message.model` reads `claude-opus-5` whether
/// the session has a 200K window or a 1M one; the `[1m]` marker lives in the
/// `cost-state` record, and on a real transcript that record sat at line 5,135
/// of 6,610 — thousands of lines outside a tail read, in a file where the last
/// 256 KB covers 145 lines. So the window is settled in this order:
///
///  1. A turn already past 200K *proves* a larger window. Evidence outranks
///     configuration, and this is the case where guessing wrong would draw a
///     bar past the end of its own track.
///  2. The configured model in `settings.json`, if it carries `[1m]`.
///  3. 200K.
///
/// Step 2 is a guess, and a session started with `--model` or switched with
/// `/model` would defeat it. That is survivable because step 1 takes every case
/// above 200K first: the guess is only ever reached at the empty end of the
/// bar, where the difference it gets wrong is the difference between "barely
/// started" and "barely started".
enum ClaudeContext {

    static let standardWindow = 200_000
    static let largeWindow = 1_000_000

    /// The tokens in play on one assistant turn.
    ///
    /// Anything the model read counts, whether it came from the cache or not.
    /// Output is excluded: it is not in the window until the next turn puts it
    /// there, at which point it arrives inside the input figure anyway.
    static func tokens(in record: [String: Any]) -> Int? {
        guard let message = record["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return nil }
        let fields = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
        let total = fields.reduce(0) { $0 + (JSONNumber.int(usage[$1]) ?? 0) }
        return total > 0 ? total : nil
    }

    /// Which window a session is running against, and whether we know it.
    ///
    /// The settings file is passed as a closure rather than a value so that the
    /// common case never opens it: once a turn has been seen above 200K the
    /// answer is already proved, and configuration has nothing to add.
    static func window(
        observedMax: Int,
        configuredModel: () -> String?
    ) -> (tokens: Int, certain: Bool) {
        if observedMax > standardWindow { return (largeWindow, true) }
        if configuredModel()?.contains("[1m]") == true { return (largeWindow, false) }
        return (standardWindow, false)
    }

    /// The model named in the user's own settings.
    ///
    /// Only ever consulted for the `[1m]` marker, so a value this cannot parse
    /// costs nothing — the answer falls through to the 200K default, which is
    /// what an unparseable settings file should mean.
    static func configuredModel(settings: URL = defaultSettings) -> String? {
        guard let data = try? Data(contentsOf: settings),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root["model"] as? String
    }

    static var defaultSettings: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }
}

// ─ Which models did the work ────────────────────────────────────────────────

/// Counts Claude's transcripts into per-model totals.
///
/// The transcripts already say everything needed: every assistant record
/// carries a timestamp, the model that produced it, and the full token
/// breakdown for that turn. Nothing here is derived, estimated, or asked of a
/// server — it is arithmetic over lines the tool wrote itself.
///
/// Three things make it affordable to do on a running app rather than once in
/// a report:
///
///  - Only files touched inside the window are opened at all. A transcript
///    nobody has written to in a week cannot contain a turn from this week.
///  - A file is read backwards from its end until a turn falls out of the
///    window, so a months-old session gives up only its tail. On the machine
///    this was written on that is 82 MB of the 296 MB those files occupy.
///  - After the first pass each file is read from where the last one stopped.
///    Logs only grow, so steady state costs the few kilobytes an agent has
///    written since the last refresh.
///
/// Stateful, and a class for that reason: what it knows is the point.
final class ClaudeModelTally {

    private let root: URL

    /// Keyed by message id, and the largest output for that id wins.
    ///
    /// A single assistant turn is written to the transcript many times — once
    /// as it is still being produced and again each time it waits on a tool.
    /// Across the transcripts on this machine, 15,469 identifiers appear more
    /// than once, one of them seventeen times. Counting records instead of
    /// turns would roughly double every figure, and unevenly, since how often a
    /// message repeats depends on how many tools it called.
    ///
    /// Which copy to believe is the other half, and it is not "the first one".
    /// The early records carry a partial output count — a message that finally
    /// produced 2,267 tokens is written sixteen times saying 4 — and only the
    /// last one is complete. Of the 15,469 repeated identifiers, 1,350 disagree
    /// about output; none disagree about input; and in every single case the
    /// output only ever grows. So the largest wins, which is both correct and
    /// independent of the order records arrive in — and that matters, because
    /// the first pass over a file reads it backwards and every pass after it
    /// reads forwards. Taking the first record seen would have made the same
    /// file report two different totals depending on when it was scanned.
    private var byId: [String: ModelTurn] = [:]

    /// How far into each transcript this has already counted.
    private var cursors: [String: UInt64] = [:]

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")) {
        self.root = root
    }

    /// Every turn still inside the horizon.
    var turns: [ModelTurn] { Array(byId.values) }

    func refresh(now: Date = Date(), horizon: TimeInterval = 7 * 86_400) {
        let cutoff = now.addingTimeInterval(-horizon)
        var live: Set<String> = []

        for (url, size) in transcripts(changedSince: cutoff) {
            let path = url.path
            live.insert(path)

            if let cursor = cursors[path], size >= cursor {
                if size == cursor { continue }
                let appended = FileTail.appendedLines(to: url, after: cursor)
                for line in appended.lines { absorb(line, cutoff: cutoff) }
                cursors[path] = appended.next
                continue
            }
            readBack(url, cutoff: cutoff)
            cursors[path] = size
        }

        // A transcript that has aged out of the window is one whose position we
        // no longer have any use for, and whose turns are about to be dropped.
        cursors = cursors.filter { live.contains($0.key) }
        byId = byId.filter { $0.value.at >= cutoff }
    }

    /// Transcripts written to inside the window, with their sizes.
    private func transcripts(changedSince cutoff: Date) -> [(URL, UInt64)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [(URL, UInt64)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let at = values.contentModificationDate, at >= cutoff,
                  let size = values.fileSize
            else { continue }
            found.append((url, UInt64(size)))
        }
        return found
    }

    /// The first pass over a file: backwards from the end, stopping at the
    /// first turn that falls outside the window.
    ///
    /// Backwards because that is where the answer is. A transcript can be
    /// months old and still have been written to this morning; walking it from
    /// the top would read all of it to use the last tenth. Every byte is read
    /// once — the earlier version of this widened a window and re-read what it
    /// had already parsed, which cost more in JSON than the extra reads saved
    /// in seeks.
    private func readBack(_ url: URL, cutoff: Date) {
        // Stopping at the *first* turn older than the window would be right if
        // transcripts were strictly ordered, and they are, nearly always. The
        // cost of being wrong about that is silent: a single stray record —
        // written out of order, replayed on a resume — ends the read, and every
        // turn beyond it is missing from a total that still looks like a total.
        // A run of them is evidence; one is not. Twenty-five costs a few
        // hundred kilobytes of extra reading in the case that never happens.
        var consecutivelyOld = 0
        FileTail.backwards(of: url) { line in
            guard let found = Self.turn(line) else { return false }
            if found.turn.at < cutoff {
                consecutivelyOld += 1
                return consecutivelyOld >= 25
            }
            consecutivelyOld = 0
            keep(found)
            return false
        }
    }

    private func absorb(_ line: Data, cutoff: Date) {
        guard let found = Self.turn(line), found.turn.at >= cutoff else { return }
        keep(found)
    }

    /// The completed copy of a turn beats an unfinished one. See `byId`.
    private func keep(_ found: (id: String, turn: ModelTurn)) {
        if let seen = byId[found.id], seen.outputTokens >= found.turn.outputTokens { return }
        byId[found.id] = found.turn
    }

    /// The cheap test that decides whether a line is worth decoding.
    ///
    /// Most of a transcript is user messages, tool results and file snapshots.
    /// On a week of them this takes 76,046 lines down to the 26,394 that carry
    /// a usage block, and it does it on bytes: the same test written as
    /// `String.contains` has to build a string per line and compare it under
    /// Unicode equivalence, for a needle that is seven ASCII characters.
    private static let usageMarker = Data("\"usage\"".utf8)

    /// One assistant turn, or nothing.
    static func turn(_ line: Data) -> (id: String, turn: ModelTurn)? {
        guard line.range(of: usageMarker) != nil,
              let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              record["type"] as? String == "assistant",
              let message = record["message"] as? [String: Any],
              let id = message["id"] as? String,
              let model = message["model"] as? String,
              let usage = message["usage"] as? [String: Any],
              let at = ClaudeSessionActivityReader.timestamp(record["timestamp"])
        else { return nil }

        // `<synthetic>` is Claude Code writing a message of its own into the
        // transcript — an expired login, a refused request — with the shape of
        // an assistant turn and none of the substance. It is not a model and it
        // did no work, so it does not get a row of its own next to ones that
        // did.
        guard !model.hasPrefix("<") else { return nil }

        let input = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
            .reduce(0) { $0 + (JSONNumber.int(usage[$1]) ?? 0) }
        let output = JSONNumber.int(usage["output_tokens"]) ?? 0
        guard input > 0 || output > 0 else { return nil }

        return (id, ModelTurn(at: at, model: model, inputTokens: input, outputTokens: output))
    }
}
