import XCTest
@testable import Corral

final class UsageTests: XCTestCase {

    // ─ Naming a window ──────────────────────────────────────────────────────

    /// The three spans the tools actually use, in the words a person would use
    /// back. 43200 minutes is the one worth pinning: read as hours it is "720",
    /// which is true and useless.
    func testWindowsAreNamedInTheLargestUnitTheyDivideInto() {
        XCTAssertEqual(UsageWindow.label(minutes: 300), "5-hour")
        XCTAssertEqual(UsageWindow.label(minutes: 10080), "7-day")
        XCTAssertEqual(UsageWindow.label(minutes: 43200), "30-day")
    }

    /// A span that does not divide evenly drops a unit rather than rounding.
    /// "1-day" for twenty-five hours is the kind of small lie someone plans
    /// their afternoon around.
    func testAnUnevenWindowFallsToTheUnitBelowRatherThanRounding() {
        XCTAssertEqual(UsageWindow.label(minutes: 1500), "25-hour")
        XCTAssertEqual(UsageWindow.label(minutes: 90), "90-minute")
        XCTAssertEqual(UsageWindow.label(minutes: 0), "Usage")
    }

    // ─ Codex ────────────────────────────────────────────────────────────────

    /// The exact shape read off a real rollout on 2026-08-20. If Codex changes
    /// it, this is where we find out rather than in a panel showing 0%.
    private let realRateLimits: [String: Any] = [
        "limit_id": "codex",
        "primary": [
            "used_percent": 13.0,
            "window_minutes": 43200,
            "resets_at": 1_789_781_761,
        ],
        "secondary": NSNull(),
        "plan_type": "free",
    ]

    func testCodexLimitsAreReadFromTheShapeItActuallyWrites() {
        let limits = CodexUsageReader.limits(from: realRateLimits)
        XCTAssertEqual(limits.count, 1)
        XCTAssertEqual(limits[0].label, "30-day")
        XCTAssertEqual(limits[0].usedFraction, 0.13, accuracy: 0.0001)
        XCTAssertEqual(limits[0].resetsAt, Date(timeIntervalSince1970: 1_789_781_761))
    }

    /// A plan that meters a burst window reports both. The short one is listed
    /// first because it is the one that stops you today.
    func testTheShorterWindowIsListedFirst() {
        var raw = realRateLimits
        raw["secondary"] = ["used_percent": 73, "window_minutes": 300, "resets_at": 1_789_781_761]
        let limits = CodexUsageReader.limits(from: raw)
        XCTAssertEqual(limits.map(\.label), ["5-hour", "30-day"])
        XCTAssertEqual(limits[0].usedFraction, 0.73, accuracy: 0.0001)
    }

    /// JSONSerialization hands back whichever of Int and Double the file
    /// happened to contain, and a percentage arrives as both. Reading it one
    /// way silently drops half the turns.
    func testAPercentageIsReadWhetherItArrivesWholeOrFractional() {
        for value in [13 as Any, 13.5 as Any] {
            let raw: [String: Any] = [
                "primary": ["used_percent": value, "window_minutes": 300],
            ]
            XCTAssertEqual(CodexUsageReader.limits(from: raw).count, 1, "\(value)")
        }
    }

    /// An entry with no window in it is not a reading of zero. Reporting it as
    /// one would draw an empty gauge that looks like good news.
    func testAnEntryWithNoWindowIsNotAUsageOfZero() {
        XCTAssertTrue(CodexUsageReader.limits(from: ["primary": NSNull()]).isEmpty)
        XCTAssertTrue(CodexUsageReader.limits(from: [:]).isEmpty)
    }

    /// The context figure is the last turn's input, not the session's running
    /// total — that one climbs past the window inside an hour and would show
    /// every long session as permanently over.
    func testCodexContextIsTheLastTurnRatherThanTheSessionTotal() {
        let payload: [String: Any] = [
            "type": "token_count",
            "info": [
                "total_token_usage": ["input_tokens": 473_847, "total_tokens": 475_858],
                "last_token_usage": ["input_tokens": 43_854, "total_tokens": 43_885],
                "model_context_window": 258_400,
            ],
        ]
        let use = CodexContext.use(payload)
        XCTAssertEqual(use?.usedTokens, 43_854)
        XCTAssertEqual(use?.windowTokens, 258_400)
        XCTAssertEqual(use?.windowIsCertain, true)
    }

    func testCodexContextIsAbsentWithoutAStatedWindow() {
        let payload: [String: Any] = [
            "info": ["last_token_usage": ["input_tokens": 100]],
        ]
        XCTAssertNil(CodexContext.use(payload))
    }

    /// The plan comes from the sign-in, not from the last turn.
    ///
    /// A real account upgraded from free to Plus read "free" for two days,
    /// because the newest rollout was from before and Codex had not been run
    /// since. The identity token in auth.json knew the same day.
    func testThePlanIsReadFromTheSignInRatherThanTheLastTurn() throws {
        // A JWT with the one claim that matters, unsigned — the reader does
        // not verify it, so the signature can be anything.
        let payload = #"{"https://api.openai.com/auth":{"chatgpt_plan_type":"plus","chatgpt_account_id":"x"}}"#
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "eyJhbGciOiJSUzI1NiJ9.\(encoded).sig"
        XCTAssertEqual(CodexAccount.plan(inIdentityToken: token), "plus")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-codex-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let auth = dir.appendingPathComponent("auth.json")
        try #"{"auth_mode":"chatgpt","tokens":{"id_token":"\#(token)","refresh_token":"never-read"}}"#
            .write(to: auth, atomically: true, encoding: .utf8)
        XCTAssertEqual(CodexAccount.plan(in: auth), "plus")

        XCTAssertNil(CodexAccount.plan(in: dir.appendingPathComponent("missing.json")))
        XCTAssertNil(CodexAccount.plan(inIdentityToken: "not.a.jwt"))
        XCTAssertNil(CodexAccount.plan(inIdentityToken: "eyJ.\(encoded)"))
    }

    // ─ Claude Code ──────────────────────────────────────────────────────────

    /// Everything the model read is in the window, cache included — the cached
    /// part is context nobody paid full price for twice, not context that is
    /// somehow not there. Output is excluded: it reaches the window on the next
    /// turn, inside the input figure.
    func testClaudeContextCountsBothCacheFiguresAndNotOutput() {
        let record: [String: Any] = [
            "message": [
                "usage": [
                    "input_tokens": 2,
                    "cache_read_input_tokens": 290_832,
                    "cache_creation_input_tokens": 510,
                    "output_tokens": 616,
                ],
            ],
        ]
        XCTAssertEqual(ClaudeContext.tokens(in: record), 291_344)
    }

    func testClaudeContextIsAbsentWhenNothingWasCounted() {
        XCTAssertNil(ClaudeContext.tokens(in: ["message": ["usage": [:] as [String: Any]]]))
        XCTAssertNil(ClaudeContext.tokens(in: ["message": [:] as [String: Any]]))
    }

    /// A turn already past 200K proves the larger window on its own. This is
    /// the case that has to come first: a real session on this machine sat at
    /// 383K while `message.model` still read `claude-opus-5`, and taking the
    /// model at its word would have drawn a bar at 191% of its own track.
    func testATurnPastTheStandardWindowProvesTheLargerOne() {
        let window = ClaudeContext.window(observedMax: 383_256, configuredModel: { nil })
        XCTAssertEqual(window.tokens, ClaudeContext.largeWindow)
        XCTAssertTrue(window.certain)
    }

    /// Evidence outranks configuration, and settings are not even opened once
    /// the transcript has settled it.
    func testProofSkipsTheSettingsFileEntirely() {
        var opened = false
        _ = ClaudeContext.window(observedMax: 383_256, configuredModel: {
            opened = true
            return nil
        })
        XCTAssertFalse(opened)
    }

    /// Below 200K there is nothing to prove it either way, so the configured
    /// model is the best guess available — and it is marked as a guess, because
    /// a session started with `--model` would defeat it.
    func testBelowTheStandardWindowTheConfiguredModelDecidesButIsNotCertain() {
        let large = ClaudeContext.window(observedMax: 50_000, configuredModel: { "opus[1m]" })
        XCTAssertEqual(large.tokens, ClaudeContext.largeWindow)
        XCTAssertFalse(large.certain)

        let standard = ClaudeContext.window(observedMax: 50_000, configuredModel: { "opus" })
        XCTAssertEqual(standard.tokens, ClaudeContext.standardWindow)
        XCTAssertFalse(standard.certain)
    }

    func testAnUnreadableSettingsFileFallsToTheStandardWindow() {
        let missing = URL(fileURLWithPath: "/nonexistent/settings.json")
        XCTAssertNil(ClaudeContext.configuredModel(settings: missing))
        XCTAssertEqual(
            ClaudeContext.window(observedMax: 0, configuredModel: { nil }).tokens,
            ClaudeContext.standardWindow
        )
    }

    // ─ Reporting it ─────────────────────────────────────────────────────────

    /// A fraction is not clamped on the way in. A tool saying it is past its
    /// limit is saying the one thing worth interrupting someone for, and
    /// rounding it to "full" is how that gets lost.
    func testBeingOverALimitSurvivesBeingRecorded() {
        let raw: [String: Any] = ["primary": ["used_percent": 103.4, "window_minutes": 300]]
        XCTAssertEqual(CodexUsageReader.limits(from: raw)[0].usedFraction, 1.034, accuracy: 0.0001)
    }

    func testAContextUseWithNoWindowReadsAsEmptyRatherThanDividingByZero() {
        let use = ContextUse(usedTokens: 1000, windowTokens: 0, windowIsCertain: false)
        XCTAssertEqual(use.fraction, 0)
    }
}
