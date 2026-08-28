import Foundation
import SQLite3

/// Reads Cursor's agent state.
///
/// Cursor does not append to a log. It keeps its conversations in the SQLite
/// database the editor uses for everything else, under
/// `…/Cursor/User/globalStorage/state.vscdb`, as `composerData:<id>` rows in a
/// `cursorDiskKV` table.
///
/// Two consequences worth knowing before changing anything here:
///
///  * The file is open and being written by a running editor. It is opened
///    read-only, through a URI, with a short busy timeout — Corral must never
///    be the reason someone's editor stalls.
///
///  * The schema is undocumented and moves. The key names say so themselves:
///    `subagents.v3`, `slashMenuItems.v7`. Fields appeared and disappeared
///    between two reads seconds apart while this was being written. Everything
///    below is optional and a miss returns nil rather than failing.
struct CursorSessionActivityReader: SessionActivityReader {

    private let database: URL

    init(database: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")) {
        self.database = database
    }

    func reading(_ lookup: SessionLookup) -> SessionActivityReading? {
        var best: SessionActivityReading?
        for value in composerRows() {
            guard let data = value.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Self.projectPath(row) == lookup.project,
                  let id = row["composerId"] as? String, !lookup.claimed.contains(id),
                  let at = Self.updatedAt(row),
                  let summary = Self.summarise(row)
            else { continue }
            if best == nil || at > best!.activity.at {
                best = SessionActivityReading(
                    activity: SessionActivity(summary: summary, at: at, fromSubagent: false),
                    source: id
                )
            }
        }
        return best
    }

    /// Cursor records the workspace as a file URI on the conversation itself,
    /// so no hash has to be resolved back to a folder.
    static func projectPath(_ row: [String: Any]) -> String? {
        guard let workspace = row["workspaceIdentifier"] as? [String: Any],
              let uri = workspace["uri"] as? [String: Any]
        else { return nil }
        return (uri["fsPath"] as? String) ?? (uri["path"] as? String)
    }

    /// Cursor writes its own one-line description of the last step — literally
    /// the sentence we would otherwise have to compose ourselves — and falls
    /// back to the conversation's title.
    static func summarise(_ row: [String: Any]) -> String? {
        if !(row["generatingBubbleIds"] as? [Any] ?? []).isEmpty {
            if let subtitle = (row["subtitle"] as? String).flatMap({ SessionActivity.firstLine($0) }) {
                return subtitle
            }
            return "Working"
        }
        if let subtitle = (row["subtitle"] as? String).flatMap({ SessionActivity.firstLine($0) }) {
            return subtitle
        }
        return (row["name"] as? String).flatMap { SessionActivity.firstLine($0) }
    }

    static func updatedAt(_ row: [String: Any]) -> Date? {
        guard let ms = row["lastUpdatedAt"] as? Double ?? (row["createdAt"] as? Double) else {
            return nil
        }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    // ─ SQLite ───────────────────────────────────────────────────────────────

    private func composerRows() -> [String] {
        guard FileManager.default.fileExists(atPath: database.path) else { return [] }

        var handle: OpaquePointer?
        let uri = "file:\(database.path)?mode=ro"
        guard sqlite3_open_v2(
            uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil
        ) == SQLITE_OK, let handle else {
            if handle != nil { sqlite3_close_v2(handle) }
            return []
        }
        defer { sqlite3_close_v2(handle) }
        // The editor is writing to this file. Wait a moment for a checkpoint,
        // then give up — a missing line is nothing, a stalled refresh is not.
        sqlite3_busy_timeout(handle, 50)

        var statement: OpaquePointer?
        let sql = "select value from cursorDiskKV where key like 'composerData:%'"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                rows.append(String(cString: text))
            }
        }
        return rows
    }
}
