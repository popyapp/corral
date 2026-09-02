import XCTest
@testable import Corral

final class ModelUsageTests: XCTestCase {

    // ─ Reading a window back out of its own name ────────────────────────────

    /// The inverse has to be exact for every label the labeller can produce,
    /// because a breakdown that covers a different span from the limit above it
    /// is worse than no breakdown at all.
    func testEveryLabelRoundTripsBackToItsMinutes() {
        for minutes in [1, 5, 59, 60, 90, 300, 1440, 10080, 43200, 100_800] {
            let label = UsageWindow.label(minutes: minutes)
            XCTAssertEqual(UsageWindow.minutes(label: label), minutes, "round trip failed for \(label)")
        }
    }

    func testNonsenseIsNotGivenAWindow() {
        XCTAssertNil(UsageWindow.minutes(label: "Usage"))
        XCTAssertNil(UsageWindow.minutes(label: "7-fortnight"))
        XCTAssertNil(UsageWindow.minutes(label: "-1-day"))
        XCTAssertNil(UsageWindow.minutes(label: "0-day"))
        XCTAssertNil(UsageWindow.minutes(label: "day"))
    }

    // ─ Summing turns ────────────────────────────────────────────────────────

    private func turn(_ minutesAgo: Int, _ model: String, in: Int, out: Int) -> ModelTurn {
        ModelTurn(
            at: Date(timeIntervalSince1970: 1_000_000).addingTimeInterval(-Double(minutesAgo) * 60),
            model: model,
            inputTokens: `in`,
            outputTokens: out
        )
    }

    private var now: Date { Date(timeIntervalSince1970: 1_000_000) }

    func testATurnOutsideTheWindowIsNotCounted() {
        let turns = [
            turn(10, "opus", in: 100, out: 10),
            turn(400, "opus", in: 999, out: 999),
        ]
        let breakdown = ModelTally.breakdown(
            of: turns, window: "5-hour",
            since: now.addingTimeInterval(-300 * 60), observedAt: now
        )
        XCTAssertEqual(breakdown.models.count, 1)
        XCTAssertEqual(breakdown.models[0].outputTokens, 10)
        XCTAssertEqual(breakdown.models[0].inputTokens, 100)
    }

    /// Heaviest first, and ties broken by name rather than left to whatever
    /// order a dictionary hands back. A list that reshuffles itself between
    /// refreshes is unreadable while it is being read.
    func testModelsAreOrderedByOutputAndThenStably() {
        let turns = [
            turn(1, "b-model", in: 1, out: 100),
            turn(1, "a-model", in: 1, out: 100),
            turn(1, "c-model", in: 1, out: 500),
        ]
        let breakdown = ModelTally.breakdown(
            of: turns, window: "7-day",
            since: .distantPast, observedAt: now
        )
        XCTAssertEqual(breakdown.models.map(\.model), ["c-model", "a-model", "b-model"])
    }

    /// The share is of output, and says so. Input is dominated by cache reads —
    /// hundreds of millions against a couple of million produced — so a bar
    /// drawn on the total would be a bar about caching.
    func testShareIsOfOutputNotOfEverythingRead() {
        let turns = [
            turn(1, "small-output", in: 1_000_000, out: 100),
            turn(1, "big-output", in: 10, out: 300),
        ]
        let breakdown = ModelTally.breakdown(
            of: turns, window: "7-day", since: .distantPast, observedAt: now
        )
        let big = breakdown.models.first { $0.model == "big-output" }!
        XCTAssertEqual(breakdown.share(big), 0.75, accuracy: 0.0001)
        XCTAssertEqual(breakdown.totalOutput, 400)
    }

    func testAWindowWithNothingInItIsEmptyRatherThanZero() {
        let breakdown = ModelTally.breakdown(
            of: [turn(400, "opus", in: 1, out: 1)], window: "5-hour",
            since: now.addingTimeInterval(-300 * 60), observedAt: now
        )
        XCTAssertTrue(breakdown.isEmpty)
        XCTAssertEqual(breakdown.share(ModelUse(model: "x", inputTokens: 0, outputTokens: 0)), 0)
    }

    // ─ Claude: one line at a time ───────────────────────────────────────────

    private func assistant(
        id: String,
        model: String = "claude-opus-5",
        at: String = "2026-09-01T12:00:00.000Z",
        input: Int = 10,
        cacheRead: Int = 100,
        cacheWrite: Int = 5,
        output: Int = 50
    ) -> String {
        """
        {"type":"assistant","timestamp":"\(at)","message":{"id":"\(id)","model":"\(model)",\
        "usage":{"input_tokens":\(input),"cache_read_input_tokens":\(cacheRead),\
        "cache_creation_input_tokens":\(cacheWrite),"output_tokens":\(output)}}}
        """
    }

    /// Everything the model read counts, cache included — it is still context
    /// it was handed, just context nobody paid full price for twice.
    func testInputIsEverythingTheModelRead() throws {
        let found = try XCTUnwrap(ClaudeModelTally.turn(Data(assistant(id: "msg_1").utf8)))
        XCTAssertEqual(found.id, "msg_1")
        XCTAssertEqual(found.turn.inputTokens, 115)
        XCTAssertEqual(found.turn.outputTokens, 50)
        XCTAssertEqual(found.turn.model, "claude-opus-5")
    }

    /// `<synthetic>` is Claude Code writing its own message into the transcript
    /// — an expired login, a refused request. It did no work and is not a model.
    func testSyntheticMessagesAreNotAModel() {
        let line = assistant(id: "msg_2", model: "<synthetic>", input: 0, cacheRead: 0,
                             cacheWrite: 0, output: 0)
        XCTAssertNil(ClaudeModelTally.turn(Data(line.utf8)))
    }

    func testOnlyAssistantRecordsWithUsageCount() {
        let user = #"{"type":"user","timestamp":"2026-09-01T12:00:00.000Z","message":{"content":"hi"}}"#
        XCTAssertNil(ClaudeModelTally.turn(Data(user.utf8)))
        let noUsage = #"{"type":"assistant","timestamp":"2026-09-01T12:00:00.000Z","message":{"id":"m","model":"x"}}"#
        XCTAssertNil(ClaudeModelTally.turn(Data(noUsage.utf8)))
    }

    // ─ Claude: a whole directory ────────────────────────────────────────────

    private func makeCorpus(_ files: [String: [String]]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-tests-\(UUID().uuidString)")
        for (name, lines) in files {
            let dir = root.appendingPathComponent("project-\(name)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n")
                .write(to: dir.appendingPathComponent("\(name).jsonl"), atomically: true, encoding: .utf8)
        }
        return root
    }

    private func stamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    /// The finding that makes this whole file necessary. One assistant turn is
    /// written to the transcript many times: the same id, repeated — seventeen
    /// times for a single message on real data, 15,469 repeated identifiers
    /// across a week. Counting records instead of turns roughly doubles every
    /// figure, and unevenly, because how often a message repeats depends on how
    /// many tools it called.
    func testARepeatedMessageIsOneTurn() throws {
        let at = stamp(Date().addingTimeInterval(-3600))
        let repeated = Array(repeating: assistant(id: "msg_same", at: at), count: 13)
        let root = try makeCorpus(["a": repeated])
        defer { try? FileManager.default.removeItem(at: root) }

        let tally = ClaudeModelTally(root: root)
        tally.refresh()
        XCTAssertEqual(tally.turns.count, 1)
        XCTAssertEqual(tally.turns[0].outputTokens, 50)
    }

    /// And the other half: the early copies are unfinished. A message that
    /// finally produced 2,267 tokens is written sixteen times saying 4. Taking
    /// the first record seen undercounts, and undercounts differently depending
    /// on whether the file was read backwards — as the first pass does — or
    /// forwards, as every pass after it does.
    func testTheFinishedCopyOfATurnIsTheOneThatCounts() throws {
        let at = stamp(Date().addingTimeInterval(-3600))
        let growing = [4, 4, 4, 2267].map {
            assistant(id: "msg_grows", at: at, output: $0)
        }
        let root = try makeCorpus(["a": growing])
        defer { try? FileManager.default.removeItem(at: root) }

        let tally = ClaudeModelTally(root: root)
        tally.refresh()
        XCTAssertEqual(tally.turns.count, 1)
        XCTAssertEqual(tally.turns[0].outputTokens, 2267)
    }

    /// The same file must total the same however it was reached. The first pass
    /// reads backwards and sees the finished copy first; an incremental pass
    /// reads forwards and sees it last.
    func testAnUnfinishedCopyArrivingLaterDoesNotOverwriteTheFinishedOne() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-tests-\(UUID().uuidString)")
        let project = dir.appendingPathComponent("project-a")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("a.jsonl")
        defer { try? FileManager.default.removeItem(at: dir) }

        let at = stamp(Date().addingTimeInterval(-600))
        try (assistant(id: "m", at: at, output: 4) + "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let tally = ClaudeModelTally(root: dir)
        tally.refresh()
        XCTAssertEqual(tally.turns[0].outputTokens, 4)

        // The finished copy is appended, and must win.
        var handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((assistant(id: "m", at: at, output: 2267) + "\n").utf8))
        try handle.close()
        tally.refresh()
        XCTAssertEqual(tally.turns.count, 1)
        XCTAssertEqual(tally.turns[0].outputTokens, 2267)

        // And a stray unfinished copy after it must not undo that.
        handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((assistant(id: "m", at: at, output: 4) + "\n").utf8))
        try handle.close()
        tally.refresh()
        XCTAssertEqual(tally.turns.count, 1)
        XCTAssertEqual(tally.turns[0].outputTokens, 2267)
    }

    func testTurnsOlderThanTheHorizonAreDropped() throws {
        let root = try makeCorpus([
            "a": [
                assistant(id: "recent", at: stamp(Date().addingTimeInterval(-3600))),
                assistant(id: "ancient", at: stamp(Date().addingTimeInterval(-30 * 86_400))),
            ]
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let tally = ClaudeModelTally(root: root)
        tally.refresh(horizon: 7 * 86_400)
        XCTAssertEqual(tally.turns.count, 1)
    }

    /// The second pass must read only what was appended, and must not count
    /// the first pass again. Getting this wrong is invisible on a fresh launch
    /// and doubles the numbers a minute later.
    func testASecondPassCountsOnlyWhatIsNew() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-tests-\(UUID().uuidString)")
        let project = dir.appendingPathComponent("project-a")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("a.jsonl")
        defer { try? FileManager.default.removeItem(at: dir) }

        let at = stamp(Date().addingTimeInterval(-600))
        try (assistant(id: "one", at: at) + "\n").write(to: file, atomically: true, encoding: .utf8)

        let tally = ClaudeModelTally(root: dir)
        tally.refresh()
        XCTAssertEqual(tally.turns.count, 1)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((assistant(id: "two", at: at) + "\n").utf8))
        try handle.close()

        tally.refresh()
        XCTAssertEqual(tally.turns.count, 2)
        XCTAssertEqual(tally.turns.reduce(0) { $0 + $1.outputTokens }, 100)

        // And a third pass with nothing appended changes nothing.
        tally.refresh()
        XCTAssertEqual(tally.turns.count, 2)
    }

    // ─ The store, which is where the threading is ───────────────────────────

    /// The one piece that cannot be checked by reading it. The store answers on
    /// the caller's thread and counts on another, so what a reader sees before
    /// the first pass lands, and whether it ever lands, are behaviours rather
    /// than lines of code.
    func testTheStorePublishesWhatWasCountedWithoutBlockingTheCaller() throws {
        let at = stamp(Date().addingTimeInterval(-600))
        let root = try makeCorpus([
            "a": [
                assistant(id: "one", model: "claude-opus-5", at: at, output: 300),
                assistant(id: "two", model: "claude-fable-5", at: at, output: 100),
            ]
        ])
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: empty)
        }

        let store = ModelUsageStore(
            claude: ClaudeModelTally(root: root),
            codex: CodexModelTally(root: empty),
            ttl: 0
        )

        // Nothing counted yet, and asking does not block or invent a zero.
        XCTAssertFalse(store.hasCounted)
        XCTAssertTrue(store.breakdowns(for: .claudeCode).isEmpty)

        store.refresh()
        let deadline = Date().addingTimeInterval(10)
        while !store.hasCounted && Date() < deadline { usleep(20_000) }
        XCTAssertTrue(store.hasCounted, "the background pass never finished")

        let windows = store.breakdowns(for: .claudeCode)
        XCTAssertEqual(windows.map(\.window), ["5-hour", "7-day"])

        let week = try XCTUnwrap(windows.first { $0.window == "7-day" })
        XCTAssertEqual(week.models.map(\.model), ["claude-opus-5", "claude-fable-5"])
        XCTAssertEqual(week.totalOutput, 400)
        XCTAssertEqual(week.share(week.models[0]), 0.75, accuracy: 0.0001)

        // A vendor with no logs gets no rows rather than an empty gauge.
        XCTAssertTrue(store.breakdowns(for: .codex).isEmpty)
    }

    // ─ Codex ────────────────────────────────────────────────────────────────

    private func rollout(_ lines: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rollout-2026-09-01T00-00-00-abc.jsonl")
        try (lines.joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func turnContext(_ model: String) -> String {
        #"{"type":"turn_context","timestamp":"2026-09-01T12:00:00.000Z","payload":{"model":"\#(model)"}}"#
    }

    private func tokenCount(input: Int, cached: Int, output: Int) -> String {
        """
        {"type":"event_msg","timestamp":"2026-09-01T12:00:01.000Z","payload":{"type":"token_count",\
        "info":{"last_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),\
        "output_tokens":\(output),"total_tokens":\(input + output)},"model_context_window":258400}}}
        """
    }

    /// The per-turn deltas are what get summed. On both real rollouts the sum
    /// of `last_token_usage` reproduces the session's final `total_token_usage`
    /// exactly — 129,099 and 475,858 tokens — which is what makes this the
    /// right field to add up and `total_token_usage` the wrong one.
    func testCodexSumsPerTurnDeltasUnderTheModelOfThatTurn() throws {
        let file = try rollout([
            turnContext("gpt-5.6-terra"),
            tokenCount(input: 100, cached: 90, output: 10),
            tokenCount(input: 200, cached: 150, output: 20),
        ])
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let turns = CodexModelTally.scan(file)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns.map(\.model), ["gpt-5.6-terra", "gpt-5.6-terra"])
        // `input_tokens` already contains the cached portion. Adding it again
        // would count most of every turn twice.
        XCTAssertEqual(turns.reduce(0) { $0 + $1.inputTokens }, 300)
        XCTAssertEqual(turns.reduce(0) { $0 + $1.outputTokens }, 30)
    }

    /// `/model` mid-session changes the model for the turns that follow, and
    /// only those.
    func testCodexFollowsAModelChangeMidSession() throws {
        let file = try rollout([
            turnContext("gpt-5.6-terra"),
            tokenCount(input: 100, cached: 0, output: 10),
            turnContext("gpt-5.6-mini"),
            tokenCount(input: 200, cached: 0, output: 20),
        ])
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let turns = CodexModelTally.scan(file)
        XCTAssertEqual(turns.map(\.model), ["gpt-5.6-terra", "gpt-5.6-mini"])
        XCTAssertEqual(turns[1].outputTokens, 20)
    }

    /// A turn nothing names cannot be filed under a guess: a row invented for
    /// it would be indistinguishable from a real one.
    func testCodexDropsATurnItCannotAttribute() throws {
        let file = try rollout([tokenCount(input: 100, cached: 0, output: 10)])
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertTrue(CodexModelTally.scan(file).isEmpty)
    }

    // ─ Reading files backwards ──────────────────────────────────────────────

    /// A line that straddles a chunk boundary has to arrive whole. With a chunk
    /// this small every line does, which is the point.
    func testALineSpanningChunksIsStillReadWhole() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("wide.txt")
        defer { try? FileManager.default.removeItem(at: dir) }

        let lines = (0..<40).map { "line-\($0)-" + String(repeating: "x", count: 500) }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        var seen: [String] = []
        FileTail.backwards(of: file, chunk: 64) { line in
            seen.append(String(data: line, encoding: .utf8) ?? "?")
            return false
        }
        XCTAssertEqual(seen.count, 40)
        XCTAssertEqual(seen, lines.reversed())
    }

    /// Newest first, and stopping means stopping.
    func testStoppingEarlyReadsNoFurther() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("many.txt")
        defer { try? FileManager.default.removeItem(at: dir) }
        try ((0..<100).map(String.init).joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        var seen: [String] = []
        FileTail.backwards(of: file, chunk: 16) { line in
            seen.append(String(data: line, encoding: .utf8) ?? "?")
            return seen.count == 3
        }
        XCTAssertEqual(seen, ["99", "98", "97"])
    }

    /// A record still being written is left for the next call to see whole,
    /// rather than parsed as half an object and lost.
    func testAHalfWrittenLastLineIsLeftForNextTime() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("growing.txt")
        defer { try? FileManager.default.removeItem(at: dir) }

        try "one\ntwo\nthr".write(to: file, atomically: true, encoding: .utf8)
        let first = FileTail.appendedLines(to: file, after: 0)
        XCTAssertEqual(first.lines.map { String(data: $0, encoding: .utf8) }, ["one", "two"])
        XCTAssertEqual(first.next, 8)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("ee\n".utf8))
        try handle.close()

        let second = FileTail.appendedLines(to: file, after: first.next)
        XCTAssertEqual(second.lines.map { String(data: $0, encoding: .utf8) }, ["three"])
    }

    /// A file shorter than the offset was replaced, not shortened. Reading on
    /// from a position that no longer means anything would count whatever
    /// happens to sit there.
    func testATruncatedFileIsReadAgainFromTheStart() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("replaced.txt")
        defer { try? FileManager.default.removeItem(at: dir) }

        try "short\n".write(to: file, atomically: true, encoding: .utf8)
        let read = FileTail.appendedLines(to: file, after: 9_999)
        XCTAssertEqual(read.lines.map { String(data: $0, encoding: .utf8) }, ["short"])
        XCTAssertEqual(read.next, 6)
    }
}
