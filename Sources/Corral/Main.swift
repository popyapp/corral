import AppKit
import Combine
import SwiftUI

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        // First, and with no side effects: Claude Code runs this on every
        // status update, so it has to start and finish without touching the
        // process table or drawing anything.
        if args.contains("--statusline") {
            StatusLine.run(tool: StatusLine.tool(from: args))
            return
        }
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
              Corral --statusline <claude|cursor>
                                   status line for that agent; see the menu
            """)
            return
        }
        CorralApp.main()
    }
}

struct CorralApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var appearance = AppearanceController.shared
    @ObservedObject private var panels = PanelSettings.shared
    @ObservedObject private var kiroAccount = KiroAccountSettings.shared

    var body: some Scene {
        WindowGroup("Corral") {
            RootView()
                .environmentObject(AppState.shared.agents)
                .environmentObject(AppState.shared.disk)
                .frame(minWidth: 880, minHeight: 540)
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            // The stock item reads Info.plist directly and cannot show the
            // commit, so it is replaced rather than supplemented — two About
            // items would be worse than one incomplete one.
            CommandGroup(replacing: .appInfo) {
                Button("About Corral") { AboutPanel.show() }
                Divider()
                // Also on the menu bar item's menu. Somebody who turned that
                // off still has to be able to find this.
                Menu("Report Usage to Corral") {
                    ForEach(StatusLineSetup.Target.all, id: \.tool) { agent in
                        Button(agent.name) { StatusLineSetup.offer(agent) }
                    }
                    Divider()
                    // The one network call in the app, behind a dialog that
                    // says so. See `KiroAccount`.
                    Toggle(
                        KiroAccountSetup.title,
                        isOn: Binding(
                            get: { kiroAccount.isEnabled },
                            set: { on in on ? KiroAccountSetup.offer() : KiroAccountSetup.turnOff() }
                        )
                    )
                }
                Picker("Usage Panel", selection: $panels.placement) {
                    ForEach(PanelPlacement.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                // The one place the menu bar item can be turned back *on*, so
                // it is never conditional — only turning it off is, and only
                // when it is the last way back into the app.
                Toggle("Menu Bar Item", isOn: $panels.showsMenuBarItem)
                    .disabled(
                        panels.showsMenuBarItem
                            && panels.wouldStrandTheApp(turningOffMenuBar: true)
                    )
                Divider()
                Picker("Appearance", selection: $appearance.mode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            }
            // The stock Help item searches a help book Corral does not have.
            // What it has is an issue tracker, which is where help comes from.
            CommandGroup(replacing: .help) {
                Button("Report a Problem…") { NSWorkspace.shared.open(BuildInfo.supportURL) }
                Button("Corral on GitHub") { NSWorkspace.shared.open(BuildInfo.repositoryURL) }
            }
        }
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
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated {
            // Before the first window is drawn, so a dark-mode launch never
            // flashes light.
            AppearanceController.shared.apply()

            // The menu bar item is now optional, so it is created and destroyed
            // from the setting rather than owned outright.
            PanelSettings.shared.$showsMenuBarItem
                .removeDuplicates()
                .sink { [weak self] shows in
                    MainActor.assumeIsolated {
                        if shows {
                            guard self?.statusItem == nil else { return }
                            self?.statusItem = StatusItemController(
                                model: AppState.shared.agents
                            )
                        } else {
                            self?.statusItem?.removeFromStatusBar()
                            self?.statusItem = nil
                        }
                    }
                }
                .store(in: &cancellables)

            EdgePanelController.shared.apply(model: AppState.shared.agents)
        }

        // Closing the last window is when Corral leaves the Dock. See
        // `applicationShouldTerminateAfterLastWindowClosed`.
        NotificationCenter.default
            .publisher(for: NSWindow.willCloseNotification)
            .sink { [weak self] notification in
                guard let window = notification.object as? NSWindow, window.canBecomeMain
                else { return }
                MainActor.assumeIsolated { self?.leaveTheDockIfNothingIsOpen(closing: window) }
            }
            .store(in: &cancellables)
    }

    /// Closing the window puts Corral in the background rather than quitting.
    /// A monitor you have to keep a window open for is not a monitor; the menu
    /// bar item stays, and Quit is on its menu.
    ///
    /// Background means background: the Dock icon goes too. An app that keeps
    /// a Dock tile with no window behind it is the thing people force-quit to
    /// tidy up, and the usage panel on the screen edge and the menu bar item
    /// are the two ways back in. Opening the window from either brings the
    /// tile back for as long as the window is open, so ⌘-Tab works while
    /// there is something to switch to.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @MainActor
    private func leaveTheDockIfNothingIsOpen(closing window: NSWindow) {
        // Asked after the close has happened: the notification arrives before
        // the window is gone, so it would still count itself.
        DispatchQueue.main.async {
            let stillOpen = NSApp.windows.contains {
                $0 !== window && $0.canBecomeMain && $0.isVisible
            }
            guard !stillOpen else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Reopening — from the Dock while it is there, or from `open -a Corral`
    /// once it is not — brings a window back, and the Dock tile with it.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        if !hasVisibleWindows {
            NSApp.setActivationPolicy(.regular)
            MainActor.assumeIsolated { AppState.shared.agents.selection = nil }
        }
        return true
    }
}
