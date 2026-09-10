import Foundation

/// What Antigravity leaves readable, which is less than the others.
///
/// Its conversations are in `~/.gemini/antigravity/conversations/<id>.pb`,
/// and they are not protobuf in any sense a reader can use: the bytes are
/// uniformly random from the first one, with no header and nothing that
/// decompresses. Encrypted, and Corral does not try — so there is no context
/// figure and no token count for Antigravity, and the panel says why rather
/// than showing a gap.
///
/// Beside them sits `agyhub_summaries_proto.pb`, which is plain protobuf and
/// is the app's own list of conversations: for each, the title it gave the
/// conversation, the workspace it belongs to and when it was last written to.
/// That answers what the agent was last working on, and when. The rate limits
/// per model — what the app shows as a quota — are fetched from Google's
/// servers on demand and cached nowhere on disk.
///
/// Google has shipped the data under two names. `antigravity` is the original;
/// the updater that installs `Antigravity IDE.app` copies it to
/// `antigravity-ide`, and the language server names which one it is using on
/// its command line. Both are read and the newer record wins.
enum AntigravityData {

    static var roots: [URL] {
        let gemini = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini")
        return ["antigravity-ide", "antigravity"].map { gemini.appendingPathComponent($0) }
    }

    static let summariesFile = "agyhub_summaries_proto.pb"

    /// One conversation as the summaries file records it.
    struct Conversation: Equatable {
        let id: String
        let title: String
        let workspace: String?
        let updatedAt: Date?
    }

    /// Every conversation in a summaries file, in file order.
    ///
    /// Field numbers, read off a real file rather than a schema Google does
    /// not publish: each top-level field 1 is a record of `{1: id, 2:
    /// summary}`, and inside the summary `1` is the title, `3` the time of the
    /// last write as a `{seconds, nanos}` pair, and `9` the workspace with its
    /// `file://` URI in `1`. Anything else is stepped over.
    static func conversations(in data: Data) -> [Conversation] {
        ProtoScanner.fields(of: data).compactMap { field -> Conversation? in
            guard field.number == 1, case .bytes(let record) = field.value else { return nil }
            var id: String?
            var title: String?
            var workspace: String?
            var updated: Date?
            for part in ProtoScanner.fields(of: record) {
                switch (part.number, part.value) {
                case (1, .bytes(let raw)):
                    id = String(data: raw, encoding: .utf8)
                case (2, .bytes(let summary)):
                    for inner in ProtoScanner.fields(of: summary) {
                        switch (inner.number, inner.value) {
                        case (1, .bytes(let raw)):
                            title = String(data: raw, encoding: .utf8)
                        case (3, .bytes(let stamp)):
                            updated = timestamp(stamp)
                        case (9, .bytes(let space)):
                            for entry in ProtoScanner.fields(of: space) {
                                if entry.number == 1, case .bytes(let raw) = entry.value {
                                    workspace = String(data: raw, encoding: .utf8)
                                    break
                                }
                            }
                        default:
                            continue
                        }
                    }
                default:
                    continue
                }
            }
            guard let id, let title, !title.isEmpty else { return nil }
            return Conversation(id: id, title: title, workspace: workspace, updatedAt: updated)
        }
    }

    /// A `google.protobuf.Timestamp`: seconds in 1, nanoseconds in 2.
    private static func timestamp(_ data: Data) -> Date? {
        var seconds: UInt64?
        for field in ProtoScanner.fields(of: data) {
            if field.number == 1, case .varint(let value) = field.value { seconds = value }
        }
        guard let seconds, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// The path a `file://` workspace URI names.
    static func path(of workspace: String?) -> String? {
        guard let workspace, let url = URL(string: workspace), url.isFileURL else { return nil }
        return url.path
    }
}

/// Reads Antigravity's conversation list for the running app.
///
/// One app, one row, so there is nothing to tell apart: the most recently
/// written conversation is what the agent is doing, and the row says which
/// project it is in because the app's own working directory is `/`.
struct AntigravitySessionActivityReader: SessionActivityReader {

    private let roots: [URL]

    init(roots: [URL] = AntigravityData.roots) {
        self.roots = roots
    }

    func reading(_ lookup: SessionLookup) -> SessionActivityReading? {
        var best: (conversation: AntigravityData.Conversation, source: String)?
        for root in roots {
            let file = root.appendingPathComponent(AntigravityData.summariesFile)
            guard !lookup.claimed.contains(file.path),
                  let data = try? Data(contentsOf: file)
            else { continue }
            for conversation in AntigravityData.conversations(in: data) {
                guard let at = conversation.updatedAt else { continue }
                if best == nil || at > (best!.conversation.updatedAt ?? .distantPast) {
                    best = (conversation, file.path)
                }
            }
        }
        guard let best, let at = best.conversation.updatedAt else { return nil }

        var summary = SessionActivity.firstLine(best.conversation.title) ?? best.conversation.title
        if let path = AntigravityData.path(of: best.conversation.workspace) {
            let project = (path as NSString).lastPathComponent
            if !project.isEmpty { summary += " · in \(project)" }
        }
        return SessionActivityReading(
            activity: SessionActivity(summary: summary, at: at, fromSubagent: false),
            source: best.source,
            context: nil
        )
    }
}

// ─ Enough protobuf to read a list ───────────────────────────────────────────

/// A wire-format walk with no schema.
///
/// Protobuf without its `.proto` is still readable at the level of "field
/// number, wire type, bytes", which is all that is needed to pull three
/// strings and a timestamp out of a file. Nothing is decoded that is not
/// asked for, and a byte sequence that does not parse yields what was read
/// before it broke rather than an error — this is a nicety on a row, not a
/// contract.
enum ProtoScanner {

    enum Value: Equatable {
        case varint(UInt64)
        case fixed64(UInt64)
        case fixed32(UInt32)
        case bytes(Data)
    }

    struct Field: Equatable {
        let number: Int
        let value: Value
    }

    static func fields(of data: Data) -> [Field] {
        var result: [Field] = []
        var index = data.startIndex
        while index < data.endIndex {
            guard let tag = varint(data, &index) else { break }
            let number = Int(tag >> 3)
            guard number > 0 else { break }
            switch tag & 7 {
            case 0:
                guard let value = varint(data, &index) else { return result }
                result.append(Field(number: number, value: .varint(value)))
            case 1:
                guard data.endIndex - index >= 8 else { return result }
                let value = data[index..<index + 8].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                index += 8
                result.append(Field(number: number, value: .fixed64(value)))
            case 2:
                guard let length = varint(data, &index),
                      length <= UInt64(data.endIndex - index)
                else { return result }
                let end = index + Int(length)
                result.append(Field(number: number, value: .bytes(data[index..<end])))
                index = end
            case 5:
                guard data.endIndex - index >= 4 else { return result }
                let value = data[index..<index + 4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                index += 4
                result.append(Field(number: number, value: .fixed32(value)))
            default:
                // Groups and anything newer: no way to know their length.
                return result
            }
        }
        return result
    }

    private static func varint(_ data: Data, _ index: inout Data.Index) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.endIndex, shift < 64 {
            let byte = data[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }
}
