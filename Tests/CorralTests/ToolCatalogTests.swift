import XCTest
@testable import Corral

/// Recognition tests.
///
/// The point of these is that they need none of the tools installed. Cursor,
/// Codex and Windsurf all have to work correctly on a machine that has never
/// run them, and the only way to know that before shipping is to feed the
/// catalog the exact paths those tools produce.
///
/// The paths below are real shapes, not invented ones: the Claude Code and
/// Claude Desktop cases were taken from a live process table, and the Cursor
/// and Codex ones follow the documented install layouts (Cursor is a VS Code
/// fork and inherits its Electron structure).
final class ToolCatalogTests: XCTestCase {

    private func raw(
        _ path: String,
        args: [String] = [],
        comm: String? = nil,
        cwd: String? = "/Users/someone/code/api"
    ) -> ProcessScanner.Raw {
        ProcessScanner.Raw(
            pid: 4242,
            ppid: 1,
            comm: comm ?? (path as NSString).lastPathComponent,
            executablePath: path,
            arguments: args.isEmpty ? [(path as NSString).lastPathComponent] : args,
            workingDirectory: cwd,
            residentBytes: 100_000_000,
            cpuSeconds: 12,
            startedAt: Date(timeIntervalSinceNow: -3600),
            tty: "/dev/ttys004",
            lastTerminalActivity: Date(timeIntervalSinceNow: -600)
        )
    }

    // ─ Claude Code ──────────────────────────────────────────────────────────

    func testClaudeCodeVersionedInstall() throws {
        // The kernel reports this process as "2.1.235", because that is the
        // binary's name. The version has to come out of the path.
        let match = try XCTUnwrap(
            ToolCatalog.identify(
                raw("/Users/someone/.local/share/claude/versions/2.1.235",
                    args: ["claude"], comm: "2.1.235")
            )
        )
        XCTAssertEqual(match.tool, .claudeCode)
        XCTAssertEqual(match.role, .agent)
        XCTAssertEqual(match.version, "2.1.235")
    }

    func testClaudeCodeNpmInstall() throws {
        let match = try XCTUnwrap(
            ToolCatalog.identify(
                raw("/opt/homebrew/bin/node",
                    args: ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"],
                    comm: "node")
            )
        )
        XCTAssertEqual(match.tool, .claudeCode)
        XCTAssertNil(match.version)
    }

    func testClaudeCodePlainBinary() throws {
        let match = try XCTUnwrap(ToolCatalog.identify(raw("/opt/homebrew/bin/claude")))
        XCTAssertEqual(match.tool, .claudeCode)
    }

    // ─ Claude Desktop ───────────────────────────────────────────────────────

    func testClaudeDesktopMainProcess() throws {
        let match = try XCTUnwrap(
            ToolCatalog.identify(raw("/Applications/Claude.app/Contents/MacOS/Claude", cwd: "/"))
        )
        XCTAssertEqual(match.tool, .claudeDesktop)
        XCTAssertEqual(match.role, .agent)
    }

    func testClaudeDesktopRenderer() throws {
        let path = "/Applications/Claude.app/Contents/Frameworks/"
            + "Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)"
        let match = try XCTUnwrap(ToolCatalog.identify(raw(path, cwd: "/")))
        XCTAssertEqual(match.tool, .claudeDesktop)
        XCTAssertEqual(match.role, .renderer)
    }

    func testClaudeDesktopStagedUpdateCopy() throws {
        // An in-place update runs the new build from a temp directory before
        // swapping it into /Applications. Matching an /Applications prefix
        // would miss it entirely.
        let path = "/private/var/folders/96/T/com.anthropic.claudefordesktop.ShipIt.Kuv82eGF/"
            + "Claude.app/Contents/MacOS/Claude"
        let match = try XCTUnwrap(ToolCatalog.identify(raw(path, cwd: "/")))
        XCTAssertEqual(match.tool, .claudeDesktop)
    }

    // ─ Cursor ───────────────────────────────────────────────────────────────

    func testCursorMainProcess() throws {
        let match = try XCTUnwrap(
            ToolCatalog.identify(raw("/Applications/Cursor.app/Contents/MacOS/Cursor", cwd: "/"))
        )
        XCTAssertEqual(match.tool, .cursor)
        XCTAssertEqual(match.role, .agent)
    }

    func testCursorInUserApplications() throws {
        let match = try XCTUnwrap(
            ToolCatalog.identify(
                raw("/Users/someone/Applications/Cursor.app/Contents/MacOS/Cursor", cwd: "/")
            )
        )
        XCTAssertEqual(match.tool, .cursor)
    }

    func testCursorExtensionHostIsAHelper() throws {
        // The extension host is the same binary with a --type argument; only
        // the command line distinguishes it.
        let path = "/Applications/Cursor.app/Contents/Frameworks/"
            + "Cursor Helper.app/Contents/MacOS/Cursor Helper"
        let match = try XCTUnwrap(
            ToolCatalog.identify(raw(path, args: [path, "--type=utility"], cwd: "/"))
        )
        XCTAssertEqual(match.tool, .cursor)
        XCTAssertEqual(match.role, .helper)
    }

    func testCursorAgentCLI() throws {
        let match = try XCTUnwrap(
            ToolCatalog.identify(raw("/Users/someone/.local/bin/cursor-agent"))
        )
        XCTAssertEqual(match.tool, .cursorAgent)
        XCTAssertEqual(match.role, .agent)
    }

    /// The shape a real `cursor-agent` install actually produces, taken from a
    /// live process table — and the one this catalog used to miss entirely.
    ///
    /// Nothing in the chain says "cursor" where you would look for it. The user
    /// symlinks it as `agent`, that wrapper is a shell script, and the script
    /// execs a bundled `node` — so the kernel reports the executable as `node`.
    /// Only the install directory survives all three hops.
    func testCursorAgentVersionedInstall() throws {
        let match = try XCTUnwrap(
            ToolCatalog.identify(
                raw("/Users/someone/.local/share/cursor-agent/versions/2026.08.25-3e8eec8/node",
                    args: [
                        "/Users/someone/.local/bin/agent",
                        "--use-system-ca",
                        "/Users/someone/.local/share/cursor-agent/versions/2026.08.25-3e8eec8/index.js",
                    ],
                    comm: "node")
            )
        )
        XCTAssertEqual(match.tool, .cursorAgent)
        // Not `.helper`: unlike Claude, where the version is the executable and
        // anything below it is a helper, Cursor's real agent lives one level
        // under the version directory.
        XCTAssertEqual(match.role, .agent)
        XCTAssertEqual(match.version, "2026.08.25-3e8eec8")
    }

    /// The pre-filter must never reject something `identify` would accept.
    func testCursorAgentVersionedInstallPassesPreFilter() {
        XCTAssertTrue(
            ToolCatalog.pathLooksLikeATool(
                "/Users/someone/.local/share/cursor-agent/versions/2026.08.25-3e8eec8/node"
            )
        )
    }

    /// The trap this whole design exists to avoid.
    ///
    /// macOS ships `CursorUIViewService`, a text-input helper. It has nothing
    /// to do with the Cursor editor, and an app that listed it — let alone
    /// offered to kill it — would be worse than no app at all.
    func testSystemCursorUIViewServiceIsNotCursor() {
        let path = "/System/Library/PrivateFrameworks/TextInputUIMacHelper.framework/"
            + "Versions/A/XPCServices/CursorUIViewService.xpc/Contents/MacOS/CursorUIViewService"
        XCTAssertNil(ToolCatalog.identify(raw(path, cwd: "/")))
    }

    // ─ Codex ────────────────────────────────────────────────────────────────

    func testCodexNativeBinary() throws {
        let match = try XCTUnwrap(ToolCatalog.identify(raw("/Users/someone/.local/bin/codex")))
        XCTAssertEqual(match.tool, .codex)
        XCTAssertEqual(match.role, .agent)
    }

    func testCodexReleaseArchiveBinary() throws {
        let match = try XCTUnwrap(
            ToolCatalog.identify(raw("/usr/local/bin/codex-aarch64-apple-darwin"))
        )
        XCTAssertEqual(match.tool, .codex)
    }

    func testCodexNpmInstall() throws {
        let match = try XCTUnwrap(
            ToolCatalog.identify(
                raw("/opt/homebrew/bin/node",
                    args: ["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"],
                    comm: "node")
            )
        )
        XCTAssertEqual(match.tool, .codex)
    }

    func testCodexInsideChatGPTApp() throws {
        let match = try XCTUnwrap(
            ToolCatalog.identify(
                raw("/Applications/ChatGPT.app/Contents/Resources/codex", cwd: "/")
            )
        )
        XCTAssertEqual(match.tool, .codex)
    }

    // ─ Kiro ─────────────────────────────────────────────────────────────────

    /// The chain a real `kiro-cli` produces, read off a live process table:
    /// `kiro-cli` → `kiro-cli-chat chat` → a bundled `bun` running `tui.js`
    /// → `kiro-cli-chat acp`. One agent, three helpers.
    func testKiroCLIIsTheAgentAndItsChainAreHelpers() throws {
        let front = try XCTUnwrap(
            ToolCatalog.identify(raw("/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli", args: ["kiro-cli"]))
        )
        XCTAssertEqual(front.tool, .kiroCLI)
        XCTAssertEqual(front.role, .agent)

        let chat = try XCTUnwrap(
            ToolCatalog.identify(
                raw("/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli-chat",
                    args: ["/Users/someone/.local/bin/kiro-cli-chat", "chat"])
            )
        )
        XCTAssertEqual(chat.tool, .kiroCLI)
        XCTAssertEqual(chat.role, .helper)

        let tui = try XCTUnwrap(
            ToolCatalog.identify(
                raw("/Users/someone/Library/Application Support/kiro-cli/bun",
                    args: ["/Users/someone/Library/Application Support/kiro-cli/bun",
                           "/Users/someone/Library/Application Support/kiro-cli/tui.js", "chat"],
                    comm: "bun")
            )
        )
        XCTAssertEqual(tui.tool, .kiroCLI)
        XCTAssertEqual(tui.role, .helper)

        let engine = try XCTUnwrap(
            ToolCatalog.identify(
                raw("/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli-chat",
                    args: ["/Users/someone/.local/bin/kiro-cli-chat", "acp"])
            )
        )
        XCTAssertEqual(engine.role, .helper)
    }

    /// A symlinked or copied binary, outside the bundle.
    func testKiroCLIByNameAlone() throws {
        let match = try XCTUnwrap(ToolCatalog.identify(raw("/Users/someone/.local/bin/kiro-cli")))
        XCTAssertEqual(match.tool, .kiroCLI)
        XCTAssertEqual(match.role, .agent)
        XCTAssertNil(match.version, "no bundle, no version")
    }

    /// The background service the installer registers with launchd: Kiro,
    /// but not an agent.
    func testKiroCLIDesktopServiceIsAHelper() throws {
        let match = try XCTUnwrap(
            ToolCatalog.identify(
                raw("/Applications/Kiro CLI.app/Contents/MacOS/kiro_cli_desktop",
                    args: ["kiro_cli_desktop", "--no-dashboard"], cwd: "/")
            )
        )
        XCTAssertEqual(match.tool, .kiroCLI)
        XCTAssertEqual(match.role, .helper)
    }

    func testKiroCLIPassesThePreFilter() {
        XCTAssertTrue(ToolCatalog.pathLooksLikeATool("/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli"))
        XCTAssertTrue(ToolCatalog.pathLooksLikeATool("/Users/someone/Library/Application Support/kiro-cli/bun"))
        XCTAssertTrue(ToolCatalog.pathLooksLikeATool("/Users/someone/.local/bin/kiro-cli"))
        XCTAssertTrue(ToolCatalog.pathLooksLikeATool("/Applications/KiroCrew.app/Contents/MacOS/KiroCrew"))
        XCTAssertTrue(ToolCatalog.pathLooksLikeATool("/Applications/Antigravity.app/Contents/MacOS/Antigravity"))
    }

    /// Kiro Crew is Electron with a Python gateway in its Resources. The
    /// gateway is the app's machinery, not a second copy of the app — and the
    /// `kiro-cli acp` it starts per session is a Kiro CLI agent in its own
    /// right, which the inventory then files under the Crew group.
    func testKiroCrewMainAndItsGateway() throws {
        let main = try XCTUnwrap(
            ToolCatalog.identify(raw("/Applications/KiroCrew.app/Contents/MacOS/KiroCrew", cwd: "/"))
        )
        XCTAssertEqual(main.tool, .kiroCrew)
        XCTAssertEqual(main.role, .agent)

        let gateway = try XCTUnwrap(
            ToolCatalog.identify(
                raw("/Applications/KiroCrew.app/Contents/Resources/backend-dist/kirocrew-backend-arm64/bin/python3.12",
                    args: ["python3.12", "-s", "-m", "kiro_crew", "gateway", "--no-open", "--port", "5476"],
                    comm: "python3.12", cwd: "/")
            )
        )
        XCTAssertEqual(gateway.tool, .kiroCrew)
        XCTAssertEqual(gateway.role, .helper)

        let renderer = try XCTUnwrap(
            ToolCatalog.identify(
                raw("/Applications/KiroCrew.app/Contents/Frameworks/KiroCrew Helper (Renderer).app/Contents/MacOS/KiroCrew Helper (Renderer)",
                    args: ["KiroCrew Helper (Renderer)", "--type=renderer"], cwd: "/")
            )
        )
        XCTAssertEqual(renderer.role, .renderer)

        let agent = try XCTUnwrap(
            ToolCatalog.identify(
                raw("/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli",
                    args: ["/Users/someone/.local/bin/kiro-cli", "acp", "--agent", "kirocrew-lite"])
            )
        )
        XCTAssertEqual(agent.tool, .kiroCLI)
        XCTAssertEqual(agent.role, .agent)
    }

    func testKiroIDE() throws {
        let match = try XCTUnwrap(
            ToolCatalog.identify(raw("/Applications/Kiro.app/Contents/MacOS/Kiro", cwd: "/"))
        )
        XCTAssertEqual(match.tool, .kiro)
        XCTAssertEqual(match.role, .agent)
    }

    // ─ Antigravity ──────────────────────────────────────────────────────────

    /// Two bundle names for one product, and a Go language server in the
    /// bundle's Resources that is the app's, not an agent of its own.
    func testAntigravityUnderBothOfItsNames() throws {
        let original = try XCTUnwrap(
            ToolCatalog.identify(raw("/Applications/Antigravity.app/Contents/MacOS/Antigravity", cwd: "/"))
        )
        XCTAssertEqual(original.tool, .antigravity)
        XCTAssertEqual(original.role, .agent)

        let renamed = try XCTUnwrap(
            ToolCatalog.identify(raw("/Applications/Antigravity IDE.app/Contents/MacOS/Antigravity IDE", cwd: "/"))
        )
        XCTAssertEqual(renamed.tool, .antigravity)
        XCTAssertEqual(renamed.role, .agent)

        let server = try XCTUnwrap(
            ToolCatalog.identify(
                raw("/Applications/Antigravity.app/Contents/Resources/bin/language_server",
                    args: ["language_server", "--standalone", "--override_ide_name", "antigravity",
                           "--app_data_dir", "antigravity"],
                    cwd: "/")
            )
        )
        XCTAssertEqual(server.tool, .antigravity)
        XCTAssertEqual(server.role, .helper)
    }

    // ─ Rejections ───────────────────────────────────────────────────────────

    func testUnrelatedProcessesAreIgnored() {
        for path in [
            "/opt/homebrew/bin/node",
            "/bin/zsh",
            "/Applications/Safari.app/Contents/MacOS/Safari",
            "/usr/libexec/secinitd",
            "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
            // Kiro's name inside somebody else's path is not Kiro.
            "/Users/someone/code/kiro-cli-notes/build",
        ] {
            XCTAssertNil(ToolCatalog.identify(raw(path)), "should not match: \(path)")
        }
    }

    func testProcessWithNoExecutablePathIsIgnored() {
        let noPath = ProcessScanner.Raw(
            pid: 1, ppid: 0, comm: "claude", executablePath: nil, arguments: [],
            workingDirectory: nil, residentBytes: 0, cpuSeconds: 0,
            startedAt: Date(), tty: nil, lastTerminalActivity: nil
        )
        XCTAssertNil(ToolCatalog.identify(noPath))
    }

    // ─ Child roles ──────────────────────────────────────────────────────────

    func testChildClassification() {
        func role(_ path: String, _ args: [String]) -> ProcessRole {
            ToolCatalog.classifyChild(raw(path, args: args), parent: .claudeCode)
        }
        XCTAssertEqual(role("/usr/bin/caffeinate", ["caffeinate", "-i", "-t", "300"]), .powerAssertion)
        XCTAssertEqual(role("/bin/zsh", ["/bin/zsh", "-c", "ls"]), .shell)
        XCTAssertEqual(
            role("/opt/homebrew/bin/node", ["npm", "exec", "@upstash/context7-mcp"]),
            .mcpServer
        )
        XCTAssertEqual(
            role("/opt/homebrew/bin/node", ["node", "/opt/homebrew/bin/agentpack", "mcp"]),
            .mcpServer
        )
        XCTAssertEqual(
            role("/Applications/Pencil.app/Contents/Resources/mcp-server-darwin-arm64", []),
            .mcpServer
        )
        XCTAssertEqual(role("/usr/bin/grep", ["grep", "-r", "foo"]), .child)
    }
}

/// What agents start while you are working in a project.
///
/// These are children of the agent's shell, so they were already in the tree —
/// but as an undifferentiated "child". A dev server is worth naming: it outlives
/// the task that started it, holds a port, and is regularly the largest process
/// in the group.
final class DevelopmentChildTests: XCTestCase {

    private func role(_ path: String, _ args: [String]) -> ProcessRole {
        ToolCatalog.classifyChild(
            ProcessScanner.Raw(
                pid: 7, ppid: 6, comm: (path as NSString).lastPathComponent,
                executablePath: path, arguments: args,
                workingDirectory: "/Users/someone/code/api",
                residentBytes: 800_000_000, cpuSeconds: 30,
                startedAt: Date(), tty: nil, lastTerminalActivity: nil
            ),
            parent: .claudeCode
        )
    }

    func testDevServersAreNamed() {
        XCTAssertEqual(role("/opt/homebrew/bin/node", ["node", "node_modules/.bin/next", "dev"]), .devServer)
        XCTAssertEqual(role("/opt/homebrew/bin/node", ["npm", "run", "dev", "--", "vite"]), .devServer)
        XCTAssertEqual(role("/usr/bin/ruby", ["rails", "server", "-p", "3000"]), .devServer)
        XCTAssertEqual(role("/usr/bin/python3", ["python3", "manage.py", "runserver"]), .devServer)
        XCTAssertEqual(role("/opt/homebrew/bin/uvicorn", ["uvicorn", "app:main"]), .devServer)
    }

    func testBuildAndTestToolsAreTooling() {
        XCTAssertEqual(role("/usr/bin/swift", ["swift", "build"]), .tooling)
        XCTAssertEqual(role("/opt/homebrew/bin/tsc", ["tsc", "--watch"]), .tooling)
        XCTAssertEqual(role("/opt/homebrew/bin/node", ["node", "jest", "--coverage"]), .tooling)
        XCTAssertEqual(role("/usr/local/bin/cargo", ["cargo", "build"]), .tooling)
        XCTAssertEqual(role("/opt/homebrew/bin/sourcekit-lsp", ["sourcekit-lsp"]), .tooling)
        XCTAssertEqual(role("/usr/local/bin/docker", ["docker", "compose", "up"]), .tooling)
    }

    func testMcpServersStillWinOverTooling() {
        // An MCP server is often a node process too; it must not be swallowed
        // by the tooling rules.
        XCTAssertEqual(
            role("/opt/homebrew/bin/node", ["npm", "exec", "@upstash/context7-mcp"]),
            .mcpServer
        )
    }

    func testOrdinaryChildrenStayOrdinary() {
        XCTAssertEqual(role("/usr/bin/grep", ["grep", "-r", "todo"]), .child)
        XCTAssertEqual(role("/bin/cat", ["cat", "README.md"]), .child)
    }
}
