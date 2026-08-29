import Foundation

/// Claude Code's own record of which session a process is running.
///
/// It keeps `~/.claude/sessions/<pid>.json` for every live session, holding the
/// pid, the session id, the working directory and what the session thinks of
/// its own state. A file keyed by pid answers, directly, the question the rest
/// of this code has been inferring.
///
/// What it replaces is a guess that was two steps removed from the answer.
/// `CLAUDE_CODE_SESSION_ID` is exported *for* the processes an agent launches,
/// so it can only be read off a child — an agent that has not run anything yet
/// has no id to find, and reading it costs a sysctl over a megabyte buffer for
/// each one. This costs opening a file whose name we already know.
struct ClaudeSessionRegistry {

    struct Entry {
        let sessionId: String
        let cwd: String?

        /// What Claude Code says about itself: "busy", "idle". Read and carried
        /// but not yet acted on — Corral derives busy from CPU, and replacing
        /// that is a change to how the list behaves rather than to what it
        /// knows, which deserves to be its own change.
        let status: String?
    }

    private let root: URL

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/sessions")) {
        self.root = root
    }

    /// The session a process is running, if the file agrees it is that process.
    ///
    /// `project` is the working directory Corral read off the process, and it
    /// is checked rather than trusted. These files are named after pids, pids
    /// get reused, and Claude Code has no way to clean up after a session that
    /// was killed — so an entry left behind by a dead agent will happily be
    /// found under the number some later agent was given. Two sessions in one
    /// project is the case this whole path exists to get right; handing one of
    /// them a dead session's transcript would be the same bug wearing a
    /// filename.
    func entry(forPid pid: pid_t, in project: String?) -> Entry? {
        guard let data = try? Data(contentsOf: file(for: pid)),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = record["sessionId"] as? String
        else { return nil }

        let recorded = record["cwd"] as? String
        if let project, let recorded,
           !ClaudeSessionActivityReader.belongs(recorded, to: project) {
            return nil
        }

        return Entry(sessionId: id, cwd: recorded, status: record["status"] as? String)
    }

    private func file(for pid: pid_t) -> URL {
        root.appendingPathComponent("\(pid).json")
    }
}
