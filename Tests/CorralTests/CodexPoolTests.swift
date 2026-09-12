import XCTest
@testable import Corral

/// Codex can meter more than one pool, and the panel has to show each.
///
/// Its protocol names a quota with `limit_id` and `limit_name` and a turn
/// reports the pool the model it ran on draws from. So the newest turn alone
/// is not the account: a Pro-model pool read three hours ago is still live
/// (its window is five), and a cheaper model's turn since then must not hide
/// it. These fixtures are the record shape Codex writes, with the pool fields
/// its protocol defines; the machine this was written on has only ever seen
/// the default pool, which is the last test.
final class CodexPoolTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_789_000_000)
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-codex-pools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("2026/09/12"), withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func stamp(_ secondsAgo: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(-secondsAgo))
    }

    private func tokenCount(
        at: String, pool: String?, name: String? = nil, used: Double, minutes: Int
    ) -> String {
        var limits: [String: Any] = [
            "primary": ["used_percent": used, "window_minutes": minutes, "resets_at": 1_789_781_761],
            "secondary": NSNull(),
            "plan_type": "plus",
        ]
        if let pool { limits["limit_id"] = pool }
        if let name { limits["limit_name"] = name }
        let record: [String: Any] = [
            "timestamp": at,
            "type": "event_msg",
            "payload": ["type": "token_count", "rate_limits": limits],
        ]
        let data = try! JSONSerialization.data(withJSONObject: record)
        return String(decoding: data, as: UTF8.self)
    }

    private func rollout(_ lines: [String], name: String) throws {
        try (lines.joined(separator: "\n") + "\n").write(
            to: root.appendingPathComponent("2026/09/12/rollout-\(name).jsonl"),
            atomically: true, encoding: .utf8
        )
    }

    private var reader: CodexUsageReader {
        CodexUsageReader(root: root, auth: root.appendingPathComponent("no-auth.json"))
    }

    /// Both pools, the default first, the other named after itself.
    func testTheNewestReadingOfEveryPoolIsKept() throws {
        try rollout([
            tokenCount(at: stamp(3 * 3600), pool: "codex-pro", name: "GPT-5.6 Pro", used: 95, minutes: 300),
            tokenCount(at: stamp(60), pool: "codex", used: 20, minutes: 300),
        ], name: "a")

        let usage = try XCTUnwrap(reader.usage(now: now))
        XCTAssertEqual(usage.limits.map(\.pool), [nil, "GPT-5.6 Pro"])
        XCTAssertEqual(usage.limits[0].usedFraction, 0.20, accuracy: 0.0001)
        XCTAssertEqual(usage.limits[1].usedFraction, 0.95, accuracy: 0.0001)
        XCTAssertEqual(usage.observedAt.timeIntervalSince1970, now.timeIntervalSince1970 - 60, accuracy: 1)
        XCTAssertEqual(usage.plan, "plus")
    }

    /// The same pool read twice, in two files: the later reading wins.
    func testWithinAPoolTheLaterReadingWins() throws {
        try rollout([tokenCount(at: stamp(600), pool: "codex", used: 40, minutes: 300)], name: "old")
        try rollout([tokenCount(at: stamp(30), pool: "codex", used: 55, minutes: 300)], name: "new")

        let usage = try XCTUnwrap(reader.usage(now: now))
        XCTAssertEqual(usage.limits.count, 1)
        XCTAssertEqual(usage.limits[0].usedFraction, 0.55, accuracy: 0.0001)
    }

    /// A pool not heard from in longer than its own window has reset since,
    /// and its old percentage would be a bar about the past. The freshest
    /// reading stays whatever its age, because the panel dates it.
    func testAPoolOlderThanItsOwnWindowIsDropped() throws {
        try rollout([
            tokenCount(at: stamp(2 * 86_400), pool: "codex-pro", name: "GPT-5.6 Pro", used: 95, minutes: 300),
            tokenCount(at: stamp(3 * 86_400), pool: "codex", used: 20, minutes: 300),
        ], name: "a")

        let usage = try XCTUnwrap(reader.usage(now: now))
        XCTAssertEqual(usage.limits.map(\.pool), ["GPT-5.6 Pro"])
    }

    /// A pool with an id and no name is named after the model it stands in
    /// for, and failing that after its id — never left blank beside another.
    func testAnUnnamedPoolIsNamedAfterItsModelOrItsId() throws {
        try rollout([
            tokenCount(at: stamp(10), pool: "codex-spark", used: 10, minutes: 300),
            tokenCount(at: stamp(5), pool: "codex", used: 20, minutes: 300),
        ], name: "a")
        let usage = try XCTUnwrap(reader.usage(now: now))
        XCTAssertEqual(usage.limits.map(\.pool), [nil, "codex-spark"])
    }

    /// What this machine has always seen: one pool, no id at all on older
    /// records, and nothing in the panel that was not there before.
    func testTheDefaultPoolAloneReadsAsItAlwaysDid() throws {
        try rollout([tokenCount(at: stamp(60), pool: nil, used: 13, minutes: 43_200)], name: "a")
        let usage = try XCTUnwrap(reader.usage(now: now))
        XCTAssertEqual(usage.limits.count, 1)
        XCTAssertNil(usage.limits[0].pool)
        XCTAssertEqual(usage.limits[0].label, "30-day")
    }
}
