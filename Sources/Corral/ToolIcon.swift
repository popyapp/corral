import AppKit
import SwiftUI

/// The tool's real icon, taken from the copy already installed on this Mac.
///
/// Corral ships no brand artwork and never will. macOS already holds the
/// authoritative icon for every one of these products — it is what Finder and
/// the Dock draw — so we ask it for the same image. Nothing to bundle, nothing
/// that goes stale at the next rebrand, and no copy of anyone's trademark in
/// the repository.
///
/// Resolution runs in two steps, most-specific first:
///
///  1. **The running process's own bundle.** A Cursor helper executes from
///     inside `Cursor.app`, so the path names the bundle exactly — including
///     the case where it was installed to `~/Applications` or staged in a temp
///     directory by an in-place updater.
///  2. **The vendor's desktop app, by name.** A CLI agent has no bundle of its
///     own; `claude` is a bare binary. But Claude Code and Claude the desktop
///     app are one product to the person looking at the list, so the desktop
///     icon is the right picture for both — when it is installed.
///
/// When neither finds anything, the caller falls back to the SF Symbol. An
/// icon is a nicety; a row that fails to render is not.
enum ToolIcon {

    /// Resolved images, keyed by bundle path. `NSWorkspace.icon(forFile:)` hits
    /// the filesystem and decodes an ICNS, which is far too much to repeat for
    /// every row on every 2-second refresh.
    private static var images: [String: NSImage] = [:]

    /// Bundle lookups that already failed, so a machine without Cursor
    /// installed does not re-scan the same directories forever.
    private static var resolved: [Tool: String?] = [:]

    /// The bundle a path executes from, if any.
    ///
    /// Takes the *first* `.app/` in the path rather than the last: an Electron
    /// helper lives at `Cursor.app/Contents/Frameworks/Cursor Helper.app/…`,
    /// and the product is the outer bundle, not the helper's own.
    static func bundlePath(forExecutable path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[path.startIndex..<range.lowerBound]) + ".app"
    }

    /// Desktop apps to fall back to, per tool. A CLI agent borrows its vendor's
    /// icon; that is the association a user already has.
    private static func fallbackAppNames(for tool: Tool) -> [String] {
        switch tool {
        case .claudeCode, .claudeDesktop: return ["Claude"]
        case .codex: return ["ChatGPT"]
        case .cursor, .cursorAgent: return ["Cursor"]
        case .windsurf: return ["Windsurf"]
        case .copilot: return ["GitHub Copilot", "Visual Studio Code"]
        // The CLI ships as an app bundle of its own, so a running agent
        // usually resolves through its executable path before reaching here;
        // this is for a symlinked or copied binary. The IDE and Crew are the
        // next best pictures of the same product.
        case .kiroCLI: return ["Kiro CLI", "Kiro", "KiroCrew"]
        case .kiroCrew: return ["KiroCrew", "Kiro Crew", "Kiro"]
        case .kiro: return ["Kiro"]
        case .antigravity: return ["Antigravity", "Antigravity IDE"]
        }
    }

    private static var searchDirectories: [String] {
        var dirs = ["/Applications", "/Applications/Utilities"]
        if let home = FileManager.default.homeDirectoryForCurrentUser.path as String? {
            dirs.append(home + "/Applications")
        }
        return dirs
    }

    /// The icon for an agent, from the **root** process's executable path.
    ///
    /// Takes one path, not the group's, and that is the whole point. Searching
    /// every process in the group for a bundle looks more thorough and is
    /// wrong: an MCP server can be any binary at all, including one that lives
    /// inside somebody else's app. A Claude Code agent running an MCP server
    /// from `/Applications/Pencil.app/...` was drawn with Pencil's icon.
    ///
    /// A child's bundle identifies the child. Only the root identifies the
    /// agent — the same rule `ToolCatalog` already follows when it attributes a
    /// child to its parent's tool rather than recognising it on its own.
    @MainActor
    static func image(for tool: Tool, executablePath path: String?) -> NSImage? {
        if let path, let bundle = bundlePath(forExecutable: path) {
            if let cached = images[bundle] { return cached }
            if FileManager.default.fileExists(atPath: bundle) {
                let icon = NSWorkspace.shared.icon(forFile: bundle)
                images[bundle] = icon
                return icon
            }
        }
        return vendorImage(for: tool)
    }

    /// The vendor's desktop icon, or nil when that app is not installed.
    @MainActor
    static func vendorImage(for tool: Tool) -> NSImage? {
        if let known = resolved[tool] {
            return known.flatMap { images[$0] }
        }
        for name in fallbackAppNames(for: tool) {
            for directory in searchDirectories {
                let candidate = "\(directory)/\(name).app"
                guard FileManager.default.fileExists(atPath: candidate) else { continue }
                let icon = NSWorkspace.shared.icon(forFile: candidate)
                images[candidate] = icon
                resolved[tool] = candidate
                return icon
            }
        }
        resolved[tool] = String?.none
        return nil
    }
}

/// A tool's mark: its real app icon when this Mac has one, else the symbol.
///
/// Deliberately not tinted. A real icon carries the product's own colour, and
/// recolouring it would both look wrong and defeat the point of showing it.
/// The row's colour spine still does the scan-down-the-list job.
///
/// Claude Code and Claude the desktop app therefore wear the same icon, which
/// is right — they are one product — but leaves them indistinguishable in a
/// list where one is a terminal session in a project and the other is a chat
/// window. A `$` badge marks the terminal ones, so the brand stays intact and
/// the distinction is still there to read.
struct ToolGlyph: View {
    let tool: Tool
    /// The root process's executable path — never a child's. See
    /// `ToolIcon.image(for:executablePath:)`.
    var executablePath: String?
    /// Whether this agent has a controlling terminal.
    ///
    /// Taken from the process, not from which tool it is: `.codex` covers both
    /// the CLI and the processes inside ChatGPT.app, and only one of those is a
    /// terminal session. The kernel already knows which.
    var terminal = false
    var size: CGFloat = 16

    var body: some View {
        if let icon = ToolIcon.image(for: tool, executablePath: executablePath) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .overlay(alignment: .bottomTrailing) {
                    if terminal { TerminalBadge(size: size) }
                }
        } else {
            // No badge here: the fallback symbol for a CLI tool is already a
            // terminal, and stamping a `$` on a terminal glyph says it twice.
            Image(systemName: tool.symbol)
                .font(.system(size: size * 0.85))
                .foregroundStyle(Theme.accent(for: tool))
                .frame(width: size, height: size)
        }
    }
}

/// The shell-prompt `$`, small enough to read as a modifier rather than a
/// second icon.
private struct TerminalBadge: View {
    let size: CGFloat

    var body: some View {
        let diameter = max(9, size * 0.55)
        Text("$")
            .font(.system(size: diameter * 0.72, weight: .bold, design: .monospaced))
            .foregroundStyle(Color(nsColor: .controlBackgroundColor))
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(Color.primary.opacity(0.75)))
            // A ring in the row's own colour, so the badge reads as sitting on
            // top of the icon rather than being part of the artwork.
            .overlay(
                Circle().strokeBorder(Theme.rowBackground, lineWidth: 1.2)
            )
            // Hangs off the corner: centred on the icon's edge it would cover
            // the artwork it is meant to annotate.
            .offset(x: diameter * 0.28, y: diameter * 0.28)
    }
}
