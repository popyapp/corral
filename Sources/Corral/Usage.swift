import Foundation

/// How much of an account's allowance is gone, and when it comes back.
///
/// This is the budget behind the tool, not the budget inside a conversation:
/// it is shared by every session of that tool, it is spent by the machine you
/// were using yesterday as much as this one, and it refills on a clock.
struct UsageLimit: Equatable {
    /// The window in the tool's own terms — "5-hour", "30-day".
    let label: String

    /// 0…1 in ordinary use, and deliberately not clamped. A tool reporting past
    /// 100% is telling you the one thing you actually needed to know today, so
    /// rounding it down to "full" would throw that away. Bars clamp where they
    /// draw; the number keeps what it was given.
    let usedFraction: Double

    let resetsAt: Date?

    /// The same figure as a count, when the vendor gave one.
    ///
    /// Claude and Codex report a percentage and nothing else; Kiro reports
    /// credits used against a plan of so many. "312 of 500 credits left" is
    /// what a person plans around, and a percentage of it would be throwing
    /// the better number away.
    var quantity: UsageQuantity? = nil
}

/// A used-of-limit pair in the vendor's own unit.
struct UsageQuantity: Equatable {
    let used: Double
    let limit: Double
    let unit: String

    var remaining: Double { max(0, limit - used) }

    /// Whole numbers for whole counts, one decimal otherwise.
    static func format(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    /// "312 of 500 credits left", or "none left" past the end.
    var remainingText: String {
        remaining <= 0
            ? "none left"
            : "\(Self.format(remaining)) of \(Self.format(limit)) \(unit) left"
    }
}

/// How full one session's context window is.
///
/// A neighbouring number to a rate limit and a completely different problem. A
/// limit is the account resting until a clock comes round; a context window is
/// this conversation filling up now, and compacting it does nothing for the
/// limit while waiting out the limit does nothing for it. They are never given
/// the same label for that reason.
struct ContextUse: Equatable {
    let usedTokens: Int
    let windowTokens: Int

    /// Whether `windowTokens` was proved by the transcript or inferred from
    /// configuration. See `ClaudeContext.window` for why the difference is real
    /// and why it is only ever allowed to matter at the empty end of the bar.
    let windowIsCertain: Bool

    var fraction: Double {
        guard windowTokens > 0 else { return 0 }
        return Double(usedTokens) / Double(windowTokens)
    }
}

/// Everything a tool will tell us about the account behind it.
struct ToolUsage: Equatable {
    let tool: Tool
    let limits: [UsageLimit]

    /// The plan the tool recorded, when it recorded one.
    let plan: String?

    /// When the *tool* wrote this down — not when Corral read it.
    ///
    /// The whole reason this field exists. These figures are a by-product of
    /// the last turn an agent took, so a tool you last ran nine days ago
    /// reports a nine-day-old percentage. Shown bare it reads as current, which
    /// would be the app volunteering something untrue on its own initiative;
    /// every view of a limit carries this next to it.
    let observedAt: Date
}

/// Everything known about one vendor, which is the unit the rail shows.
///
/// A vendor rather than a tool, because the allowance belongs to the account:
/// Claude Code and the Claude desktop app spend the same budget. The
/// conversations underneath are still per agent, and stay that way.
struct VendorUsage: Identifiable {
    /// A representative tool, for the icon and the colour.
    let tool: Tool
    let account: ToolUsage?
    let sessions: [(group: AgentGroup, use: ContextUse)]

    /// Which models did the spending, per window.
    ///
    /// A companion to `account`, never a decomposition of it. The limits above
    /// are the vendor's own arithmetic over an allowance nothing here can see;
    /// these are tokens counted off this machine's transcripts. They answer
    /// different questions and the panel is required to keep them apart.
    var breakdowns: [ModelBreakdown] = []

    var id: String { tool.vendor }
    var name: String { tool.vendor }

    var hasSomethingToShow: Bool { account != nil || !sessions.isEmpty }

    /// The number in the ring.
    ///
    /// The account's tightest window when the tool records one, and the fullest
    /// conversation when it does not. Those are different measurements, which
    /// is why the ring is never shown without the label under it saying which
    /// one you are looking at.
    var fraction: Double {
        if let limits = account?.limits.map(\.usedFraction).max() { return limits }
        return sessions.map(\.use.fraction).max() ?? 0
    }

    /// What that number is, in three or four words.
    var headline: String {
        if let limit = account?.limits.max(by: { $0.usedFraction < $1.usedFraction }) {
            return limit.label
        }
        return "context"
    }
}

/// Reads one tool's account usage off disk.
///
/// Same contract as `SessionActivityReader`: cheap enough to call on a refresh,
/// and silent rather than throwing. A figure we cannot read is a figure we do
/// not show, not an error the user has to deal with.
protocol UsageReader {
    func usage() -> ToolUsage?
}

// ─ Naming a window ──────────────────────────────────────────────────────────

enum UsageWindow {

    /// A span in minutes, as the tools themselves name it: 300 is the five-hour
    /// window, 10080 the week, 43200 the month.
    ///
    /// Anything that does not divide evenly falls back to the next unit down
    /// rather than rounding, because "1-day" for 25 hours is the kind of small
    /// lie that makes someone plan around the wrong reset.
    static func label(minutes: Int) -> String {
        guard minutes > 0 else { return "Usage" }
        if minutes % 1440 == 0 { return "\(minutes / 1440)-day" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
        return "\(minutes)-minute"
    }
}

// ─ Reading numbers out of JSON ──────────────────────────────────────────────

/// `JSONSerialization` hands back `NSNumber`, which bridges to whichever of
/// `Int` and `Double` you ask for — but only if you ask for the one it happens
/// to be holding. A percentage arrives as `13` on one turn and `13.5` on the
/// next, so every numeric field here goes through these.
enum JSONNumber {
    static func double(_ raw: Any?) -> Double? { (raw as? NSNumber)?.doubleValue }
    static func int(_ raw: Any?) -> Int? { (raw as? NSNumber)?.intValue }
}
