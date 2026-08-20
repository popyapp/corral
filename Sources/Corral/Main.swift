import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--version") {
            print("Corral \(BuildInfo.display)")
            return
        }
        if args.contains("--bench") {
            CLI.bench()
            return
        }
        if args.contains("--disk") {
            CLI.disk()
            return
        }
        if args.contains("--list") {
            var filter: String?
            if let i = args.firstIndex(of: "--search"), args.count > i + 1 {
                filter = args[i + 1]
            }
            CLI.list(json: args.contains("--json"), search: filter)
            return
        }
        if args.contains("--help") || args.contains("-h") {
            print("""
            Corral \(BuildInfo.display) — see what your AI coding agents are doing

              Corral               open the window
              Corral --list        print running agents
              Corral --list --search <text>
                                   only agents matching a project, tool or pid
              Corral --disk        print what the tools have left on disk
              Corral --list --json machine-readable output
              Corral --version     print version
            """)
            return
        }
        CorralApp.main()
    }
}

struct CorralApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Corral") {
            RootView()
                .environmentObject(AppState.shared.agents)
                .environmentObject(AppState.shared.disk)
                .frame(minWidth: 880, minHeight: 540)
        }
        .windowToolbarStyle(.unifiedCompact)
    }
}

/// The view models outlive the window.
///
/// Corral keeps running with its window closed — the menu bar item is the whole
/// point of it being open at all — so the models cannot be `@StateObject`s owned
/// by a scene that comes and goes. The app delegate needs them too, for the
/// status item.
@MainActor
final class AppState {
    static let shared = AppState()
    let agents = CorralViewModel()
    let disk = DiskViewModel()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated {
            statusItem = StatusItemController(model: AppState.shared.agents)
        }
    }

    /// Closing the window puts Corral in the background rather than quitting.
    /// A monitor you have to keep a window open for is not a monitor; the menu
    /// bar item stays, and Quit is on its menu.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the dock icon with no window open brings one back.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        if !hasVisibleWindows {
            MainActor.assumeIsolated { AppState.shared.agents.selection = nil }
        }
        return true
    }
}
