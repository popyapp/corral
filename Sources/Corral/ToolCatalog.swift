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

    /// A path-only pre-filter, used to decide which processes are worth the
    /// expensive lookups. Deliberately generous — it may say yes to something
    /// `identify` later rejects, but it must never say no to something
    /// `identify` would have accepted on its path alone.
    static func pathLooksLikeATool(_ path: String) -> Bool {
        guard !systemPrefixes.contains(where: { path.hasPrefix($0) }) else { return false }
        if path.contains("/.local/share/claude/versions/") { return true }
        if path.contains("/@anthropic-ai/claude-code/") { return true }
        if path.contains("/@openai/codex") || path.contains("/.codex/") { return true }
        if path.contains("/.cursor/") { return true }
        if electronApps.contains(where: { path.contains($0.bundle) }) { return true }
        if path.contains("/ChatGPT.app/") { return true }
        let name = (path as NSString).lastPathComponent
        return name == "claude" || name == "codex" || name.hasPrefix("codex-")
            || name == "cursor-agent"
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
        /// The bundle directory name, matched anywhere in the path.
        let bundle: String
        let tool: Tool
    }

    private static let electronApps: [ElectronApp] = [
        .init(bundle: "/Claude.app/", tool: .claudeDesktop),
        .init(bundle: "/Cursor.app/", tool: .cursor),
        .init(bundle: "/Windsurf.app/", tool: .windsurf),
    ]

    /// Electron fans out into a main process plus renderers, GPU helpers and a
    /// crash handler. They all live inside the same `.app`, so the bundle name
    /// identifies the product and the sub-path identifies the role.
    ///
    /// Matched on the bundle *component*, not an `/Applications` prefix: people
    /// install into `~/Applications`, and an in-place updater stages the new
    /// copy in a temp directory and runs it from there. The `/System` guard
    /// above is what keeps this from being too loose.
    private static func electronApp(path: String, raw: ProcessScanner.Raw) -> Match? {
        guard let app = electronApps.first(where: { path.contains($0.bundle) }) else {
            return nil
        }

        let role: ProcessRole
        if path.contains("(Renderer)") || raw.arguments.contains("--type=renderer") {
            role = .renderer
        } else if path.contains("/Frameworks/") || path.contains("/Helpers/")
            || raw.arguments.contains(where: { $0.hasPrefix("--type=") })
        {
            // Cursor's extension host and language servers arrive as
            // `--type=utility` / `--type=gpu-process` rather than a distinct
            // binary, so the argument decides where the name cannot.
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

    /// Codex ships as a native binary (`codex`, or `codex-aarch64-apple-darwin`
    /// from the release archives), as an npm package run through node, and
    /// bundled inside the ChatGPT desktop app.
    private static func codex(path: String, raw: ProcessScanner.Raw) -> Match? {
        let name = (path as NSString).lastPathComponent
        if name == "codex" || name.hasPrefix("codex-") {
            return Match(tool: .codex, role: .agent, version: nil)
        }
        if path.contains("/@openai/codex") || path.contains("/.codex/") {
            return Match(tool: .codex, role: .agent, version: nil)
        }
        if path.contains("/ChatGPT.app/") {
            let isHelper = path.contains("/Frameworks/") || path.contains("/Helpers/")
            return Match(tool: .codex, role: isHelper ? .helper : .agent, version: nil)
        }
        // `node …/codex/bin/codex.js` — the binary is node, so only the command
        // line can say what it is running.
        if raw.arguments.contains(where: {
            $0.contains("@openai/codex") || $0.hasSuffix("/codex.js")
        }) {
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

    /// Command-line fragments that mean "this is serving something".
    private static let devServerTokens = [
        "next dev", "next start", "vite", "webpack serve", "webpack-dev-server",
        "nuxt dev", "astro dev", "remix dev", "ng serve", "react-scripts start",
        "rails server", "rails s", "manage.py runserver", "flask run",
        "uvicorn", "gunicorn", "nodemon", "http-server", "serve -", "php artisan serve",
        "expo start", "metro", "storybook",
    ]

    private static let toolingNames: Set<String> = [
        "tsc", "swift", "swiftc", "swift-frontend", "cargo", "rustc", "go",
        "gradle", "mvn", "make", "cmake", "clang", "gcc", "esbuild", "rollup",
        "jest", "vitest", "pytest", "mocha", "xcodebuild", "eslint", "prettier",
        "tsserver", "sourcekit-lsp", "pylsp", "gopls", "rust-analyzer",
        "docker", "podman", "ruff", "mypy", "biome",
    ]

    private static let toolingTokens = [
        "language-server", "langserver", "--watch", "tsc -w", "jest --",
        "vitest run", "pytest ", "swift build", "swift test", "cargo build",
        "go build", "npm run build", "pnpm build", "yarn build",
    ]

    /// A process spawned by a recognised agent. We attribute it to the parent's
    /// tool rather than trying to recognise it on its own — an MCP server can
    /// be any binary at all, and the only thing that makes it *this agent's*
    /// MCP server is that this agent started it.
    static func classifyChild(_ raw: ProcessScanner.Raw, parent: Tool) -> ProcessRole {
        let name = raw.executablePath.map { ($0 as NSString).lastPathComponent } ?? raw.comm
        let joined = raw.arguments.joined(separator: " ").lowercased()

        if name == "caffeinate" { return .powerAssertion }
        if ["zsh", "bash", "sh", "fish"].contains(name) { return .shell }

        // Things the agent started while working on the project. A dev server
        // is the one that matters: it outlives the task, holds a port, and is
        // often the biggest process in the group — and you will not remember
        // starting it.
        if devServerTokens.contains(where: joined.contains) { return .devServer }
        if toolingNames.contains(name) || toolingTokens.contains(where: joined.contains) {
            return .tooling
        }

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
