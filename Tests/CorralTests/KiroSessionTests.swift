import XCTest
@testable import Corral

/// Kiro CLI's session files, as they were on a real machine on 2026-09-10.
///
/// The shapes below are trimmed copies of what `kiro-cli chat` wrote after
/// one turn, and the numbers are the real ones: a 1,000,000-token window,
/// 6.6373% of it used, and a turn that cost two metering entries adding up to
/// 0.3814 credits with every token field at zero. If Kiro changes the layout,
/// this is where it shows.
final class KiroSessionTests: XCTestCase {

    private let session: [String: Any] = [
        "session_id": "a2c18799-4e78-4fc6-a107-499d9f53edb4",
        "cwd": "/Volumes/webroot/github/popy_app",
        "created_at": "2026-09-09T23:14:40.827240Z",
        "updated_at": "2026-09-09T23:18:13.570925Z",
        "title": "bana bu klasor ile ilgili bir ozet cikart",
        "session_state": [
            "conversation_metadata": [
                "user_turn_metadatas": [
                    [
                        "end_timestamp": "2026-09-09T23:17:16.411392Z",
                        "input_token_count": 0,
                        "output_token_count": 0,
                        "cache_read_input_token_count": 0,
                        "cache_write_input_token_count": 0,
                        "model": "auto",
                        "context_usage_percentage": 6.6373,
                        "final_context_usage_percentage": 6.6373,
                        "metering_usage": [
                            ["value": 0.06444776683250415, "unit": "credit", "unitPlural": "credits"],
                            ["value": 0.3170016558872305, "unit": "credit", "unitPlural": "credits"],
                        ],
                    ],
                ],
                "last_context_usage": ["percentage": 6.6373, "model_id": "auto"],
            ],
            "rts_model_state": [
                "conversation_id": "a2c18799-4e78-4fc6-a107-499d9f53edb4",
                "model_info": [
                    "model_id": "auto",
                    "context_window_tokens": 1_000_000,
                    "rate_unit": "Credit",
                ],
                "context_usage_percentage": 3.5586,
            ],
        ],
    ]

    // ─ The session file ─────────────────────────────────────────────────────

    /// Kiro writes a percentage and a window, not a count, so the count is
    /// arithmetic on the two — and the window is certain, because the file
    /// names it.
    func testContextIsThePercentageOfTheStatedWindow() throws {
        let parsed = try XCTUnwrap(KiroSessionFile.parse(session))
        let context = try XCTUnwrap(parsed.context)
        XCTAssertEqual(context.windowTokens, 1_000_000)
        XCTAssertEqual(context.usedTokens, 66_373)
        XCTAssertTrue(context.windowIsCertain)
    }

    /// Two percentages in the file, and they disagree on a real session: the
    /// model state lags the last turn. The turn's figure is the one to show.
    func testTheLastTurnsPercentageBeatsTheModelStates() throws {
        let parsed = try XCTUnwrap(KiroSessionFile.parse(session))
        XCTAssertEqual(parsed.contextPercentage ?? 0, 6.6373, accuracy: 0.0001)
    }

    func testTheModelStateIsTheFallbackWhenNoTurnHasFinished() throws {
        var bare = session
        var state = bare["session_state"] as! [String: Any]
        state["conversation_metadata"] = [:] as [String: Any]
        bare["session_state"] = state
        let parsed = try XCTUnwrap(KiroSessionFile.parse(bare))
        XCTAssertEqual(parsed.contextPercentage ?? 0, 3.5586, accuracy: 0.0001)
    }

    /// A turn is billed, not counted: every token field is zero and the cost
    /// is the sum of the metering entries in credits.
    func testATurnIsSummedInCreditsWhenTheTokensAreZero() throws {
        let parsed = try XCTUnwrap(KiroSessionFile.parse(session))
        XCTAssertEqual(parsed.turns.count, 1)
        XCTAssertEqual(parsed.turns[0].credits, 0.3814494227197347, accuracy: 0.000001)
        XCTAssertEqual(parsed.turns[0].model, "auto")

        let turn = try XCTUnwrap(parsed.modelTurns.first)
        XCTAssertEqual(turn.totalTokens, 0)
        XCTAssertFalse(turn.isSplit)
        XCTAssertEqual(turn.credits, 0.3814494227197347, accuracy: 0.000001)
    }

    /// Should a plan ever fill the token fields in, they are counted the way
    /// Claude's are — everything read, cache included — with the credits kept
    /// alongside rather than dropped.
    func testTokensAreUsedWhenAPlanWritesThem() throws {
        var filled = session
        var state = filled["session_state"] as! [String: Any]
        var metadata = state["conversation_metadata"] as! [String: Any]
        var turns = metadata["user_turn_metadatas"] as! [[String: Any]]
        turns[0]["input_token_count"] = 1_000
        turns[0]["cache_read_input_token_count"] = 9_000
        turns[0]["output_token_count"] = 250
        metadata["user_turn_metadatas"] = turns
        state["conversation_metadata"] = metadata
        filled["session_state"] = state

        let turn = try XCTUnwrap(KiroSessionFile.parse(filled)?.modelTurns.first)
        XCTAssertEqual(turn.inputTokens, 10_000)
        XCTAssertEqual(turn.outputTokens, 250)
        XCTAssertTrue(turn.isSplit)
        XCTAssertEqual(turn.credits, 0.3814494227197347, accuracy: 0.000001)
    }

    func testATurnThatCostNothingIsNotATurn() throws {
        var free = session
        var state = free["session_state"] as! [String: Any]
        var metadata = state["conversation_metadata"] as! [String: Any]
        var turns = metadata["user_turn_metadatas"] as! [[String: Any]]
        turns[0]["metering_usage"] = [] as [[String: Any]]
        metadata["user_turn_metadatas"] = turns
        state["conversation_metadata"] = metadata
        free["session_state"] = state
        XCTAssertTrue(KiroSessionFile.parse(free)?.turns.isEmpty ?? false)
    }

    /// Kiro writes six fractional digits where the other tools write three.
    func testMicrosecondTimestampsAreRead() throws {
        let date = try XCTUnwrap(KiroSessions.timestamp("2026-09-09T23:17:16.411392Z"))
        XCTAssertEqual(date.timeIntervalSince1970, 1_788_995_836.411, accuracy: 0.001)
        XCTAssertNil(KiroSessions.timestamp(nil))
        XCTAssertNil(KiroSessions.timestamp("yesterday"))
    }

    // ─ The event log ────────────────────────────────────────────────────────

    /// The three kinds of line, read from the newest. An assistant message is
    /// read from its end: thought, then spoke, then called a tool means it is
    /// running that tool.
    func testAnAssistantMessageEndsWithWhatItIsDoing() {
        let message: [String: Any] = [
            "kind": "AssistantMessage",
            "data": [
                "content": [
                    ["kind": "thinking", "data": ["text": ""]],
                    ["kind": "text", "data": "Let me look at the folder."],
                    ["kind": "toolUse", "data": ["toolUseId": "t1", "name": "read"]],
                ],
            ],
        ]
        XCTAssertEqual(KiroSessionActivityReader.summarise(message), "Running read")

        let spoke: [String: Any] = [
            "kind": "AssistantMessage",
            "data": ["content": [["kind": "text", "data": "Here is the summary.\nMore."]]],
        ]
        XCTAssertEqual(KiroSessionActivityReader.summarise(spoke), "Here is the summary.")

        let thought: [String: Any] = [
            "kind": "AssistantMessage",
            "data": ["content": [["kind": "thinking", "data": ["text": ""]], ["kind": "text", "data": ""]]],
        ]
        XCTAssertEqual(KiroSessionActivityReader.summarise(thought), "Thinking")
    }

    /// A prompt or a tool result at the end of the log means the model is
    /// working on it.
    func testAPromptOrAToolResultMeansWorking() {
        XCTAssertEqual(KiroSessionActivityReader.summarise(["kind": "Prompt"]), "Working")
        XCTAssertEqual(KiroSessionActivityReader.summarise(["kind": "ToolResults"]), "Working")
        XCTAssertNil(KiroSessionActivityReader.summarise(["kind": "Something"]))
    }

    // ─ Matching a session to a process ──────────────────────────────────────

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-kiro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(
        _ session: [String: Any], lockPid: pid_t?, lockStarted: String? = nil, in root: URL
    ) throws {
        let id = session["session_id"] as! String
        try JSONSerialization.data(withJSONObject: session)
            .write(to: root.appendingPathComponent("\(id).json"))
        let log = """
            {"version":"v1","kind":"Prompt","data":{"content":[{"kind":"text","data":"hi"}]}}
            {"version":"v1","kind":"AssistantMessage","data":{"content":[{"kind":"toolUse","data":{"name":"grep"}}]}}

            """
        try log.write(to: root.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
        if let lockPid {
            var lock: [String: Any] = ["pid": Int(lockPid)]
            if let lockStarted { lock["started_at"] = lockStarted }
            try JSONSerialization.data(withJSONObject: lock)
                .write(to: root.appendingPathComponent("\(id).lock"))
        }
    }

    /// The lock names the engine process, and the engine is in the group. That
    /// is proof, and it works for an app whose own directory is `/`.
    func testALockNamingAPidInTheGroupIsTheMatch() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(session, lockPid: 75_029, lockStarted: "2026-09-09T23:14:40.827046Z", in: root)

        let reader = KiroSessionActivityReader(root: root)
        let reading = try XCTUnwrap(reader.reading(SessionLookup(
            project: nil,
            startedAt: Date(timeIntervalSince1970: 1_788_995_638),   // 23:13:58Z
            sessionId: nil,
            claimed: [],
            pids: [74_859, 74_987, 75_026, 75_029]
        )))
        XCTAssertEqual(reading.activity.summary, "Running grep")
        XCTAssertEqual(reading.context?.usedTokens, 66_373)
        XCTAssertEqual(reading.activity.at, KiroSessions.timestamp("2026-09-09T23:18:13.570925Z"))
    }

    /// Pids are recycled. A lock from before this agent existed cannot be its
    /// lock, whatever number it happens to name.
    func testALockOlderThanTheAgentIsNotItsLock() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(session, lockPid: 75_029, lockStarted: "2026-09-01T10:00:00.000000Z", in: root)

        let reader = KiroSessionActivityReader(root: root)
        let reading = reader.reading(SessionLookup(
            project: "/somewhere/else",
            startedAt: Date(timeIntervalSince1970: 1_788_995_638),
            sessionId: nil,
            claimed: [],
            pids: [75_029]
        ))
        XCTAssertNil(reading)
    }

    /// Without a lock, the project and the clock decide, as they do for
    /// every other tool.
    func testWithoutALockTheProjectAndTheClockDecide() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(session, lockPid: nil, in: root)

        let reader = KiroSessionActivityReader(root: root)
        let matched = reader.reading(SessionLookup(
            project: "/Volumes/webroot/github/popy_app",
            startedAt: Date(timeIntervalSince1970: 1_788_995_638),
            sessionId: nil, claimed: [], pids: [1]
        ))
        XCTAssertNotNil(matched)

        let elsewhere = reader.reading(SessionLookup(
            project: "/Volumes/webroot/github/other",
            startedAt: Date(timeIntervalSince1970: 1_788_995_638),
            sessionId: nil, claimed: [], pids: [1]
        ))
        XCTAssertNil(elsewhere)

        // A process started after the session was last written cannot be
        // the one writing it.
        let tooNew = reader.reading(SessionLookup(
            project: "/Volumes/webroot/github/popy_app",
            startedAt: Date(timeIntervalSince1970: 1_789_000_000),
            sessionId: nil, claimed: [], pids: [1]
        ))
        XCTAssertNil(tooNew)
    }

    func testAClaimedSessionIsNotHandedOutTwice() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(session, lockPid: 75_029, in: root)

        let reader = KiroSessionActivityReader(root: root)
        let first = try XCTUnwrap(reader.reading(SessionLookup(
            project: nil, startedAt: .distantPast, sessionId: nil, claimed: [], pids: [75_029]
        )))
        let second = reader.reading(SessionLookup(
            project: nil, startedAt: .distantPast, sessionId: nil,
            claimed: [first.source], pids: [75_029]
        ))
        XCTAssertNil(second)
    }

    // ─ Counting credits ─────────────────────────────────────────────────────

    func testTheTallyCountsSessionsInsideTheWindowAndForgetsTheRest() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(session, lockPid: nil, in: root)

        let tally = KiroModelTally(root: root)
        // The fixture's turn ended on 2026-09-09; a week from then it counts,
        // a month from then it does not.
        tally.refresh(now: Date(timeIntervalSince1970: 1_788_995_836 + 86_400))
        XCTAssertEqual(tally.turns.count, 1)
        XCTAssertEqual(tally.turns[0].credits, 0.3814494227197347, accuracy: 0.000001)

        tally.refresh(now: Date(timeIntervalSince1970: 1_788_995_836 + 30 * 86_400))
        XCTAssertTrue(tally.turns.isEmpty)
    }

    /// And once counted, the breakdown is in credits and says so.
    func testABreakdownOfBilledTurnsIsInCredits() {
        let now = Date(timeIntervalSince1970: 1_788_995_900)
        let turns = [
            ModelTurn(at: now, model: "auto", credits: 0.3),
            ModelTurn(at: now, model: "claude-sonnet-4.6", credits: 0.9),
        ]
        let breakdown = ModelTally.breakdown(
            of: turns, window: "7-day", since: .distantPast, observedAt: now
        )
        XCTAssertTrue(breakdown.isCredits)
        XCTAssertEqual(breakdown.basis, "credits")
        XCTAssertEqual(breakdown.models.map(\.model), ["claude-sonnet-4.6", "auto"])
        XCTAssertEqual(breakdown.share(breakdown.models[0]), 0.75, accuracy: 0.0001)
        XCTAssertEqual(breakdown.totalCredits, 1.2, accuracy: 0.0001)
        XCTAssertEqual(breakdown.models[0].creditsSummary, "0.90")
    }

    /// A token breakdown is untouched by the credits field existing.
    func testATokenBreakdownStaysAboutTokens() {
        let now = Date(timeIntervalSince1970: 1_788_995_900)
        let turns = [ModelTurn(at: now, model: "claude-opus-5", inputTokens: 10, outputTokens: 5)]
        let breakdown = ModelTally.breakdown(
            of: turns, window: "7-day", since: .distantPast, observedAt: now
        )
        XCTAssertFalse(breakdown.isCredits)
        XCTAssertEqual(breakdown.basis, "output")
        XCTAssertEqual(breakdown.share(breakdown.models[0]), 1, accuracy: 0.0001)
    }

    func testCreditsReadLikeAPrice() {
        XCTAssertEqual(ModelUse.compact(credits: 0.3814), "0.38")
        XCTAssertEqual(ModelUse.compact(credits: 12.34), "12.3")
        XCTAssertEqual(ModelUse.compact(credits: 812.3), "812")
    }
}
