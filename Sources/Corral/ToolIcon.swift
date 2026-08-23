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
        }
    }

    private static var searchDirectories: [String] {
        var dirs = ["/Applications", "/Applications/Utilities"]
        if let home = FileManager.default.homeDirectoryForCurrentUser.path as String? {
            dirs.append(home + "/Applications")
        }
        return dirs
    }

    /// The icon for a group, given the executable paths of its processes.
    ///
    /// `paths` should be every process in the group: the agent itself may be a
    /// bare binary while one of its children runs from inside the bundle, and
    /// either one is enough to find the product.
    @MainActor
    static func image(for tool: Tool, executablePaths paths: [String]) -> NSImage? {
        for path in paths {
            if let bundle = bundlePath(forExecutable: path) {
                if let cached = images[bundle] { return cached }
                if FileManager.default.fileExists(atPath: bundle) {
                    let icon = NSWorkspace.shared.icon(forFile: bundle)
                    images[bundle] = icon
                    return icon
                }
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
struct ToolGlyph: View {
    let tool: Tool
    var executablePaths: [String] = []
    var size: CGFloat = 16

    var body: some View {
        if let icon = ToolIcon.image(for: tool, executablePaths: executablePaths) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: tool.symbol)
                .font(.system(size: size * 0.85))
                .foregroundStyle(Theme.accent(for: tool))
                .frame(width: size, height: size)
        }
    }
}
