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
