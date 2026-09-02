import XCTest
@testable import Corral

final class StatusLineTests: XCTestCase {

    /// The object Claude Code documents, trimmed to the fields that matter and
    /// carrying two that must never be kept.
    private let payload: [String: Any] = [
        "session_id": "abc-123",
        "cwd": "/Volumes/webroot/github/popy_app",
        "transcript_path": "/Users/someone/.claude/projects/x/abc-123.jsonl",
        "context_window": [
            "total_input_tokens": 421_000,
            "context_window_size": 1_000_000,
            "used_percentage": 42.1,
        ],
        "rate_limits": [
            "five_hour": ["used_percentage": 73, "resets_at": 1_787_999_999],
            "seven_day": ["used_percentage": 36.5, "resets_at": 1_788_500_000],
        ],
        "pr": ["number": 42, "url": "https://example.com/private"],
    ]

    // ─ Reading ──────────────────────────────────────────────────────────────

    /// The window size arrives stated. That is the whole reason this path
    /// exists: `ClaudeContext` has to prove or guess the same number.
    func testTheContextWindowArrivesStatedRatherThanInferred() {
        let context = StatusLine.context(payload)
        XCTAssertEqual(context?.used, 421_000)
        XCTAssertEqual(context?.window, 1_000_000)
    }

    func testBothLimitWindowsAreRead() {
        let limits = StatusLine.limits(payload)
        XCTAssertEqual(limits.map(\.label), ["5-hour", "7-day"])
        XCTAssertEqual(limits[0].usedFraction, 0.73, accuracy: 0.0001)
        XCTAssertEqual(limits[1].usedFraction, 0.365, accuracy: 0.0001)
        XCTAssertEqual(limits[0].resetsAt, Date(timeIntervalSince1970: 1_787_999_999))
    }

    /// Documented as present only for subscribers, and only after a session has
    /// made a request. Absent is the ordinary case on a free plan, and it is
    /// not an error — it is a row the panel does not draw.
    func testNoRateLimitsIsNotAnError() {
        var bare = payload
        bare["rate_limits"] = nil
        XCTAssertTrue(StatusLine.limits(bare).isEmpty)
        XCTAssertNotNil(StatusLine.context(bare), "the context still arrives")
    }

    func testAWindowOfZeroIsRefusedRatherThanDividedBy() {
        let broken: [String: Any] = [
            "context_window": ["total_input_tokens": 100, "context_window_size": 0],
        ]
        XCTAssertNil(StatusLine.context(broken))
    }

    // ─ What is kept ─────────────────────────────────────────────────────────

    /// The dialog that turns this on promises Corral keeps the session id, the
    /// directory, the context size and the limits — and nothing else. What
    /// arrives also describes what someone is working on: the transcript, the
    /// branch, any open pull request. This is the test that keeps that promise
    /// true when the snapshot type is next edited.
    func testNothingDescribingTheWorkIsKept() throws {
        let snapshot = StatusSnapshot(
            tool: .claudeCode,
            sessionId: payload["session_id"] as! String,
            cwd: payload["cwd"] as? String,
            contextUsed: StatusLine.context(payload)?.used,
            contextWindow: StatusLine.context(payload)?.window,
            limits: StatusLine.limits(payload),
            writtenAt: Date(timeIntervalSince1970: 1_788_000_000)
        )
        let encoded = try JSONEncoder().encode(snapshot)
        let text = String(decoding: encoded, as: UTF8.self)

        XCTAssertFalse(text.contains("transcript"), "the transcript path must not be stored")
        XCTAssertFalse(text.contains("example.com"), "the pull request must not be stored")
        XCTAssertTrue(text.contains("abc-123"))
    }

    // ─ The line itself ──────────────────────────────────────────────────────

    /// Whatever this returns becomes the user's status line, so it has to read
    /// as a line somebody wrote rather than a dump of fields.
    func testTheLineNamesTheProjectAndBothKindsOfFullness() {
        let snapshot = StatusSnapshot(
            tool: .claudeCode,
            sessionId: "abc-123",
            cwd: "/a/popy_app",
            contextUsed: 421_000,
            contextWindow: 1_000_000,
            limits: StatusLine.limits(payload),
            writtenAt: Date()
        )
        XCTAssertEqual(
            StatusLine.line(for: snapshot, cwd: "/a/popy_app"),
            "popy_app · ctx 42% · session 73% · week 37%"
        )
    }

    /// Nothing unknown is mentioned. A line reading "ctx —%" would be worse
    /// than a shorter line.
    func testUnknownFiguresAreLeftOutRatherThanShownEmpty() {
        let snapshot = StatusSnapshot(
            tool: .claudeCode,
            sessionId: "abc-123",
            cwd: "/a/popy_app",
            contextUsed: nil,
            contextWindow: nil,
            limits: [],
            writtenAt: Date()
        )
        XCTAssertEqual(StatusLine.line(for: snapshot, cwd: "/a/popy_app"), "popy_app")
    }

    // ─ Editing somebody else's settings ─────────────────────────────────────

    @MainActor
    func testInstallingLeavesTheRestOfTheFileExactlyAsItWas() throws {
        let file = try temporarySettings(#"""
        {
          "model": "opus[1m]",
          "permissions": { "allow": ["Bash(ls:*)"] }
        }
        """#)

        guard case .added = StatusLineSetup.install(.claudeCode, file: file) else {
            return XCTFail("install refused a free slot")
        }

        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("\"statusLine\""))
        // The point of editing the text rather than re-serialising: every line
        // the user wrote comes back the way they wrote it.
        XCTAssertTrue(text.contains(#""model": "opus[1m]""#))
        XCTAssertTrue(text.contains(#""permissions": { "allow": ["Bash(ls:*)"] }"#))

        let data = try XCTUnwrap(text.data(using: .utf8))
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: data), "still valid JSON")
    }

    /// A status line somebody else set up is not Corral's to take.
    @MainActor
    func testAnExistingStatusLineIsNeverOverwritten() throws {
        let file = try temporarySettings(#"""
        { "statusLine": { "type": "command", "command": "~/bin/my-prompt.sh" } }
        """#)

        guard case .taken(let existing) = StatusLineSetup.state(file: file) else {
            return XCTFail("an occupied slot should read as taken")
        }
        XCTAssertEqual(existing, "~/bin/my-prompt.sh")

        let before = try String(contentsOf: file, encoding: .utf8)
        guard case .failed = StatusLineSetup.install(.claudeCode, file: file) else {
            return XCTFail("install should refuse an occupied slot")
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), before)
    }

    @MainActor
    func testAFileThatDoesNotParseIsLeftAlone() throws {
        let file = try temporarySettings("{ this is not json")
        guard case .unreadable = StatusLineSetup.state(file: file) else {
            return XCTFail("unparseable settings should read as unreadable")
        }
        guard case .failed = StatusLineSetup.install(.claudeCode, file: file) else {
            return XCTFail("install should refuse a file it cannot parse")
        }
    }

    private func temporarySettings(_ contents: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("corral-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}

/// Two agents write into the same folder in the same shape.
///
/// Which one a snapshot came from is therefore not cosmetic: get it wrong and
/// Cursor's conversation is reported as Claude's allowance, in a panel whose
/// whole claim is that every figure is real. These are the tests that keep the
/// two apart.
final class StatusSnapshotRoutingTests: XCTestCase {

    private func snapshot(_ tool: Tool, _ session: String, limits: Bool) -> StatusSnapshot {
        StatusSnapshot(
            tool: tool,
            sessionId: session,
            cwd: "/a/project",
            contextUsed: 100_000,
            contextWindow: 200_000,
            limits: limits
                ? [.init(label: "5-hour", usedFraction: 0.5, resetsAt: nil)]
                : [],
            writtenAt: Date()
        )
    }

    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("corral-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ snapshot: StatusSnapshot, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(snapshot).write(
            to: directory.appendingPathComponent(
                "\(snapshot.tool.rawValue)-\(snapshot.sessionId).json"
            )
        )
    }

    /// A reader answers for its own tool and stays silent about the other's,
    /// even when both are sitting in the folder.
    func testOneAgentNeverAnswersForAnother() throws {
        let directory = try directory()
        try write(snapshot(.claudeCode, "s1", limits: true), to: directory)
        try write(snapshot(.cursorAgent, "s2", limits: true), to: directory)

        let claude = StatusSnapshotReader(tool: .claudeCode, directory: directory)
        let cursor = StatusSnapshotReader(tool: .cursorAgent, directory: directory)

        XCTAssertEqual(claude.usage()?.tool, .claudeCode)
        XCTAssertEqual(cursor.usage()?.tool, .cursorAgent)
        XCTAssertNotNil(claude.context(for: "s1"))
        XCTAssertNil(claude.context(for: "s2"), "that session belongs to Cursor")
        XCTAssertNil(cursor.context(for: "s1"), "that session belongs to Claude Code")
    }

    /// Two agents can hold the same session id without colliding, because the
    /// file is named by both.
    func testTheSameSessionIdFromTwoAgentsDoesNotCollide() throws {
        let directory = try directory()
        try write(snapshot(.claudeCode, "same", limits: false), to: directory)
        try write(snapshot(.cursorAgent, "same", limits: false), to: directory)

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2
        )
        for tool in [Tool.claudeCode, .cursorAgent] {
            let reader = StatusSnapshotReader(tool: tool, directory: directory)
            XCTAssertEqual(reader.snapshot(for: "same")?.tool, tool)
        }
    }

    /// Cursor sends no `rate_limits`, so there is no allowance to report — and
    /// reporting one anyway is exactly the failure this whole split prevents.
    func testAnAgentWithNoLimitsReportsNoAllowance() throws {
        let directory = try directory()
        try write(snapshot(.cursorAgent, "s1", limits: false), to: directory)
        let reader = StatusSnapshotReader(tool: .cursorAgent, directory: directory)
        XCTAssertNil(reader.usage())
        XCTAssertNotNil(reader.context(for: "s1"), "the context still arrives")
    }

    /// The flag on the command line is what decides, because the two payloads
    /// are too alike to tell apart by inspection.
    func testTheToolComesFromTheCommandLine() {
        XCTAssertEqual(StatusLine.tool(from: ["Corral", "--statusline", "cursor"]), .cursorAgent)
        XCTAssertEqual(StatusLine.tool(from: ["Corral", "--statusline", "claude"]), .claudeCode)
        // An older settings file, written before the argument existed.
        XCTAssertEqual(StatusLine.tool(from: ["Corral", "--statusline"]), .claudeCode)
    }
}

/// Upgrading must not blank the panel.
///
/// Snapshots written before there was more than one tool have no `tool` field
/// and no prefix in their name. They are Claude Code's, and they hold the only
/// copy of the account's limits until some session takes another turn.
final class StatusSnapshotLegacyTests: XCTestCase {

    func testAPreviousVersionsSnapshotIsStillRead() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("corral-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        // Exactly what the previous version wrote: no tool, no prefix.
        let legacy = """
        {"contextUsed":158760,"writtenAt":1788011854.1,"sessionId":"abc",
         "cwd":"/a/lobbyist","contextWindow":1000000,
         "limits":[{"label":"5-hour","resetsAt":1787272200,"usedFraction":0.01}]}
        """
        try legacy.write(
            to: directory.appendingPathComponent("abc.json"), atomically: true, encoding: .utf8
        )

        let claude = StatusSnapshotReader(tool: .claudeCode, directory: directory)
        XCTAssertEqual(claude.usage()?.limits.first?.usedFraction, 0.01)
        XCTAssertEqual(claude.context(for: "abc")?.windowTokens, 1_000_000)

        // And it is still not Cursor's.
        let cursor = StatusSnapshotReader(tool: .cursorAgent, directory: directory)
        XCTAssertNil(cursor.usage())
        XCTAssertNil(cursor.context(for: "abc"))
    }
}

// ─ What the Usage page says about reporting ─────────────────────────────────

/// The Reporting section states, in a sentence per tool, whether Corral is
/// being told anything. A sentence that is wrong here is worse than no
/// sentence: it is the page somebody opens precisely because they cannot tell.
final class ReportingSummaryTests: XCTestCase {

    private func target(writing contents: String?) throws -> StatusLineSetup.Target {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("settings.json")
        if let contents { try contents.write(to: file, atomically: true, encoding: .utf8) }
        return StatusLineSetup.Target(
            tool: .claudeCode, name: "Claude Code", file: file,
            argument: "claude", provides: "It would show the five-hour window."
        )
    }

    func testAnInstalledStatusLineSaysSoAndOffersNothing() throws {
        let target = try self.target(writing:
            #"{"statusLine":{"type":"command","command":"/Applications/Corral.app/Contents/MacOS/Corral --statusline claude"}}"#)
        defer { try? FileManager.default.removeItem(at: target.file.deletingLastPathComponent()) }
        XCTAssertEqual(target.summary, "Reporting through its status line.")
        XCTAssertFalse(target.canBeInstalled)
    }

    /// The only state with something to press, and the sentence carries what
    /// pressing it would get you rather than leaving that to the dialog.
    func testAnAbsentStatusLineOffersTheSetup() throws {
        let target = try self.target(writing: #"{"model":"claude-opus-5"}"#)
        defer { try? FileManager.default.removeItem(at: target.file.deletingLastPathComponent()) }
        XCTAssertTrue(target.canBeInstalled)
        XCTAssertTrue(target.summary.hasPrefix("Not set up."))
        XCTAssertTrue(target.summary.contains("five-hour window"))
    }

    /// Somebody else's status line is not a gap to fill. The sentence names it
    /// and promises not to touch it, and no button appears.
    func testAStatusLineBelongingToSomethingElseIsLeftAlone() throws {
        let target = try self.target(writing:
            #"{"statusLine":{"type":"command","command":"~/bin/my-own-prompt.sh"}}"#)
        defer { try? FileManager.default.removeItem(at: target.file.deletingLastPathComponent()) }
        XCTAssertFalse(target.canBeInstalled)
        XCTAssertTrue(target.summary.contains("my-own-prompt.sh"))
        XCTAssertTrue(target.summary.contains("will not replace"))
    }

    /// No settings file at all reads as unreadable rather than absent, and the
    /// difference matters: offering to edit a file Corral cannot parse is how
    /// somebody's configuration gets damaged.
    func testAMissingSettingsFileIsNotMistakenForAnEmptySlot() throws {
        let target = try self.target(writing: nil)
        defer { try? FileManager.default.removeItem(at: target.file.deletingLastPathComponent()) }
        XCTAssertFalse(target.canBeInstalled)
        XCTAssertTrue(target.summary.contains("settings.json"))
    }
}
