import Foundation

/// What each tool leaves on disk, and how safe it is to remove.
///
/// The sizes involved are not small. On the machine this was written on:
/// 10 GB of Claude Desktop VM image, 2.8 GB of superseded Claude Code versions,
/// 1 GB of plugin cache, half a gigabyte of Electron HTTP cache. Roughly 16 GB
/// for two apps.
///
/// The whole design question is which of that is junk and which is your work,
/// so every entry declares it.
enum Safety: Int, Comparable {
    /// Regenerated automatically. Deleting costs a slower next launch.
    case safe
    /// Large, and the app will fetch it again when it next needs it. Fine to
    /// remove, expensive to re-acquire.
    case redownload
    /// Your history. Conversation logs, undo history, extensions. Never
    /// selected by default, and labelled plainly so nobody clears it by
    /// accident.
    case userData

    static func < (a: Safety, b: Safety) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .safe: return "Safe to clear"
        case .redownload: return "Will be downloaded again"
        case .userData: return "Your data"
        }
    }

    var detail: String {
        switch self {
        case .safe:
            return "Caches the app rebuilds by itself. The only cost is a slower next launch."
        case .redownload:
            return "Big, and the app fetches it again when it needs it. Free the space now, pay the download later."
        case .userData:
            return "History and settings you created. Corral never selects these for you."
        }
    }

    /// Only caches are pre-selected. Anything that costs the user something is
    /// theirs to tick.
    var selectedByDefault: Bool { self == .safe }
}

/// A removable thing on disk.
struct DiskItem: Identifiable, Hashable {
    let url: URL
    let tool: Tool
    let title: String
    let detail: String
    let safety: Safety
    var size: Int64

    var id: String { url.path }

    var displayPath: String {
        let home = NSHomeDirectory()
        let path = url.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    func hash(into hasher: inout Hasher) { hasher.combine(url.path) }
    static func == (a: DiskItem, b: DiskItem) -> Bool { a.url.path == b.url.path }
}

/// Where to look, per tool. Paths are relative to the home directory.
enum DiskCatalog {

    struct Entry {
        let tool: Tool
        let relativePath: String
        let title: String
        let detail: String
        let safety: Safety
        /// When true, each child of the directory is listed separately rather
        /// than the directory as a whole — used for versioned install folders,
        /// where the point is to keep one and drop the rest.
        var perChild = false
    }

    static let entries: [Entry] = [

        // ─ Claude Code ──────────────────────────────────────────────────────
        .init(
            tool: .claudeCode,
            relativePath: ".local/share/claude/versions",
            title: "Superseded versions",
            detail: "Claude Code keeps every version it has ever updated through. Only the newest is used.",
            safety: .safe,
            perChild: true
        ),
        .init(
            tool: .claudeCode,
            relativePath: ".claude/plugins/cache",
            title: "Plugin cache",
            detail: "Downloaded plugin and marketplace contents.",
            safety: .redownload
        ),
        .init(
            tool: .claudeCode,
            relativePath: ".claude/paste-cache",
            title: "Paste cache",
            detail: "Text you pasted into sessions.",
            safety: .safe
        ),
        .init(
            tool: .claudeCode,
            relativePath: ".claude/image-cache",
            title: "Image cache",
            detail: "Images you dropped into sessions.",
            safety: .safe
        ),
        .init(
            tool: .claudeCode,
            relativePath: ".claude/shell-snapshots",
            title: "Shell snapshots",
            detail: "A copy of your shell environment per session.",
            safety: .safe
        ),
        .init(
            tool: .claudeCode,
            relativePath: ".claude/cache",
            title: "Cache",
            detail: "Assorted scratch data.",
            safety: .safe
        ),
        .init(
            tool: .claudeCode,
            relativePath: "Library/Caches/claude-cli-nodejs",
            title: "Node cache",
            detail: "Node module cache for the CLI.",
            safety: .safe
        ),
        .init(
            tool: .claudeCode,
            relativePath: ".claude/file-history",
            title: "File history",
            detail: "Snapshots of files before edits — this is what undo reads.",
            safety: .userData
        ),
        .init(
            tool: .claudeCode,
            relativePath: ".claude/projects",
            title: "Conversation history",
            detail: "Every session transcript. Removing this means --resume and --continue have nothing to resume.",
            safety: .userData
        ),
        .init(
            tool: .claudeCode,
            relativePath: ".claude/backups",
            title: "Backups",
            detail: "Settings backups.",
            safety: .userData
        ),

        // ─ Claude Desktop ───────────────────────────────────────────────────
        .init(
            tool: .claudeDesktop,
            relativePath: "Library/Application Support/Claude/vm_bundles",
            title: "Local agent VM image",
            detail: "The Linux virtual machine local agent mode runs in. Easily the largest thing either app stores.",
            safety: .redownload
        ),
        .init(
            tool: .claudeDesktop,
            relativePath: "Library/Application Support/Claude/Cache",
            title: "Network cache",
            detail: "Electron's HTTP cache.",
            safety: .safe
        ),
        .init(
            tool: .claudeDesktop,
            relativePath: "Library/Application Support/Claude/Code Cache",
            title: "Compiled script cache",
            detail: "Chromium's compiled JavaScript cache.",
            safety: .safe
        ),
        .init(
            tool: .claudeDesktop,
            relativePath: "Library/Application Support/Claude/GPUCache",
            title: "GPU cache",
            detail: "Compiled shaders.",
            safety: .safe
        ),
        .init(
            tool: .claudeDesktop,
            relativePath: "Library/Application Support/Claude/DawnWebGPUCache",
            title: "WebGPU cache",
            detail: "Compiled WebGPU shaders.",
            safety: .safe
        ),
        .init(
            tool: .claudeDesktop,
            relativePath: "Library/Application Support/Claude/DawnGraphiteCache",
            title: "Graphite cache",
            detail: "Compiled graphics pipelines.",
            safety: .safe
        ),
        .init(
            tool: .claudeDesktop,
            relativePath: "Library/Application Support/Claude/claude-code",
            title: "Bundled Claude Code versions",
            detail: "Copies of Claude Code the desktop app ships with. Only the newest is used.",
            safety: .safe,
            perChild: true
        ),
        .init(
            tool: .claudeDesktop,
            relativePath: "Library/Application Support/Claude/claude-code-vm",
            title: "Claude Code VM builds",
            detail: "Linux builds of Claude Code for local agent mode. Only the newest is used.",
            safety: .safe,
            perChild: true
        ),
        .init(
            tool: .claudeDesktop,
            relativePath: "Library/Caches/com.anthropic.claudefordesktop",
            title: "App cache",
            detail: "macOS-level cache for the desktop app.",
            safety: .safe
        ),
        .init(
            tool: .claudeDesktop,
            relativePath: "Library/Logs/Claude",
            title: "Logs",
            detail: "Diagnostic logs.",
            safety: .safe
        ),
        .init(
            tool: .claudeDesktop,
            relativePath: "Library/Application Support/Claude/local-agent-mode-sessions",
            title: "Local agent sessions",
            detail: "Working state from local agent mode runs.",
            safety: .userData
        ),

        // ─ Cursor ───────────────────────────────────────────────────────────
        // Cursor is a VS Code fork, so it inherits Code's storage layout.
        .init(
            tool: .cursor,
            relativePath: "Library/Application Support/Cursor/Cache",
            title: "Network cache",
            detail: "Electron's HTTP cache.",
            safety: .safe
        ),
        .init(
            tool: .cursor,
            relativePath: "Library/Application Support/Cursor/Code Cache",
            title: "Compiled script cache",
            detail: "Chromium's compiled JavaScript cache.",
            safety: .safe
        ),
        .init(
            tool: .cursor,
            relativePath: "Library/Application Support/Cursor/CachedData",
            title: "Cached data",
            detail: "Parsed sources and indexes the editor rebuilds on demand.",
            safety: .safe
        ),
        .init(
            tool: .cursor,
            relativePath: "Library/Application Support/Cursor/CachedExtensionVSIXs",
            title: "Extension downloads",
            detail: "Downloaded extension packages, kept after install.",
            safety: .safe
        ),
        .init(
            tool: .cursor,
            relativePath: "Library/Application Support/Cursor/GPUCache",
            title: "GPU cache",
            detail: "Compiled shaders.",
            safety: .safe
        ),
        .init(
            tool: .cursor,
            relativePath: "Library/Application Support/Cursor/logs",
            title: "Logs",
            detail: "Per-window and extension host logs.",
            safety: .safe
        ),
        .init(
            tool: .cursor,
            relativePath: "Library/Application Support/Cursor/User/workspaceStorage",
            title: "Workspace storage",
            detail: "Per-project editor state: open tabs, undo, view layout.",
            safety: .userData
        ),
        .init(
            tool: .cursor,
            relativePath: "Library/Application Support/Cursor/User/History",
            title: "Local file history",
            detail: "The editor's own undo history for edited files.",
            safety: .userData
        ),
        .init(
            tool: .cursor,
            relativePath: ".cursor/extensions",
            title: "Extensions",
            detail: "Installed extensions.",
            safety: .userData
        ),

        // ─ Codex ────────────────────────────────────────────────────────────
        .init(
            tool: .codex,
            relativePath: ".codex/log",
            title: "Logs",
            detail: "Session logs.",
            safety: .safe
        ),
        .init(
            tool: .codex,
            relativePath: ".codex/tmp",
            title: "Temporary files",
            detail: "Scratch space from runs.",
            safety: .safe
        ),
        .init(
            tool: .codex,
            relativePath: ".cache/codex",
            title: "Cache",
            detail: "Downloaded data the CLI rebuilds.",
            safety: .safe
        ),
        .init(
            tool: .codex,
            relativePath: ".codex/sessions",
            title: "Session history",
            detail: "Past conversations.",
            safety: .userData
        ),

        // ─ Windsurf ─────────────────────────────────────────────────────────
        .init(
            tool: .windsurf,
            relativePath: "Library/Application Support/Windsurf/Cache",
            title: "Network cache",
            detail: "Electron's HTTP cache.",
            safety: .safe
        ),
        .init(
            tool: .windsurf,
            relativePath: "Library/Application Support/Windsurf/Code Cache",
            title: "Compiled script cache",
            detail: "Chromium's compiled JavaScript cache.",
            safety: .safe
        ),
        .init(
            tool: .windsurf,
            relativePath: "Library/Application Support/Windsurf/CachedData",
            title: "Cached data",
            detail: "Parsed sources and indexes the editor rebuilds on demand.",
            safety: .safe
        ),

        // ─ Kiro CLI ─────────────────────────────────────────────────────────
        .init(
            tool: .kiroCLI,
            relativePath: ".kiro/sessions/cli",
            title: "Conversation history",
            detail: "Every Kiro CLI session, Kiro Crew's included. Removing this means --resume has nothing to resume.",
            safety: .userData
        ),

        // ─ Kiro Crew ────────────────────────────────────────────────────────
        .init(
            tool: .kiroCrew,
            relativePath: ".kiro/crew/models",
            title: "Embedding model",
            detail: "The local model Kiro Crew's memory embeds with. Fetched again the next time memory needs it.",
            safety: .redownload
        ),
        .init(
            tool: .kiroCrew,
            relativePath: ".kiro/crew/cache",
            title: "Cache",
            detail: "Compiled Python, crash dumps and scratch space the gateway rebuilds.",
            safety: .safe
        ),
        .init(
            tool: .kiroCrew,
            relativePath: ".kiro/crew/logs",
            title: "Gateway logs",
            detail: "Diagnostic logs from the background gateway.",
            safety: .safe
        ),
        .init(
            tool: .kiroCrew,
            relativePath: "Library/Logs/Kiro Crew",
            title: "Logs",
            detail: "Diagnostic logs.",
            safety: .safe
        ),
        .init(
            tool: .kiroCrew,
            relativePath: "Library/Application Support/kirocrew-desktop/Cache",
            title: "Network cache",
            detail: "Electron's HTTP cache.",
            safety: .safe
        ),
        .init(
            tool: .kiroCrew,
            relativePath: "Library/Application Support/kirocrew-desktop/Code Cache",
            title: "Compiled script cache",
            detail: "Chromium's compiled JavaScript cache.",
            safety: .safe
        ),
        .init(
            tool: .kiroCrew,
            relativePath: "Library/Application Support/kirocrew-desktop/GPUCache",
            title: "GPU cache",
            detail: "Compiled shaders.",
            safety: .safe
        ),
        .init(
            tool: .kiroCrew,
            relativePath: "Library/Application Support/kirocrew-desktop/DawnWebGPUCache",
            title: "WebGPU cache",
            detail: "Compiled WebGPU shaders.",
            safety: .safe
        ),
        .init(
            tool: .kiroCrew,
            relativePath: "Library/Application Support/kirocrew-desktop/DawnGraphiteCache",
            title: "Graphite cache",
            detail: "Compiled graphics pipelines.",
            safety: .safe
        ),
        .init(
            tool: .kiroCrew,
            relativePath: ".kiro/crew/sessions",
            title: "Session workspaces",
            detail: "Per-session history, sub-agent results and artifacts.",
            safety: .userData
        ),
        .init(
            tool: .kiroCrew,
            relativePath: ".kiro/crew/workspace",
            title: "Agent workspace",
            detail: "Files the agents made for themselves — notes, tasks, configs.",
            safety: .userData
        ),

        // ─ Kiro IDE ─────────────────────────────────────────────────────────
        // A VS Code fork, so it inherits Code's storage layout.
        .init(
            tool: .kiro,
            relativePath: "Library/Application Support/Kiro/Cache",
            title: "Network cache",
            detail: "Electron's HTTP cache.",
            safety: .safe
        ),
        .init(
            tool: .kiro,
            relativePath: "Library/Application Support/Kiro/Code Cache",
            title: "Compiled script cache",
            detail: "Chromium's compiled JavaScript cache.",
            safety: .safe
        ),
        .init(
            tool: .kiro,
            relativePath: "Library/Application Support/Kiro/CachedData",
            title: "Cached data",
            detail: "Parsed sources and indexes the editor rebuilds on demand.",
            safety: .safe
        ),
        .init(
            tool: .kiro,
            relativePath: "Library/Application Support/Kiro/GPUCache",
            title: "GPU cache",
            detail: "Compiled shaders.",
            safety: .safe
        ),
        .init(
            tool: .kiro,
            relativePath: "Library/Application Support/Kiro/logs",
            title: "Logs",
            detail: "Per-window and extension host logs.",
            safety: .safe
        ),
        .init(
            tool: .kiro,
            relativePath: "Library/Application Support/Kiro/User/workspaceStorage",
            title: "Workspace storage",
            detail: "Per-project editor state: open tabs, undo, view layout.",
            safety: .userData
        ),
        .init(
            tool: .kiro,
            relativePath: "Library/Application Support/Kiro/User/History",
            title: "Local file history",
            detail: "The editor's own undo history for edited files.",
            safety: .userData
        ),

        // ─ Antigravity ──────────────────────────────────────────────────────
        // Also a VS Code fork. Its agent data lives under ~/.gemini, in two
        // copies once the updater has installed the renamed app: the second
        // is what `Antigravity IDE.app` reads, and the first is what it was
        // copied from.
        .init(
            tool: .antigravity,
            relativePath: "Library/Application Support/Antigravity/Cache",
            title: "Network cache",
            detail: "Electron's HTTP cache.",
            safety: .safe
        ),
        .init(
            tool: .antigravity,
            relativePath: "Library/Application Support/Antigravity/Code Cache",
            title: "Compiled script cache",
            detail: "Chromium's compiled JavaScript cache.",
            safety: .safe
        ),
        .init(
            tool: .antigravity,
            relativePath: "Library/Application Support/Antigravity/CachedData",
            title: "Cached data",
            detail: "Parsed sources and indexes the editor rebuilds on demand.",
            safety: .safe
        ),
        .init(
            tool: .antigravity,
            relativePath: "Library/Application Support/Antigravity/CachedExtensionVSIXs",
            title: "Extension downloads",
            detail: "Downloaded extension packages, kept after install.",
            safety: .safe
        ),
        .init(
            tool: .antigravity,
            relativePath: "Library/Application Support/Antigravity/GPUCache",
            title: "GPU cache",
            detail: "Compiled shaders.",
            safety: .safe
        ),
        .init(
            tool: .antigravity,
            relativePath: "Library/Application Support/Antigravity/logs",
            title: "Logs",
            detail: "Per-window and extension host logs.",
            safety: .safe
        ),
        .init(
            tool: .antigravity,
            relativePath: "Library/Logs/Antigravity",
            title: "Agent logs",
            detail: "The language server's and updater's logs.",
            safety: .safe
        ),
        .init(
            tool: .antigravity,
            relativePath: "Library/Caches/com.google.antigravity.ShipIt",
            title: "Staged update",
            detail: "An update the app unpacked to install. Fetched again if it is still needed.",
            safety: .safe
        ),
        .init(
            tool: .antigravity,
            relativePath: "Library/Caches/antigravity-updater",
            title: "Downloaded updates",
            detail: "Update archives the app has already downloaded.",
            safety: .redownload
        ),
        .init(
            tool: .antigravity,
            relativePath: "Library/Application Support/Antigravity/User/workspaceStorage",
            title: "Workspace storage",
            detail: "Per-project editor state: open tabs, undo, view layout.",
            safety: .userData
        ),
        .init(
            tool: .antigravity,
            relativePath: "Library/Application Support/Antigravity/User/History",
            title: "Local file history",
            detail: "The editor's own undo history for edited files.",
            safety: .userData
        ),
        .init(
            tool: .antigravity,
            relativePath: ".antigravity/extensions",
            title: "Extensions",
            detail: "Installed extensions.",
            safety: .userData
        ),
        .init(
            tool: .antigravity,
            relativePath: ".gemini/antigravity/browser_recordings",
            title: "Browser recordings",
            detail: "Recordings of the agent's browser sessions. Easily the largest thing it keeps.",
            safety: .userData
        ),
        .init(
            tool: .antigravity,
            relativePath: ".gemini/antigravity/conversations",
            title: "Conversation history",
            detail: "Every agent conversation, encrypted. Removing this loses them.",
            safety: .userData
        ),
        .init(
            tool: .antigravity,
            relativePath: ".gemini/antigravity/brain",
            title: "Agent artifacts",
            detail: "Task plans, walkthroughs and screenshots the agent produced per conversation.",
            safety: .userData
        ),
        .init(
            tool: .antigravity,
            relativePath: ".gemini/antigravity-ide/browser_recordings",
            title: "Browser recordings (Antigravity IDE)",
            detail: "The renamed app's copy of the agent's browser recordings.",
            safety: .userData
        ),
        .init(
            tool: .antigravity,
            relativePath: ".gemini/antigravity-ide/conversations",
            title: "Conversation history (Antigravity IDE)",
            detail: "The renamed app's copy of every agent conversation, encrypted.",
            safety: .userData
        ),
        .init(
            tool: .antigravity,
            relativePath: ".gemini/antigravity-ide/brain",
            title: "Agent artifacts (Antigravity IDE)",
            detail: "The renamed app's copy of the agent's task plans and screenshots.",
            safety: .userData
        ),
    ]

    /// Roots outside which the remover refuses to act, whatever a catalog entry
    /// or a caller says. Belt and braces: the paths above are all relative to
    /// home, so nothing should ever land outside these — but the check is what
    /// makes that a guarantee rather than an intention.
    static var allowedRoots: [String] {
        let home = NSHomeDirectory()
        return [
            home + "/.claude",
            home + "/.local/share/claude",
            home + "/.codex",
            home + "/.cursor",
            home + "/.cache",
            home + "/Library/Application Support/Claude",
            home + "/Library/Application Support/Cursor",
            home + "/Library/Application Support/Windsurf",
            home + "/.kiro",
            home + "/Library/Application Support/kirocrew-desktop",
            home + "/Library/Application Support/Kiro",
            home + "/.antigravity",
            home + "/.gemini/antigravity",
            home + "/.gemini/antigravity-ide",
            home + "/Library/Application Support/Antigravity",
            home + "/Library/Caches",
            home + "/Library/Logs",
        ]
    }

    static func isRemovable(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard !path.contains("..") else { return false }
        // A prefix match alone would let "~/Library/CachesEvil" through.
        return allowedRoots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}
