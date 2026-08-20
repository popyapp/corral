import Foundation

/// Walks the catalog, measures what is actually there, and moves the chosen
/// items to the Trash.
enum DiskScanner {

    // ─ Scan ─────────────────────────────────────────────────────────────────

    /// Measure every catalog entry that exists. Slow — a 10 GB directory takes
    /// real time to add up — so callers run it off the main thread and pass a
    /// `progress` callback to fill the list in as it goes.
    static func scan(
        runningVersions: Set<String> = [],
        progress: (@Sendable (DiskItem) -> Void)? = nil
    ) -> [DiskItem] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let fm = FileManager.default
        var items: [DiskItem] = []

        for entry in DiskCatalog.entries {
            let url = home.appendingPathComponent(entry.relativePath)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }

            if entry.perChild, isDirectory.boolValue {
                items.append(contentsOf: versionedChildren(
                    of: url, entry: entry, runningVersions: runningVersions, progress: progress
                ))
            } else {
                let size = size(of: url)
                guard size > 0 else { continue }
                let item = DiskItem(
                    url: url, tool: entry.tool, title: entry.title,
                    detail: entry.detail, safety: entry.safety, size: size
                )
                progress?(item)
                items.append(item)
            }
        }
        return items
    }

    /// A versioned install directory: keep the newest, offer the rest.
    ///
    /// "Newest" is by version string, not by file date — an update can touch an
    /// old directory's mtime and we would then offer to delete the one in use.
    /// Anything currently running is excluded outright, whatever its number.
    private static func versionedChildren(
        of url: URL,
        entry: DiskCatalog.Entry,
        runningVersions: Set<String>,
        progress: (@Sendable (DiskItem) -> Void)?
    ) -> [DiskItem] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: url.path) else { return [] }

        let versions = names.filter { !$0.hasPrefix(".") }
        guard versions.count > 1 else { return [] }   // nothing superseded yet

        let newest = versions.max { compareVersions($0, $1) == .orderedAscending }

        var items: [DiskItem] = []
        for name in versions.sorted(by: { compareVersions($0, $1) == .orderedDescending }) {
            if name == newest { continue }
            if runningVersions.contains(name) { continue }

            let child = url.appendingPathComponent(name)
            let size = size(of: child)
            guard size > 0 else { continue }
            let item = DiskItem(
                url: child,
                tool: entry.tool,
                title: "\(entry.title) · \(name)",
                detail: entry.detail,
                safety: entry.safety,
                size: size
            )
            progress?(item)
            items.append(item)
        }
        return items
    }

    /// Compare dotted version strings numerically, so 2.1.9 sorts below 2.1.10
    /// — which a plain string comparison gets backwards.
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let lhs = a.split(separator: ".").map { Int($0) ?? -1 }
        let rhs = b.split(separator: ".").map { Int($0) ?? -1 }
        for i in 0..<max(lhs.count, rhs.count) {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    // ─ Sizing ───────────────────────────────────────────────────────────────

    /// Disk usage of a file or directory, counting allocated size so the total
    /// matches what the Finder and `du` report rather than the logical length.
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        ]

        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
           values.isDirectory == false {
            return fileSize(url, keys: keys)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles.subtracting(.skipsHiddenFiles)]
        ) else { return 0 }

        var total: Int64 = 0
        for case let child as URL in enumerator {
            total += fileSize(child, keys: keys)
        }
        return total
    }

    private static func fileSize(_ url: URL, keys: Set<URLResourceKey>) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard values.isRegularFile != false else { return 0 }
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }

    // ─ Removal ──────────────────────────────────────────────────────────────

    struct RemovalResult {
        let removed: [DiskItem]
        let failed: [(item: DiskItem, reason: String)]
        var freedBytes: Int64 { removed.reduce(0) { $0 + $1.size } }
    }

    /// Move items to the Trash. Never `removeItem` — a wrong call here costs
    /// someone their conversation history, and the Trash makes that a mistake
    /// rather than a catastrophe.
    static func remove(_ items: [DiskItem]) -> RemovalResult {
        var removed: [DiskItem] = []
        var failed: [(DiskItem, String)] = []

        for item in items {
            guard DiskCatalog.isRemovable(item.url) else {
                failed.append((item, "outside the folders Corral is allowed to touch"))
                continue
            }
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                removed.append(item)
            } catch {
                failed.append((item, error.localizedDescription))
            }
        }
        return RemovalResult(removed: removed, failed: failed)
    }
}
