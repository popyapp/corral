import Foundation

/// Terminal mode. Same inventory the window shows, printed — useful on a
/// headless box, in a script, or when the thing eating your CPU is the reason
/// you can't open a GUI.
enum CLI {

    static func list(json: Bool) {
        let inventory = AgentInventory()
        inventory.refresh()

        // Idle is a delta between two samples, so a one-shot run has to take
        // both. A second is long enough to separate "waiting for input" from
        // "compiling", and short enough that nobody minds.
        Thread.sleep(forTimeInterval: 1.0)
        inventory.refresh()

        json ? printJSON(inventory) : printTable(inventory)
    }

    // ─ Table ────────────────────────────────────────────────────────────────

    private static func printTable(_ inventory: AgentInventory) {
        let groups = inventory.groups
        guard !groups.isEmpty else {
            print("No AI coding agents running.")
            return
        }

        let totals = inventory.totals
        print("")
        print("  \(totals.agents) agents · \(totals.processes) processes · "
            + "\(totals.residentBytes.byteString) · \(totals.projects) projects"
            + (totals.idleAgents > 0 ? " · \(totals.idleAgents) idle" : ""))
        print("")

        for group in groups {
            let root = group.root
            let act = inventory.activity(for: root.pid)

            let state: String
            if let idle = act.idleFor {
                // Say where the number came from. "idle 3d" measured from the
                // terminal is a fact; measured from our own uptime it is only
                // "quiet since we started looking", and conflating the two
                // would be the app quietly lying about the thing it exists for.
                state = act.idleIsMeasuredFromTerminal
                    ? "idle \(idle.durationString)"
                    : "quiet \(idle.durationString) (since Corral opened)"
            } else {
                state = String(format: "%.0f%% cpu", act.cpuLoad * 100)
            }

            print("  \(root.title)  ·  pid \(root.pid)")
            print("    project   \(root.displayPath ?? "—")")
            print("    up        \(root.uptime.durationString)"
                + "    cpu \(root.cpuSeconds.cpuTimeString)"
                + "    mem \(group.totalResidentBytes.byteString)"
                + "    \(state)")
            if let tty = root.tty {
                print("    tty       \(tty)")
            }
            if !group.children.isEmpty {
                let summary = group.children
                    .map { "\($0.comm) (\($0.role.label), pid \($0.pid))" }
                    .joined(separator: ", ")
                print("    children  \(group.children.count) — \(summary)")
            }
            print("")
        }
    }

    // ─ JSON ─────────────────────────────────────────────────────────────────

    private static func printJSON(_ inventory: AgentInventory) {
        let payload: [String: Any] = [
            "totals": [
                "agents": inventory.totals.agents,
                "processes": inventory.totals.processes,
                "resident_bytes": inventory.totals.residentBytes,
                "projects": inventory.totals.projects,
                "idle_agents": inventory.totals.idleAgents,
            ],
            "agents": inventory.groups.map { group in
                describe(group, inventory: inventory)
            },
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        print(String(decoding: data, as: UTF8.self))
    }

    static func describe(_ group: AgentGroup, inventory: AgentInventory) -> [String: Any] {
        let root = group.root
        let act = inventory.activity(for: root.pid)
        var dict: [String: Any] = [
            "pid": root.pid,
            "ppid": root.ppid,
            "tool": root.tool.rawValue,
            "tool_name": root.tool.displayName,
            "uptime_seconds": Int(root.uptime),
            "cpu_seconds": root.cpuSeconds,
            "resident_bytes": root.residentBytes,
            "group_resident_bytes": group.totalResidentBytes,
            "cpu_load": act.cpuLoad,
            "idle": act.isIdle,
            "children": group.children.map {
                [
                    "pid": $0.pid,
                    "name": $0.comm,
                    "role": $0.role.rawValue,
                    "resident_bytes": $0.residentBytes,
                ] as [String: Any]
            },
        ]
        if let version = root.version { dict["version"] = version }
        if let cwd = root.workingDirectory { dict["working_directory"] = cwd }
        if let project = root.projectName { dict["project"] = project }
        if let path = root.executablePath { dict["executable"] = path }
        if let idle = act.idleFor { dict["idle_seconds"] = Int(idle) }
        return dict
    }
}
