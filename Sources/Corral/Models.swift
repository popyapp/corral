import Foundation

/// One of the AI coding tools Corral knows how to recognise.
///
/// The list is deliberately small and explicit. A generic "anything that looks
/// like an agent" heuristic would sweep up every `node` process on the machine,
/// and the whole point of this app is that you can trust what it shows you
/// before you kill it.
enum Tool: String, CaseIterable, Identifiable, Codable {
    case claudeCode
    case claudeDesktop
    case codex
    case cursor
    case cursorAgent
    case copilot
    case windsurf

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .claudeDesktop: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .cursorAgent: return "Cursor Agent"
        case .copilot: return "Copilot"
        case .windsurf: return "Windsurf"
        }
    }

    /// Grouping label — the desktop app and its CLI are one product to a user.
    var vendor: String {
        switch self {
        case .claudeCode, .claudeDesktop: return "Claude"
        case .codex: return "Codex"
        case .cursor, .cursorAgent: return "Cursor"
        case .copilot: return "Copilot"
        case .windsurf: return "Windsurf"
        }
    }

    /// SF Symbol shown in the list.
    var symbol: String {
        switch self {
        case .claudeCode: return "terminal"
        case .claudeDesktop: return "bubble.left.and.bubble.right"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .cursor, .cursorAgent: return "cursorarrow.rays"
        case .copilot: return "airplane"
        case .windsurf: return "wind"
        }
    }

    /// True for tools that run one instance per project directory, where the
    /// working directory is the thing that identifies the instance.
    var isProjectScoped: Bool {
        switch self {
        case .claudeCode, .codex, .cursorAgent: return true
        case .claudeDesktop, .cursor, .copilot, .windsurf: return false
        }
    }
}

/// What a process is doing inside its tool: the agent itself, a helper the app
/// spawned, or an MCP server the agent started.
enum ProcessRole: String, Codable {
    case agent
    case helper
    case renderer
    case mcpServer
    case shell
    /// `caffeinate`. Claude Code spawns one per session to stop the Mac
    /// sleeping mid-task — which means a pile of forgotten agents is also a
    /// Mac that never sleeps. Worth calling out by name.
    case powerAssertion
    case child

    var label: String {
        switch self {
        case .agent: return "agent"
        case .helper: return "helper"
        case .renderer: return "renderer"
        case .mcpServer: return "MCP server"
        case .shell: return "shell"
        case .powerAssertion: return "keeps Mac awake"
        case .child: return "child"
        }
    }

    var symbol: String {
        switch self {
        case .agent: return "circle.fill"
        case .helper: return "puzzlepiece.extension"
        case .renderer: return "rectangle.on.rectangle"
        case .mcpServer: return "point.3.connected.trianglepath.dotted"
        case .shell: return "chevron.right.square"
        case .powerAssertion: return "eye"
        case .child: return "arrow.turn.down.right"
        }
    }
}

/// A live process belonging to one of the tools above.
struct AgentProcess: Identifiable, Hashable {
    let pid: pid_t
    let ppid: pid_t
    let tool: Tool
    let role: ProcessRole

    /// `p_comm` — truncated to 16 chars by the kernel, and for Claude Code it
    /// is the *version number*, because the binary is `versions/2.1.235`. That
    /// is exactly why Activity Monitor is useless here.
    let comm: String
    let executablePath: String?
    let arguments: [String]

    /// The process's current working directory — for a project-scoped tool this
    /// is the answer to "which one of these is which".
    let workingDirectory: String?

    let residentBytes: UInt64
    let cpuSeconds: Double
    let startedAt: Date

    /// Version string when we can work one out (Claude Code encodes it in the
    /// binary path; Electron apps carry it in the framework path).
    let version: String?

    /// Controlling terminal (`/dev/ttys004`), when the process has one.
    let tty: String?
    /// Last write to that terminal. For a CLI agent this is the honest answer
    /// to "when did this last do anything" — and unlike a CPU-delta sample it
    /// is a fact on disk, so it is still true the first time Corral looks.
    let lastTerminalActivity: Date?

    var id: pid_t { pid }

    var uptime: TimeInterval { Date().timeIntervalSince(startedAt) }

    /// The last path component of the working directory — what a human calls
    /// the project.
    var projectName: String? {
        guard let cwd = workingDirectory, cwd != "/" else { return nil }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    var displayPath: String? {
        guard let cwd = workingDirectory else { return nil }
        let home = NSHomeDirectory()
        return cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
    }

    /// What to show as the row's title.
    var title: String {
        if let version { return "\(tool.displayName) \(version)" }
        return tool.displayName
    }

    func hash(into hasher: inout Hasher) { hasher.combine(pid) }
    static func == (a: AgentProcess, b: AgentProcess) -> Bool { a.pid == b.pid }
}

/// An agent plus everything it spawned, which is how you actually want to think
/// about it: killing the agent should account for its MCP servers too.
struct AgentGroup: Identifiable {
    let root: AgentProcess
    let children: [AgentProcess]

    var id: pid_t { root.pid }

    var all: [AgentProcess] { [root] + children }
    var totalResidentBytes: UInt64 { all.reduce(0) { $0 + $1.residentBytes } }
    var totalCPUSeconds: Double { all.reduce(0) { $0 + $1.cpuSeconds } }
}

/// How busy a process has been since the previous sample.
///
/// There is no kernel notion of "idle" for a process, so we derive it: sample
/// cumulative CPU time, and if it has barely moved between samples the process
/// is parked waiting for input. `idleSince` is the first sample at which that
/// became true and stayed true.
struct Activity {
    /// Fraction of one core used since the last sample, 0…1+ (can exceed 1 on
    /// multi-threaded work).
    let cpuLoad: Double
    /// When CPU use dropped below the threshold and stayed there. nil until we
    /// have two samples, and it only ever reaches back to when Corral started
    /// watching.
    let quietSince: Date?
    /// Last write to the controlling terminal, if there is one. This is the
    /// better signal: it predates Corral, so an agent you abandoned on Tuesday
    /// reads as "idle 3d" the moment you open the app.
    let lastTerminalActivity: Date?

    var isIdle: Bool { quietSince != nil }

    /// How long this has been doing nothing, from the longest-horizon evidence
    /// available. nil when we do not yet know — never a guess.
    var idleFor: TimeInterval? {
        guard isIdle else { return nil }
        let now = Date()
        if let terminal = lastTerminalActivity {
            return now.timeIntervalSince(terminal)
        }
        return quietSince.map { now.timeIntervalSince($0) }
    }

    /// True when `idleFor` comes from the terminal rather than from however
    /// long Corral has happened to be open.
    var idleIsMeasuredFromTerminal: Bool {
        isIdle && lastTerminalActivity != nil
    }
}

// ─ Formatting ───────────────────────────────────────────────────────────────

extension UInt64 {
    var byteString: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .memory)
    }
}

extension Int64 {
    var byteString: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

extension TimeInterval {
    /// Compact duration: 5.4d, 3.2h, 14m, 42s. Long-running agents are the
    /// point of the app, so days come first and stay readable.
    var durationString: String {
        let s = max(0, self)
        if s >= 86_400 { return String(format: "%.1fd", s / 86_400) }
        if s >= 3_600 { return String(format: "%.1fh", s / 3_600) }
        if s >= 60 { return String(format: "%.0fm", s / 60) }
        return String(format: "%.0fs", s)
    }

    /// CPU time reads better in minutes than in fractional days.
    var cpuTimeString: String {
        let s = max(0, self)
        if s >= 3_600 { return String(format: "%.1fh", s / 3_600) }
        if s >= 60 { return String(format: "%.1fm", s / 60) }
        return String(format: "%.1fs", s)
    }
}
