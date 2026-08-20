import Foundation

/// Terminal mode. Same inventory the window shows, printed — useful on a
/// headless box, in a script, or when the thing eating your CPU is the reason
/// you can't open a GUI.
enum CLI {

    static func list(json: Bool, search: String? = nil) {
        let inventory = AgentInventory()
        inventory.refresh()

        // Idle is a delta between two samples, so a one-shot run has to take
        // both. A second is long enough to separate "waiting for input" from
        // "compiling", and short enough that nobody minds.
        Thread.sleep(forTimeInterval: 1.0)
        inventory.refresh()

        let needle = search?.trimmingCharacters(in: .whitespaces).lowercased()
        let groups = (needle?.isEmpty == false)
            ? inventory.groups.filter { matches($0, needle!) }
            : inventory.groups

        json ? printJSON(inventory, groups: groups)
             : printTable(inventory, groups: groups, search: needle)
    }

    /// Same fields the window searches, so `--search api` and typing "api" in
    /// the app agree about what matches.
    static func matches(_ group: AgentGroup, _ needle: String) -> Bool {
        let root = group.root
        var haystacks = [root.tool.displayName, root.tool.vendor, "\(root.pid)", root.comm]
        if let project = root.projectName { haystacks.append(project) }
        if let path = root.workingDirectory { haystacks.append(path) }
        if let version = root.version { haystacks.append(version) }
        if let exec = root.executablePath { haystacks.append(exec) }
        if let tty = root.tty { haystacks.append(tty) }
        haystacks.append(root.arguments.joined(separator: " "))
        for child in group.children {
            haystacks.append(contentsOf: [
                child.comm, child.role.label, child.arguments.joined(separator: " "),
            ])
        }
        return haystacks.contains { $0.lowercased().contains(needle) }
    }

    /// `--disk`: what the tools have left behind, grouped by how safe it is to
    /// remove. Read-only — nothing is deleted from the terminal.
    static func disk() {
        let inventory = AgentInventory()
        inventory.refresh()
        let running = Set(inventory.groups.compactMap { $0.root.version })

        let items = DiskScanner.scan(runningVersions: running)
        guard !items.isEmpty else {
            print("Nothing found on disk.")
            return
        }

        let total = items.reduce(Int64(0)) { $0 + $1.size }
        print("")
        print("  \(items.count) items · \(total.byteString) total")
        if !running.isEmpty {
            print("  (skipping versions in use: \(running.sorted().joined(separator: ", ")))")
        }
        print("")

        for safety in [Safety.safe, .redownload, .userData] {
            let group = items.filter { $0.safety == safety }.sorted { $0.size > $1.size }
            guard !group.isEmpty else { continue }
            let subtotal = group.reduce(Int64(0)) { $0 + $1.size }
            print("  \(safety.title.uppercased()) — \(subtotal.byteString)")
            for item in group {
                let size = item.size.byteString.padding(
                    toLength: 11, withPad: " ", startingAt: 0
                )
                print("    \(size) \(item.title)")
                print("                \(item.displayPath)")
            }
            print("")
        }
        print("  Nothing was deleted. Use the app's \"On disk\" tab to remove items.")
        print("")
    }

    /// `--bench`: how long a refresh actually costs, with no UI in the way.
    /// A monitor that shows you what is eating your CPU has no business being
    /// on that list itself, so this number gets measured rather than assumed.
    static func bench(iterations: Int = 30) {
        let inventory = AgentInventory()
        inventory.refresh()   // warm the caches, as the running app would be

        var samples: [Double] = []
        for _ in 0..<iterations {
            let start = Date()
            inventory.refresh()
            samples.append(Date().timeIntervalSince(start))
        }
        // Phase breakdown, so the next person optimising this starts from a
        // measurement instead of a hunch.
        var lightTotal = 0.0, enrichTotal = 0.0
        for _ in 0..<10 {
            var start = Date()
            let lights = ProcessScanner.scanLightweight()
            lightTotal += Date().timeIntervalSince(start)

            let agents = lights.filter {
                $0.executablePath.map(ToolCatalog.pathLooksLikeATool) ?? false
            }
            start = Date()
            for light in agents { _ = ProcessScanner.enrich(light) }
            enrichTotal += Date().timeIntervalSince(start)
        }
        print(String(format: "  scanLightweight: %.1f ms   enrich(%d): %.1f ms",
                     lightTotal / 10 * 1000,
                     ProcessScanner.scanLightweight().filter {
                         $0.executablePath.map(ToolCatalog.pathLooksLikeATool) ?? false
                     }.count,
                     enrichTotal / 10 * 1000))

        let sorted = samples.sorted()
        let mean = samples.reduce(0, +) / Double(samples.count)
        let median = sorted[sorted.count / 2]
        print(String(format: "refresh: mean %.1f ms · median %.1f ms · max %.1f ms  (%d processes, %d agents)",
                     mean * 1000, median * 1000, (sorted.last ?? 0) * 1000,
                     ProcessScanner.scanLightweight().count, inventory.groups.count))
        print(String(format: "at a 2 s interval that is %.1f%% of one core", mean / 2.0 * 100))
    }

    // ─ Table ────────────────────────────────────────────────────────────────

    private static func printTable(
        _ inventory: AgentInventory,
        groups: [AgentGroup],
        search: String?
    ) {
        guard !inventory.groups.isEmpty else {
            print("No AI coding agents running.")
            return
        }
        guard !groups.isEmpty else {
            print("Nothing matches \"\(search ?? "")\" — \(inventory.groups.count) agents running.")
            return
        }

        let totals = inventory.totals
        print("")
        if groups.count != totals.agents {
            print("  \(groups.count) of \(totals.agents) agents match \"\(search ?? "")\"")
        } else {
            print("  \(totals.agents) agents · \(totals.processes) processes · "
                + "\(totals.residentBytes.byteString) · \(totals.projects) projects"
                + (totals.idleAgents > 0 ? " · \(totals.idleAgents) idle" : ""))
        }
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

    private static func printJSON(_ inventory: AgentInventory, groups: [AgentGroup]) {
        let payload: [String: Any] = [
            "totals": [
                "agents": inventory.totals.agents,
                "processes": inventory.totals.processes,
                "resident_bytes": inventory.totals.residentBytes,
                "projects": inventory.totals.projects,
                "idle_agents": inventory.totals.idleAgents,
            ],
            "agents": groups.map { group in
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
