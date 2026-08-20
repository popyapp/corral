import AppKit
import SwiftUI

struct DiskView: View {
    @EnvironmentObject private var disk: DiskViewModel
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if let banner = disk.banner {
                DiskBanner(banner: banner) { disk.banner = nil }
            }
            content
        }
        .onAppear { if disk.items.isEmpty && !disk.scanning { disk.scan() } }
        .confirmationDialog(
            "Move \(disk.selected.count) item(s) to the Trash?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { disk.removeSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    private var confirmMessage: String {
        let base = "This frees \(disk.selectedBytes.byteString). "
            + "Everything goes to the Trash, so you can put it back."
        guard disk.selectionIncludesUserData else { return base }
        return base + "\n\nYour selection includes history Corral did not tick for you — "
            + "conversation transcripts, undo history or extensions. Those do not come back on their own."
    }

    // ─ Header ───────────────────────────────────────────────────────────────

    private var header: some View {
        HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 2) {
                Text("On disk")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(disk.scanning ? "measuring…" : "\(disk.items.count) items found")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.faint)
            }

            Divider().frame(height: 26).opacity(0.4)

            Stat(value: disk.totalBytes.byteString, label: "total")
            Stat(
                value: disk.bytes(for: .safe).byteString,
                label: "caches",
                tint: Theme.Severity.active.color
            )
            if disk.bytes(for: .redownload) > 0 {
                Stat(
                    value: disk.bytes(for: .redownload).byteString,
                    label: "re-downloadable",
                    tint: Theme.Severity.stale.color
                )
            }

            Spacer(minLength: 8)

            if disk.hasSelection {
                Button {
                    confirming = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                        Text("Free \(disk.selectedBytes.byteString)").monospacedDigit()
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent(for: .claudeCode))
            }

            Button { disk.scan() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(disk.scanning)
                .help("Measure again")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // ─ Content ──────────────────────────────────────────────────────────────

    @ViewBuilder
    private var content: some View {
        if disk.items.isEmpty && disk.scanning {
            VStack(spacing: 10) {
                Spacer()
                ProgressView()
                Text("Adding up what your agents have left behind…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.faint)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if disk.items.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "sparkles")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Theme.Severity.active.color)
                Text("Nothing to clean")
                    .font(.system(size: 15, weight: .medium))
                Text("No caches or superseded versions found.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.faint)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(disk.sections, id: \.safety) { section in
                        SafetySection(safety: section.safety, items: section.items)
                    }
                    if disk.scanning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("still measuring…")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.faint)
                        }
                        .padding(.leading, 4)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
        }
    }
}

// ─ Section ──────────────────────────────────────────────────────────────────

private struct SafetySection: View {
    @EnvironmentObject private var disk: DiskViewModel
    let safety: Safety
    let items: [DiskItem]

    private var tint: Color {
        switch safety {
        case .safe: return Theme.Severity.active.color
        case .redownload: return Theme.Severity.stale.color
        case .userData: return Theme.Severity.abandoned.color
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(safety.title)
                    .font(.system(size: 12, weight: .semibold))
                Text(items.reduce(Int64(0)) { $0 + $1.size }.byteString)
                    .font(.system(size: 11, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.faint)
                Spacer()
                Button(disk.allSelected(in: safety) ? "Deselect all" : "Select all") {
                    disk.allSelected(in: safety)
                        ? disk.deselectAll(in: safety)
                        : disk.selectAll(in: safety)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(tint)
            }

            Text(safety.detail)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.faint)
                .padding(.bottom, 1)

            VStack(spacing: 4) {
                ForEach(items) { item in
                    DiskRow(item: item, tint: tint)
                }
            }
        }
    }
}

// ─ Row ──────────────────────────────────────────────────────────────────────

private struct DiskRow: View {
    @EnvironmentObject private var disk: DiskViewModel
    let item: DiskItem
    let tint: Color
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 11) {
            Button {
                disk.toggle(item)
            } label: {
                Image(systemName: disk.isSelected(item) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(disk.isSelected(item) ? tint : Theme.faint)
            }
            .buttonStyle(.plain)

            Image(systemName: item.tool.symbol)
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent(for: item.tool))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Pill(text: item.tool.displayName, color: Theme.accent(for: item.tool))
                }
                Text(item.displayPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 8)

            Text(item.size.byteString)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 68, alignment: .trailing)

            Button {
                disk.reveal(item)
            } label: {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(hovering ? Theme.subtle : Theme.faint.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help("Show in Finder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.rowBackground.opacity(hovering ? 1 : 0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .onHover { hovering = $0 }
        .help(item.detail)
        .contentShape(Rectangle())
        .onTapGesture { disk.toggle(item) }
    }
}

private struct DiskBanner: View {
    let banner: CorralViewModel.Banner
    let dismiss: () -> Void

    var body: some View {
        let color: Color = banner.kind == .success
            ? Theme.Severity.active.color
            : Theme.Severity.stale.color
        HStack(spacing: 8) {
            Image(systemName: banner.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            Text(banner.text).font(.system(size: 11.5))
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(color.opacity(0.10))
    }
}
