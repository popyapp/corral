import Foundation
import SwiftUI

@MainActor
final class DiskViewModel: ObservableObject {

    @Published private(set) var items: [DiskItem] = []
    @Published private(set) var scanning = false
    @Published var selected: Set<String> = []
    @Published var query: String = ""
    @Published var banner: CorralViewModel.Banner?

    /// Versions currently executing, which must never be offered for deletion
    /// however old their version number looks.
    var runningVersions: Set<String> = []

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
    var selectedBytes: Int64 {
        items.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size }
    }
    var hasSelection: Bool { !selected.isEmpty }

    /// Grouped for display: safest first, biggest first within a group.
    var visibleItems: [DiskItem] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return items }
        return items.filter { item in
            [item.title, item.displayPath, item.url.path, item.tool.displayName, item.detail]
                .contains { $0.lowercased().contains(needle) }
        }
    }

    var searchHidEverything: Bool { !items.isEmpty && visibleItems.isEmpty }

    var sections: [(safety: Safety, items: [DiskItem])] {
        let grouped = Dictionary(grouping: visibleItems, by: \.safety)
        return [Safety.safe, .redownload, .userData].compactMap { safety in
            guard let group = grouped[safety], !group.isEmpty else { return nil }
            return (safety, group.sorted { $0.size > $1.size })
        }
    }

    func bytes(for safety: Safety) -> Int64 {
        items.filter { $0.safety == safety }.reduce(0) { $0 + $1.size }
    }

    // ─ Scan ─────────────────────────────────────────────────────────────────

    func scan() {
        guard !scanning else { return }
        scanning = true
        items = []
        selected = []
        let running = runningVersions

        Task.detached(priority: .utility) {
            // Adding up a 10 GB directory takes a moment. Publish each item as
            // it lands so the list fills in rather than staring at a spinner.
            let found = DiskScanner.scan(runningVersions: running) { item in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.items.append(item)
                    if item.safety.selectedByDefault { self.selected.insert(item.id) }
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.items = found.sorted { $0.size > $1.size }
                self.selected = Set(
                    found.filter { $0.safety.selectedByDefault }.map(\.id)
                )
                self.scanning = false
            }
        }
    }

    // ─ Selection ────────────────────────────────────────────────────────────

    func toggle(_ item: DiskItem) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    func isSelected(_ item: DiskItem) -> Bool { selected.contains(item.id) }

    func selectAll(in safety: Safety) {
        for item in items where item.safety == safety { selected.insert(item.id) }
    }

    func deselectAll(in safety: Safety) {
        for item in items where item.safety == safety { selected.remove(item.id) }
    }

    func allSelected(in safety: Safety) -> Bool {
        let group = items.filter { $0.safety == safety }
        return !group.isEmpty && group.allSatisfy { selected.contains($0.id) }
    }

    /// True when anything the user has ticked is their own data — the case
    /// worth a louder confirmation.
    var selectionIncludesUserData: Bool {
        items.contains { selected.contains($0.id) && $0.safety == .userData }
    }

    // ─ Removal ──────────────────────────────────────────────────────────────

    func removeSelected() {
        let targets = items.filter { selected.contains($0.id) }
        guard !targets.isEmpty else { return }

        let result = DiskScanner.remove(targets)
        if result.failed.isEmpty {
            banner = CorralViewModel.Banner(
                kind: .success,
                text: "Moved \(result.removed.count) item(s) to the Trash · \(result.freedBytes.byteString) freed"
            )
        } else {
            let first = result.failed[0]
            banner = CorralViewModel.Banner(
                kind: .warning,
                text: result.removed.isEmpty
                    ? "Couldn't remove \(first.item.title): \(first.reason)"
                    : "Freed \(result.freedBytes.byteString); \(result.failed.count) item(s) couldn't be removed"
            )
        }

        let removedIDs = Set(result.removed.map(\.id))
        items.removeAll { removedIDs.contains($0.id) }
        selected.subtract(removedIDs)
    }

    func reveal(_ item: DiskItem) {
        NSWorkspace.shared.selectFile(item.url.path, inFileViewerRootedAtPath: item.url.deletingLastPathComponent().path)
    }
}

#if canImport(AppKit)
import AppKit
#endif
