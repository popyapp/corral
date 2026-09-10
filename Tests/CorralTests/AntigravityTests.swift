import XCTest
@testable import Corral

/// Antigravity's conversation list, decoded without its schema.
///
/// The bytes below are built the way the app builds them — field 1 a record,
/// inside it the id and a summary, inside that the title, a timestamp and a
/// workspace — so the field numbers this reader relies on are pinned here
/// rather than only in a comment.
final class AntigravityTests: XCTestCase {

    // ─ Building protobuf by hand ────────────────────────────────────────────

    private func varint(_ value: UInt64) -> Data {
        var value = value
        var out = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value > 0 { byte |= 0x80 }
            out.append(byte)
        } while value > 0
        return out
    }

    private func field(_ number: Int, varint value: UInt64) -> Data {
        varint(UInt64(number << 3)) + varint(value)
    }

    private func field(_ number: Int, bytes: Data) -> Data {
        varint(UInt64(number << 3 | 2)) + varint(UInt64(bytes.count)) + bytes
    }

    private func field(_ number: Int, string: String) -> Data {
        field(number, bytes: Data(string.utf8))
    }

    private func record(
        id: String, title: String, updated: UInt64, workspace: String?
    ) -> Data {
        var summary = field(1, string: title)
            + field(2, varint: 337)
            + field(3, bytes: field(1, varint: updated) + field(2, varint: 112_542_000))
            + field(7, bytes: field(1, varint: updated - 3_600))
        if let workspace {
            summary += field(9, bytes: field(1, string: workspace) + field(2, string: workspace) + field(4, string: "main"))
        }
        summary += field(22, varint: 4)
        return field(1, bytes: field(1, string: id) + field(2, bytes: summary))
    }

    // ─ Reading it back ──────────────────────────────────────────────────────

    func testConversationsComeBackWithTitleTimeAndWorkspace() {
        let data = record(
            id: "31a7b8fc-e2e9-42f1-8687-24ed6edf59f6",
            title: "Changing App Icon",
            updated: 1_764_101_214,
            workspace: "file:///Volumes/webroot/github/startupdeal-innovation-mobile"
        ) + record(
            id: "1b4d1a35-355b-454a-876b-7982e44257ff",
            title: "Xcode Module Not Found",
            updated: 1_764_634_905,
            workspace: nil
        )

        let conversations = AntigravityData.conversations(in: data)
        XCTAssertEqual(conversations.count, 2)
        XCTAssertEqual(conversations[0].title, "Changing App Icon")
        XCTAssertEqual(conversations[0].updatedAt, Date(timeIntervalSince1970: 1_764_101_214))
        XCTAssertEqual(
            AntigravityData.path(of: conversations[0].workspace),
            "/Volumes/webroot/github/startupdeal-innovation-mobile"
        )
        XCTAssertEqual(conversations[1].title, "Xcode Module Not Found")
        XCTAssertNil(conversations[1].workspace)
    }

    /// The bytes of a conversation file itself — random from the first one —
    /// must come back as nothing rather than as garbage with a title.
    func testEncryptedBytesYieldNothing() {
        var noise = Data()
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for _ in 0..<4096 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            noise.append(UInt8(truncatingIfNeeded: seed >> 56))
        }
        XCTAssertTrue(AntigravityData.conversations(in: noise).isEmpty)
    }

    func testATruncatedFileGivesUpWhatItReadBeforeTheBreak() {
        let whole = record(id: "a", title: "First", updated: 1_764_101_214, workspace: nil)
            + record(id: "b", title: "Second", updated: 1_764_101_300, workspace: nil)
        let cut = whole.prefix(whole.count - 5)
        let conversations = AntigravityData.conversations(in: Data(cut))
        XCTAssertEqual(conversations.map(\.title), ["First"])
    }

    // ─ The reader ───────────────────────────────────────────────────────────

    func testTheNewestConversationIsWhatTheAppIsDoing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-antigravity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let data = record(
            id: "old", title: "Older work", updated: 1_764_101_214,
            workspace: "file:///Users/someone/code/api"
        ) + record(
            id: "new", title: "Qdrant Migration Error", updated: 1_788_996_000,
            workspace: "file:///Volumes/webroot/github/qdrant-migrate"
        )
        try data.write(to: root.appendingPathComponent(AntigravityData.summariesFile))

        let reader = AntigravitySessionActivityReader(roots: [root])
        let reading = try XCTUnwrap(reader.reading(SessionLookup(
            project: nil, startedAt: .distantPast, sessionId: nil, claimed: [], pids: [1]
        )))
        XCTAssertEqual(reading.activity.summary, "Qdrant Migration Error · in qdrant-migrate")
        XCTAssertEqual(reading.activity.at, Date(timeIntervalSince1970: 1_788_996_000))
        XCTAssertNil(reading.context, "conversations are encrypted; no context is ever claimed")
    }

    func testAMissingListIsNotAnError() {
        let reader = AntigravitySessionActivityReader(roots: [URL(fileURLWithPath: "/nonexistent")])
        XCTAssertNil(reader.reading(SessionLookup(
            project: nil, startedAt: .distantPast, sessionId: nil, claimed: [], pids: []
        )))
    }
}
