import AppKit
import Combine
import SwiftUI

/// The menu bar item.
///
/// The window is where you go to do something about your agents. The menu bar
/// is where you find out you need to — a glance at the top right, without
/// opening anything. So the item carries the one number that matters, its
/// tooltip carries the summary, and its menu names whatever is currently
/// costing you the most.
@MainActor
final class StatusItemController {

    /// A group is "hot" above this share of one core. Agents idle for days sit
    /// near zero, so anything sustained above a few percent is genuinely doing
    /// something — and worth surfacing before you go looking.
    static let hotCPU = 0.08
    /// Or above this much memory, which is where a forgotten dev server lands.
    static let hotMemory: UInt64 = 400 * 1024 * 1024

    private let item: NSStatusItem
    private let model: CorralViewModel
    private var cancellables = Set<AnyCancellable>()

    init(model: CorralViewModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.delegate = MenuBuilder.shared
        MenuBuilder.shared.controller = self
        item.menu = menu

        // Rebuild the button whenever the inventory changes, which is every
        // couple of seconds — cheap, since it is a symbol and a short string.
        model.$groups
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton() }
            .store(in: &cancellables)

        updateButton()
    }

    // ─ The button ───────────────────────────────────────────────────────────

    private func updateButton() {
        guard let button = item.button else { return }

        let totals = model.totals
        let hot = hotGroups

        let symbol = totals.agents == 0 ? "gauge.low" : "speedometer"
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: "Corral"
        )
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading

        // A count only earns its space when there is something to count. When
        // something is hot the number is what you want to see, so it wins.
        if let top = hot.first {
            button.title = " \(Int(model.activity(for: top.root.pid).cpuLoad * 100))%"
        } else if totals.agents > 0 {
            button.title = " \(totals.agents)"
        } else {
            button.title = ""
        }

        button.toolTip = tooltip
    }

    private var tooltip: String {
        let totals = model.totals
        guard totals.agents > 0 else { return "Corral — no agents running" }

        var lines = [
            "\(totals.agents) agents · \(totals.residentBytes.byteString) · "
                + "\(totals.projects) projects",
        ]
        if totals.idleAgents > 0 {
            lines.append("\(totals.idleAgents) idle")
        }
        let hot = hotGroups
        if hot.isEmpty {
            lines.append("Nothing is working hard right now.")
        } else {
            lines.append("")
            lines.append("Busiest:")
            for group in hot.prefix(3) {
                lines.append("  \(describe(group))")
            }
        }
        return lines.joined(separator: "\n")
    }

    // ─ What counts as busy ──────────────────────────────────────────────────

    /// Groups worth interrupting someone about, worst first. CPU decides the
    /// order because it is what you feel; memory gets a group in on its own if
    /// it is large enough.
    var hotGroups: [AgentGroup] {
        model.groups
            .filter { group in
                model.activity(for: group.root.pid).cpuLoad >= Self.hotCPU
                    || group.totalResidentBytes >= Self.hotMemory
            }
            .sorted { a, b in
                let cpuA = model.activity(for: a.root.pid).cpuLoad
                let cpuB = model.activity(for: b.root.pid).cpuLoad
                if abs(cpuA - cpuB) > 0.005 { return cpuA > cpuB }
                return a.totalResidentBytes > b.totalResidentBytes
            }
    }

    func describe(_ group: AgentGroup) -> String {
        let load = model.activity(for: group.root.pid).cpuLoad
        let cpu = load >= 0.01 ? String(format: "%.0f%% cpu · ", load * 100) : ""
        return "\(model.label(for: group)) — \(cpu)\(group.totalResidentBytes.byteString)"
    }

    // ─ Menu ─────────────────────────────────────────────────────────────────

    func buildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let totals = model.totals
        if totals.agents == 0 {
            menu.addItem(disabled("No agents running"))
        } else {
            menu.addItem(disabled(
                "\(totals.agents) agents · \(totals.residentBytes.byteString) · "
                    + "\(totals.projects) projects"
            ))

            let hot = hotGroups
            if hot.isEmpty {
                menu.addItem(disabled("Nothing is working hard right now"))
            } else {
                menu.addItem(.separator())
                menu.addItem(disabled("BUSIEST"))
                for group in hot.prefix(6) {
                    let entry = NSMenuItem(
                        title: describe(group),
                        action: #selector(MenuBuilder.openForGroup(_:)),
                        keyEquivalent: ""
                    )
                    entry.target = MenuBuilder.shared
                    entry.representedObject = group.root.pid
                    entry.image = dot(for: group)
                    menu.addItem(entry)
                }
            }

            if !model.staleGroups.isEmpty {
                menu.addItem(.separator())
                menu.addItem(disabled(
                    "\(model.staleGroups.count) idle · "
                        + "\(model.reclaimableBytes.byteString) reclaimable"
                ))
            }
        }

        menu.addItem(.separator())
        let open = NSMenuItem(
            title: "Open Corral",
            action: #selector(MenuBuilder.openWindow),
            keyEquivalent: ""
        )
        open.target = MenuBuilder.shared
        menu.addItem(open)

        let quit = NSMenuItem(
            title: "Quit Corral",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    /// A coloured dot so the list is scannable without reading it.
    private func dot(for group: AgentGroup) -> NSImage? {
        let load = model.activity(for: group.root.pid).cpuLoad
        let colour: NSColor = load >= 0.30
            ? .systemRed
            : (load >= Self.hotCPU ? .systemOrange : .systemGray)

        let size = NSSize(width: 9, height: 9)
        let image = NSImage(size: size)
        image.lockFocus()
        colour.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }

    // ─ Actions ──────────────────────────────────────────────────────────────

    func open(selecting pid: pid_t?) {
        if let pid { model.selection = pid }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Reopening is what brings the SwiftUI WindowGroup's window back after
        // it has been closed; ordering an existing window front handles the
        // case where it is merely hidden.
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.sendAction(
                #selector(NSApplication.newWindowForTab(_:)), to: nil, from: nil
            )
        }
    }
}

/// A small Objective-C shim: `NSMenu` needs a target that responds to
/// selectors, which a `@MainActor` Swift class with generics cannot be.
final class MenuBuilder: NSObject, NSMenuDelegate {
    static let shared = MenuBuilder()
    weak var controller: StatusItemController?

    func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { controller?.buildMenu(menu) }
    }

    @objc func openForGroup(_ sender: NSMenuItem) {
        let pid = sender.representedObject as? pid_t
        MainActor.assumeIsolated { controller?.open(selecting: pid) }
    }

    @objc func openWindow() {
        MainActor.assumeIsolated { controller?.open(selecting: nil) }
    }
}
