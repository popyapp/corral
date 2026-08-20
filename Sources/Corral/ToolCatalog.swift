import Foundation

/// Turns a raw process into a recognised tool, or rejects it.
///
/// Recognition is done on the **executable path**, not the process name. Two
/// reasons, both learned from real machines:
///
///  1. Claude Code's binary lives at `~/.local/share/claude/versions/2.1.235`,
///     so the kernel reports its name as `2.1.235`. Matching on the name gets
///     you nothing; matching on the path gets you the version for free.
///
///  2. Substring matching on the name is actively dangerous. macOS ships
///     `CursorUIViewService`, a text-input helper in
///     `/System/Library/PrivateFrameworks/…`, which has nothing to do with the
///     Cursor editor. An app that offered to kill it would be worse than no app
///     at all. Everything under `/System` and `/usr/libexec` is refused outright.
enum ToolCatalog {

    /// Prefixes that can never be one of our tools, whatever they are called.
    private static let systemPrefixes = [
        "/System/",
        "/usr/libexec/",
        "/usr/sbin/",
        "/Library/Apple/",
    ]

    struct Match {
        let tool: Tool
        let role: ProcessRole
        let version: String?
    }

    static func identify(_ raw: ProcessScanner.Raw) -> Match? {
        guard let path = raw.executablePath else { return nil }
        guard !systemPrefixes.contains(where: { path.hasPrefix($0) }) else { return nil }

        if let match = claudeCode(path: path, raw: raw) { return match }
        if let match = electronApp(path: path, raw: raw) { return match }
        if let match = codex(path: path, raw: raw) { return match }
        if let match = cursorAgent(path: path, raw: raw) { return match }
        return nil
    }

    // ─ Claude Code ──────────────────────────────────────────────────────────

    /// The versioned-binary install (`~/.local/share/claude/versions/2.1.235`)
    /// and the npm install (`node …/@anthropic-ai/claude-code/cli.js`).
    private static func claudeCode(path: String, raw: ProcessScanner.Raw) -> Match? {
        if let range = path.range(of: "/.local/share/claude/versions/") {
            let version = String(path[range.upperBound...])
            // The version directory is the last component; anything deeper is
            // a helper the launcher spawned, not the agent itself.
            return Match(
                tool: .claudeCode,
                role: version.contains("/") ? .child : .agent,
                version: version.split(separator: "/").first.map(String.init)
            )
        }
        if path.contains("/@anthropic-ai/claude-code/") {
            return Match(tool: .claudeCode, role: .agent, version: nil)
        }
        // A `node` process running the Claude Code CLI.
        if raw.arguments.contains(where: { $0.contains("@anthropic-ai/claude-code") }) {
            return Match(tool: .claudeCode, role: .agent, version: nil)
        }
        // Homebrew / manual installs land on a plain `claude` executable.
        if (path as NSString).lastPathComponent == "claude" {
            return Match(tool: .claudeCode, role: .agent, version: nil)
        }
        return nil
    }

    // ─ Electron desktop apps ────────────────────────────────────────────────

    private struct ElectronApp {
        let bundlePath: String
        let tool: Tool
    }

    private static let electronApps: [ElectronApp] = [
        .init(bundlePath: "/Applications/Claude.app/", tool: .claudeDesktop),
        .init(bundlePath: "/Applications/Cursor.app/", tool: .cursor),
        .init(bundlePath: "/Applications/Windsurf.app/", tool: .windsurf),
    ]

    /// Electron fans out into a main process plus renderers, GPU helpers and a
    /// crash handler. They all live inside the same `.app`, so the bundle path
    /// identifies the product and the sub-path identifies the role.
    private static func electronApp(path: String, raw: ProcessScanner.Raw) -> Match? {
        // Also match the staged copy an in-place updater leaves in a temp dir.
        let candidates = electronApps.filter {
            path.hasPrefix($0.bundlePath) || path.contains($0.bundlePath)
        }
        guard let app = candidates.first else { return nil }

        let role: ProcessRole
        if path.contains("(Renderer)") || raw.arguments.contains("--type=renderer") {
            role = .renderer
        } else if path.contains("/Frameworks/") || path.contains("/Helpers/") {
            role = .helper
        } else {
            role = .agent
        }

        return Match(tool: app.tool, role: role, version: electronVersion(path: path))
    }

    /// Electron stamps its own version into the framework path
    /// (`…/Electron Framework.framework/Versions/151.1.93.136/…`). That is the
    /// Chromium version, not the app's, so it is only used for helpers where
    /// nothing better exists.
    private static func electronVersion(path: String) -> String? {
        guard let range = path.range(of: ".framework/Versions/") else { return nil }
        let rest = path[range.upperBound...]
        let component = String(rest.split(separator: "/").first ?? "")
        // "A" is the symlinked current version — no information in it.
        return (component == "A" || component.isEmpty) ? nil : component
    }

    // ─ Codex ────────────────────────────────────────────────────────────────

    private static func codex(path: String, raw: ProcessScanner.Raw) -> Match? {
        let name = (path as NSString).lastPathComponent
        if name == "codex" || name.hasPrefix("codex-") {
            return Match(tool: .codex, role: .agent, version: nil)
        }
        if path.contains("/@openai/codex") || path.contains("/.codex/") {
            return Match(tool: .codex, role: .agent, version: nil)
        }
        if raw.arguments.contains(where: { $0.contains("@openai/codex") }) {
            return Match(tool: .codex, role: .agent, version: nil)
        }
        return nil
    }

    // ─ Cursor's CLI agent ───────────────────────────────────────────────────

    private static func cursorAgent(path: String, raw: ProcessScanner.Raw) -> Match? {
        let name = (path as NSString).lastPathComponent
        if name == "cursor-agent" { return Match(tool: .cursorAgent, role: .agent, version: nil) }
        if path.contains("/.cursor/") && name != "cursor" {
            return Match(tool: .cursorAgent, role: .agent, version: nil)
        }
        if raw.arguments.first.map({ ($0 as NSString).lastPathComponent }) == "cursor-agent" {
            return Match(tool: .cursorAgent, role: .agent, version: nil)
        }
        return nil
    }

    // ─ Children ─────────────────────────────────────────────────────────────

    /// A process spawned by a recognised agent. We attribute it to the parent's
    /// tool rather than trying to recognise it on its own — an MCP server can
    /// be any binary at all, and the only thing that makes it *this agent's*
    /// MCP server is that this agent started it.
    static func classifyChild(_ raw: ProcessScanner.Raw, parent: Tool) -> ProcessRole {
        let name = raw.executablePath.map { ($0 as NSString).lastPathComponent } ?? raw.comm
        let joined = raw.arguments.joined(separator: " ").lowercased()

        if name == "caffeinate" { return .powerAssertion }
        if ["zsh", "bash", "sh", "fish"].contains(name) { return .shell }

        // An MCP server can be any binary; what makes it one is how it was
        // invoked. Check the whole command line, not just the name — the most
        // common shapes are `node …/some-mcp/index.js`, `npm exec foo-mcp` and
        // `<binary> --mcp`.
        if name.lowercased().contains("mcp")
            || joined.contains(" --mcp")
            || joined.contains("mcp-server")
            || joined.contains("-mcp")
            || joined.hasSuffix(" mcp")
        {
            return .mcpServer
        }
        _ = parent
        return .child
    }
}
