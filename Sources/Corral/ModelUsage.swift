import Foundation

/// What one model accounted for inside a window.
///
/// Tokens, not a percentage of anything. The distinction is the whole reason
/// this type is separate from `UsageLimit`: a limit is the vendor telling you
/// how much of your allowance is gone, and nobody outside the vendor can
/// compute that. Neither Claude nor Codex publishes an allowance per model on
/// this machine — Claude Code tracks `seven_day_opus` and `seven_day_sonnet`
/// internally but writes neither to disk nor to its status line, and Codex
/// stamps every limit it reports `limit_id: "codex"`, with no model in it at
/// all. What is on disk is what each model *did*, turn by turn, and that is
/// what this is.
struct ModelUse: Equatable, Identifiable {
    /// Exactly as the tool named it — `claude-opus-5[1m]`, `gpt-5.6-terra`.
    /// Not tidied up: the `[1m]` suffix is the difference between two models
    /// with very different windows, and shortening happens at the point of
    /// drawing, where the available width is known.
    let model: String

    /// Everything the model read, cache included. Cached tokens are still
    /// context the model was handed; they are just context nobody paid full
    /// price for twice. Zero when the source did not separate the two — see
    /// `isSplit`.
    let inputTokens: Int

    let outputTokens: Int

    /// What the work cost in total. Always meaningful; the two above are not.
    let totalTokens: Int

    /// Whether the source separated what was read from what was produced.
    ///
    /// Codex's newer session store keeps one figure per thread — `tokens_used`,
    /// with no split anywhere in any of its databases — so a breakdown built
    /// from it can only honestly be about totals. Rather than put a total in
    /// the output field and let a bar labelled "output" draw it, that fact
    /// travels with the number and the caption changes to match.
    let isSplit: Bool

    init(model: String, inputTokens: Int, outputTokens: Int) {
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = inputTokens + outputTokens
        self.isSplit = true
    }

    init(model: String, totalTokens: Int) {
        self.model = model
        self.inputTokens = 0
        self.outputTokens = 0
        self.totalTokens = totalTokens
        self.isSplit = false
    }

    var id: String { model }

    /// The part of the name that tells you which model this is.
    ///
    /// Only the vendor prefix comes off, and only because the list it appears
    /// in is already headed by the vendor. Nothing else is trimmed: the date in
    /// `claude-opus-4-5-20251101` and the `[1m]` in `claude-opus-5[1m]` are the
    /// differences between one model and another, not decoration — a view too
    /// narrow to show them should truncate in the middle and keep both ends,
    /// rather than have this hand it something already shortened wrongly.
    var shortName: String {
        for prefix in ["claude-", "gpt-", "codex-"] where model.hasPrefix(prefix) {
            return String(model.dropFirst(prefix.count))
        }
        return model
    }

    /// Rounded to the unit a person reads at a glance. Exact counts belong in
    /// the tooltip, where there is room to be exact.
    var outputSummary: String { ModelUse.compact(outputTokens) }
    var inputSummary: String { ModelUse.compact(inputTokens) }

    static func compact(_ value: Int) -> String {
        switch value {
        case 1_000_000...: return String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...: return String(format: "%.0fk", Double(value) / 1_000)
        default: return "\(value)"
        }
    }
}

/// One turn, as some tool wrote it down.
///
/// The intermediate form both vendors are reduced to before anything is
/// counted, so the windowing and the sorting are written once and tested
/// against fixtures rather than against whatever is on the machine today.
struct ModelTurn: Equatable {
    let at: Date
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    /// See `ModelUse.isSplit`.
    let isSplit: Bool

    init(at: Date, model: String, inputTokens: Int, outputTokens: Int) {
        self.at = at
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = inputTokens + outputTokens
        self.isSplit = true
    }

    /// For a source that reports one figure for a whole session rather than a
    /// split, and attributes it to the moment the session was last touched.
    init(at: Date, model: String, totalTokens: Int) {
        self.at = at
        self.model = model
        self.inputTokens = 0
        self.outputTokens = 0
        self.totalTokens = totalTokens
        self.isSplit = false
    }
}

/// Who did the work behind one of the account's windows.
///
/// Deliberately shaped to sit under a `UsageLimit` with the same `window`
/// string, because that is the only comparison that means anything: "your
/// 7-day allowance is 61% gone, and here is which models spent it". Shares are
/// of tokens observed locally, never of the allowance — the vendors weight
/// models against each other in ways nothing here can see, so a model with 40%
/// of the tokens has not necessarily taken 40% of the limit, and this type
/// never claims it has.
struct ModelBreakdown: Equatable {
    /// The same vocabulary `UsageLimit.label` uses: "5-hour", "7-day".
    let window: String

    /// Heaviest first.
    let models: [ModelUse]

    /// When Corral read the logs. Unlike a limit — which is as old as the last
    /// turn the tool took — this is a live reading, because it is computed from
    /// the transcripts rather than copied out of a figure the tool cached.
    let observedAt: Date

    /// True only when every turn behind this reported a split. One unsplit
    /// source drags the whole breakdown down to totals, because a mixture would
    /// otherwise be added up as if it were one kind of number.
    let isSplit: Bool

    var isEmpty: Bool { models.isEmpty }

    var totalOutput: Int { models.reduce(0) { $0 + $1.outputTokens } }
    var totalInput: Int { models.reduce(0) { $0 + $1.inputTokens } }
    var totalTokens: Int { models.reduce(0) { $0 + $1.totalTokens } }

    /// The word for what the bars are shares of.
    var basis: String { isSplit ? "output" : "tokens" }

    /// A model's share of this window.
    ///
    /// Output when the source separates it, because input is dominated by cache
    /// reads — on the machine this was written on, 621 million cached tokens
    /// against 2.7 million produced ones — and a bar drawn on the total would
    /// be a bar about caching. When there is no split to be had, the total is
    /// the only honest denominator, and `basis` says so.
    func share(_ use: ModelUse) -> Double {
        let whole = isSplit ? totalOutput : totalTokens
        guard whole > 0 else { return 0 }
        return Double(isSplit ? use.outputTokens : use.totalTokens) / Double(whole)
    }
}

// ─ Turning turns into a breakdown ───────────────────────────────────────────

enum ModelTally {

    /// Sums the turns inside a window, one row per model.
    ///
    /// Sorted by output and then by name: ties would otherwise reorder
    /// themselves between refreshes, and a list that reshuffles while being
    /// read is worse than one in a slightly arbitrary order.
    static func breakdown(
        of turns: [ModelTurn],
        window: String,
        since: Date,
        observedAt: Date
    ) -> ModelBreakdown {
        var input: [String: Int] = [:]
        var output: [String: Int] = [:]
        var total: [String: Int] = [:]
        var split = true
        for turn in turns where turn.at >= since {
            input[turn.model, default: 0] += turn.inputTokens
            output[turn.model, default: 0] += turn.outputTokens
            total[turn.model, default: 0] += turn.totalTokens
            if !turn.isSplit { split = false }
        }
        let models = total.keys.map { model in
            split
                ? ModelUse(
                    model: model,
                    inputTokens: input[model] ?? 0,
                    outputTokens: output[model] ?? 0
                )
                : ModelUse(model: model, totalTokens: total[model] ?? 0)
        }
        // Ordered by whatever the bars are shares of, so the longest bar is
        // always the top row. Sorting a split breakdown by total would sort it
        // by cache reads, which is the one thing the bar deliberately is not
        // about.
        .sorted {
            let a = split ? $0.outputTokens : $0.totalTokens
            let b = split ? $1.outputTokens : $1.totalTokens
            return a != b ? a > b : $0.model < $1.model
        }
        return ModelBreakdown(
            window: window, models: models, observedAt: observedAt, isSplit: split
        )
    }
}

// ─ Reading a window back out of its own name ────────────────────────────────

extension UsageWindow {

    /// The inverse of `label(minutes:)`, for every label that function can
    /// produce.
    ///
    /// The breakdown has to cover the same span as the limit it sits under, and
    /// a limit carries its window as the label rather than as a number —
    /// `StatusSnapshot.Window` is written to disk, so widening it would mean
    /// every snapshot already on a user's machine decoding short a field on the
    /// next upgrade. Inverting a total function we own costs nothing and
    /// changes no file format.
    static func minutes(label: String) -> Int? {
        // Empty pieces kept, so a leading separator is a parse failure rather
        // than something `split` quietly steps over: with them omitted,
        // "-1-day" comes back as ["1", "day"] and reads as a day.
        let parts = label.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let count = Int(parts[0]), count > 0 else { return nil }

        let minutes: Int
        switch parts[1] {
        case "day": minutes = count * 1440
        case "hour": minutes = count * 60
        case "minute": minutes = count
        default: return nil
        }

        // The claim being made is "the inverse of `label(minutes:)`", so the
        // answer is only accepted if it would print itself back. That rejects
        // "60-minute" — which is an hour, and which the labeller would never
        // write — and it makes this true by construction rather than by
        // having thought of every way a string can be malformed.
        return label == self.label(minutes: minutes) ? minutes : nil
    }
}
