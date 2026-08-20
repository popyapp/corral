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
        if args.contains("--list") {
            CLI.list(json: args.contains("--json"))
            return
        }
        if args.contains("--help") || args.contains("-h") {
            print("""
            Corral \(BuildInfo.display) — see what your AI coding agents are doing

              Corral               open the window
              Corral --list        print running agents
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
    @StateObject private var model = CorralViewModel()

    var body: some Scene {
        WindowGroup("Corral") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 520)
        }
        .windowToolbarStyle(.unifiedCompact)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
