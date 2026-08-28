import CryptoKit
import Foundation

/// Reads the state of Cursor's *command line* agent.
///
/// Not the same place as the editor's, which is what
/// `CursorSessionActivityReader` reads. The CLI keeps its own store per
/// session, under `~/.cursor/chats/<md5 of the project path>/<session>/`.
///
/// This one says less than the other readers do, and the reason is worth
/// writing down so nobody goes looking again. The conversation lives in that
/// directory's `store.db` as content-addressed blobs. The messages themselves
/// are plain JSON — but they carry no timestamp and no sequence number, and the
/// index that orders them is the one blob that *is* encrypted, with a key the
/// store keeps next to it. Which message came last is therefore not something
/// this can honestly answer.
///
/// What it can answer is what the session is *about* and when it last moved,
/// both of which sit in plain sight in `meta.json` — including the working
/// directory, so the md5 is only a way to find the folder quickly and the
/// recorded path is what settles it.
struct CursorCLISessionActivityReader: SessionActivityReader {

    private let root: URL

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cursor/chats")) {
        self.root = root
    }

    /// Cursor names a project's folder after the md5 of its path.
    static func directoryName(for cwd: String) -> String {
        Insecure.MD5.hash(data: Data(cwd.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func reading(_ lookup: SessionLookup) -> SessionActivityReading? {
        let folder = root.appendingPathComponent(Self.directoryName(for: lookup.project))
        let sessions = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []

        var best: SessionActivityReading?
        for session in sessions where !lookup.claimed.contains(session.path) {
            guard let meta = Self.meta(of: session),
                  meta.cwd == lookup.project,
                  meta.updatedAt >= lookup.startedAt
            else { continue }

            let summary = meta.title ?? Self.latestPrompt(in: session) ?? "Working"
            let reading = SessionActivityReading(
                activity: SessionActivity(
                    summary: summary, at: meta.updatedAt, fromSubagent: false
                ),
                source: session.path
            )
            if best == nil || reading.activity.at > best!.activity.at { best = reading }
        }
        return best
    }

    private struct Meta {
        let cwd: String
        let title: String?
        let updatedAt: Date
    }

    private static func meta(of session: URL) -> Meta? {
        guard let data = try? Data(contentsOf: session.appendingPathComponent("meta.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cwd = object["cwd"] as? String,
              let updatedMs = object["updatedAtMs"] as? Double
        else { return nil }
        return Meta(
            cwd: cwd,
            title: (object["title"] as? String).flatMap { SessionActivity.firstLine($0) },
            updatedAt: Date(timeIntervalSince1970: updatedMs / 1000)
        )
    }

    /// The last thing the person asked for. A fallback for a session too young
    /// to have been given a title yet.
    private static func latestPrompt(in session: URL) -> String? {
        guard let data = try? Data(
            contentsOf: session.appendingPathComponent("prompt_history.json")
        ),
        let prompts = try? JSONSerialization.jsonObject(with: data) as? [String],
        let last = prompts.last
        else { return nil }
        return SessionActivity.firstLine(last)
    }
}
