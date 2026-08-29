import AppKit
import Foundation

/// Turns on the one thing an agent will not tell you unless asked.
///
/// This writes to files Corral does not own — the user's own
/// `~/.claude/settings.json` and `~/.cursor/cli-config.json` — which is why
/// every part of it is arranged around being reversible and being understood
/// first. It asks, in a dialog that names the exact setting it is about to add.
/// It keeps a timestamped copy of the file beside it. It edits the text rather
/// than re-serialising the JSON, so the rest of the file comes out byte for
/// byte as it went in. And it refuses outright to touch a status line somebody
/// else already set up.
@MainActor
enum StatusLineSetup {

    /// One agent that can be asked to report.
    struct Target {
        let tool: Tool
        let name: String
        /// The agent's own settings file, which is not ours.
        let file: URL
        /// What `--statusline` is told, so the snapshot knows whose it is.
        let argument: String
        /// What turning this on actually gets you. The two tools differ, and
        /// the dialog must not promise the one that does not.
        let provides: String

        static let claudeCode = Target(
            tool: .claudeCode,
            name: "Claude Code",
            file: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/settings.json"),
            argument: "claude",
            provides: "Corral will then show what your account has left — the five-hour "
                + "and weekly windows — and the exact size of each session's context."
        )

        static let cursorAgent = Target(
            tool: .cursorAgent,
            name: "Cursor",
            file: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cursor/cli-config.json"),
            argument: "cursor",
            provides: "Corral will then show how full each session's context is. Cursor "
                + "does not publish what your account has left, to this or to anywhere "
                + "else on this Mac, so that part will stay empty."
        )

        static let all: [Target] = [.claudeCode, .cursorAgent]

        static func of(_ tool: Tool) -> Target? {
            switch tool {
            case .claudeCode, .claudeDesktop: return .claudeCode
            case .cursorAgent, .cursor: return .cursorAgent
            default: return nil
            }
        }
    }

    enum State {
        case installed
        case absent
        /// Someone else's status line is in the slot.
        case taken(command: String)
        case unreadable
    }

    // ─ Looking ──────────────────────────────────────────────────────────────

    static func state(of target: Target) -> State { state(file: target.file) }

    nonisolated static func state(file: URL) -> State {
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unreadable }

        guard let line = root["statusLine"] as? [String: Any],
              let command = line["command"] as? String
        else { return .absent }

        return command.contains("--statusline") && command.contains("Corral")
            ? .installed
            : .taken(command: command)
    }

    static func command(for target: Target) -> String {
        let path = Bundle.main.executablePath ?? "/Applications/Corral.app/Contents/MacOS/Corral"
        // Quoted because an app someone renamed can easily have a space in its
        // path, and the command runs through a shell.
        return "\"\(path)\" --statusline \(target.argument)"
    }

    // ─ Asking ───────────────────────────────────────────────────────────────

    /// Offer to install it, and do so if the answer is yes.
    static func offer(_ target: Target) {
        switch state(of: target) {
        case .installed:
            tell(
                "Already set up",
                "\(target.name) is already reporting to Corral. Its figures appear "
                    + "once a session makes a request."
            )

        case .unreadable:
            tell(
                "Cannot read those settings",
                "Corral could not parse \(short(target.file)), so it will not write to "
                    + "it. Fix or remove the file and try again."
            )

        case .taken(let existing):
            // Chaining two status lines means running someone else's command
            // and passing its output through, and getting that wrong breaks the
            // line they already rely on. Corral says what it would do instead.
            let alert = NSAlert()
            alert.messageText = "You already have a status line"
            alert.informativeText = """
                \(target.name) is set to run:

                \(existing)

                Corral will not replace it. To use both, add this to the end of your \
                own command so it sees the same input:

                \(command(for: target))
                """
            alert.addButton(withTitle: "Copy Corral's Command")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command(for: target), forType: .string)
            }

        case .absent:
            let alert = NSAlert()
            alert.messageText = "Let \(target.name) report its usage?"
            alert.informativeText = """
                \(target.name) does not write these figures to disk, but it does hand \
                them to a status line command. Corral can be that command.

                This adds one setting to \(short(target.file)):

                "statusLine": { "type": "command", "command": … }

                \(target.provides)

                Corral keeps only the session id, the working directory, the context \
                size and any limit percentages — not the transcript path, the branch, \
                or anything you are working on. A copy of the file is saved first.

                Your status line will show the project and those figures.
                """
            alert.addButton(withTitle: "Add It")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            report(install(target), target: target)
        }
    }

    // ─ Writing ──────────────────────────────────────────────────────────────

    enum Outcome {
        case added(backup: URL?)
        case failed(String)
    }

    /// Insert the setting textually, so nothing else in the file moves.
    ///
    /// Re-serialising the parsed JSON would be shorter and would also reorder
    /// every key and drop every formatting choice the user made. A settings file
    /// that comes back rearranged is a settings file the app has taken over.
    static func install(_ target: Target, file: URL? = nil) -> Outcome {
        let file = file ?? target.file
        guard case .absent = state(file: file) else {
            return .failed("The status line setting is not free.")
        }
        guard let original = try? String(contentsOf: file, encoding: .utf8) else {
            return .failed("Could not read \(file.path).")
        }
        guard let brace = original.firstIndex(of: "{") else {
            return .failed("\(file.path) does not look like a JSON object.")
        }

        let escaped = command(for: target)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let insertion = "\n  \"statusLine\": { \"type\": \"command\", \"command\": \"\(escaped)\" },"

        var updated = original
        updated.insert(contentsOf: insertion, at: original.index(after: brace))

        // Never leave the file worse than it was found. If the edit produced
        // something that will not parse, it is not written at all.
        guard let data = updated.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil
        else {
            return .failed("The edit would have produced invalid JSON, so nothing was written.")
        }

        let backup = self.backup(original, beside: file)
        do {
            try updated.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return .failed(error.localizedDescription)
        }
        return .added(backup: backup)
    }

    private static func backup(_ contents: String, beside file: URL) -> URL? {
        let stamp = Int(Date().timeIntervalSince1970)
        let copy = file.deletingLastPathComponent()
            .appendingPathComponent("\(file.lastPathComponent).corral-backup-\(stamp)")
        try? contents.write(to: copy, atomically: true, encoding: .utf8)
        return FileManager.default.fileExists(atPath: copy.path) ? copy : nil
    }

    // ─ Telling ──────────────────────────────────────────────────────────────

    private static func report(_ outcome: Outcome, target: Target) {
        switch outcome {
        case .added(let backup):
            var text = "Sessions started from now on will report to Corral. Figures "
                + "appear once a session makes its first request; on plans with nothing "
                + "metered, the limits never appear, and that is not an error."
            if let backup {
                text += "\n\nYour previous settings are in \(backup.lastPathComponent)."
            }
            tell("\(target.name) is set up", text)
        case .failed(let reason):
            tell("Nothing was changed", reason)
        }
    }

    private static func tell(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// `~`-relative, because that is how a person refers to these files.
    private static func short(_ file: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return file.path.hasPrefix(home)
            ? "~" + file.path.dropFirst(home.count)
            : file.path
    }
}
