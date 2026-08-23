import SwiftUI

/// How far back the header sparklines look.
enum TrendRange: String, CaseIterable, Identifiable {
    case fifteenMinutes, hour, threeHours

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .fifteenMinutes: return 900
        case .hour: return 3_600
        case .threeHours: return 10_800
        }
    }

    var label: String {
        switch self {
        case .fifteenMinutes: return "15m"
        case .hour: return "1h"
        case .threeHours: return "3h"
        }
    }

    /// Clicking the header cycles through the ranges rather than spending a
    /// control on something most people set once.
    var next: TrendRange {
        switch self {
        case .fifteenMinutes: return .hour
        case .hour: return .threeHours
        case .threeHours: return .fifteenMinutes
        }
    }
}

/// Rolling history of one header number.
///
/// Samples arrive every two seconds, but a sparkline 90 points wide cannot show
/// 5,400 of them, so they are averaged into 30-second buckets and the last three
/// hours of buckets are kept — the longest range the header offers.
///
/// Buckets are stored with their absolute index rather than as a plain array,
/// so a gap is a real gap. A Mac that slept for an hour did not hold a steady
/// value through it, and drawing a flat line across that stretch would be a
/// claim Corral cannot make.
struct TrendBuffer {
    static let bucketSeconds: TimeInterval = 30

    struct Bucket: Equatable {
        let index: Int
        let value: Double
    }

    private(set) var buckets: [Bucket] = []

    private var openIndex: Int?
    private var openSum = 0.0
    private var openCount = 0

    /// The in-progress bucket, so the rightmost point tracks live rather than
    /// snapping into place every 30 seconds.
    var live: Double? { openCount > 0 ? openSum / Double(openCount) : nil }

    var latest: Double? { live ?? buckets.last?.value }

    mutating func record(_ value: Double, at date: Date = Date()) {
        let index = Int(date.timeIntervalSince1970 / Self.bucketSeconds)
        if let open = openIndex, open != index {
            buckets.append(Bucket(index: open, value: openSum / Double(max(openCount, 1))))
            openSum = 0
            openCount = 0
        }
        openIndex = index
        openSum += value
        openCount += 1

        let cutoff = index - Int(TrendRange.threeHours.seconds / Self.bucketSeconds)
        if let first = buckets.first, first.index < cutoff {
            buckets.removeAll { $0.index < cutoff }
        }
    }

    /// Buckets inside `range`, plus the live one, oldest first.
    func series(_ range: TrendRange) -> [Bucket] {
        guard let openIndex else { return buckets }
        let span = Int(range.seconds / Self.bucketSeconds)
        var result = buckets.filter { $0.index > openIndex - span }
        if let live { result.append(Bucket(index: openIndex, value: live)) }
        return result
    }

    /// True once there is enough history for a line to mean anything. Two
    /// points is a segment; one is a dot that reads as a flat trend.
    func hasShape(_ range: TrendRange) -> Bool { series(range).count >= 3 }
}

/// The header's trend lines, recorded together so they share a time axis.
struct Trends {
    var cpu = TrendBuffer()
    var memory = TrendBuffer()
    var agents = TrendBuffer()
    var projects = TrendBuffer()

    func series(for metric: TrendMetric) -> TrendBuffer {
        switch metric {
        case .cpu: return cpu
        case .memory: return memory
        case .agents: return agents
        case .projects: return projects
        }
    }
}

/// Which number the header graph is plotting.
///
/// One graph rather than one per figure: four thumbnails at this size say less
/// than a single readable chart, and the question is almost always about one
/// number at a time. CPU is the default because it is the one that made you
/// open the app.
enum TrendMetric: String, CaseIterable, Identifiable {
    case cpu, memory, agents, projects

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .agents: return "Agents"
        case .projects: return "Projects"
        }
    }

    /// Counts and CPU are measured from zero, so their axis starts there.
    /// Memory is not: every agent holds a hundred megabytes before it does
    /// anything, and a zero floor would flatten every real change into nothing.
    var zeroBased: Bool { self != .memory }
}

/// A small history graph: discrete columns on a faint grid.
///
/// Deliberately an instrument readout rather than an infographic. This app's
/// whole claim is that it is Activity Monitor for agents, and Activity
/// Monitor's own CPU history is bars on a graticule — a filled gradient curve
/// would be the wrong dialect, and at this size it also reads as one soft blob
/// where the point is to see individual movements.
///
/// Buckets are resampled to a fixed column count so a 3-hour range and a
/// 15-minute one draw the same number of bars at the same width, instead of
/// the longer range collapsing into a solid block.
struct TrendGraph: View {
    /// One column, read off under the pointer.
    struct Probe: Equatable {
        let value: Double
        /// The start of the 30-second bucket this column covers.
        let at: Date
    }

    let buckets: [TrendBuffer.Bucket]
    var color: Color = Theme.trend
    /// Forces the y-axis to start at zero. Right for counts, where a floor of
    /// zero is meaningful; wrong for memory, where every agent holds a hundred
    /// megabytes and a zero floor would flatten every real change into nothing.
    var zeroBased = false
    var maxColumns = 22
    /// Fires as the pointer moves across the columns, and once with nil when it
    /// leaves.
    var onProbe: ((Probe?) -> Void)?

    @State private var hovered: Int?

    var body: some View {
        GeometryReader { geometry in
            let columns = resample()
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                guard columns.contains(where: { $0 != nil }) else { return }
                draw(grid: context, size: size)
                draw(columns: columns, context: context, size: size)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    probe(at: location, width: geometry.size.width, columns: columns)
                case .ended:
                    if hovered != nil { hovered = nil }
                    onProbe?(nil)
                }
            }
        }
    }

    // ─ Data ─────────────────────────────────────────────────────────────────

    private struct Column {
        let value: Double
        /// The bucket this column stands for, so a reading can be dated.
        let index: Int
    }

    /// One slot per column, nil where no bucket landed — a stretch when Corral
    /// was not running leaves a hole rather than a bar borrowed from its
    /// neighbours.
    private func resample() -> [Column?] {
        guard let first = buckets.first, let last = buckets.last else { return [] }
        let span = last.index - first.index
        // Never more columns than there are buckets to fill them: early on,
        // wide bars are honest, and holes would look like missing data.
        let count = max(1, min(maxColumns, span + 1))

        var sums = [Double](repeating: 0, count: count)
        var hits = [Int](repeating: 0, count: count)
        var latest = [Int](repeating: 0, count: count)
        for bucket in buckets {
            let position = span == 0
                ? 0
                : Int((Double(bucket.index - first.index) / Double(span)) * Double(count - 1))
            let slot = min(max(position, 0), count - 1)
            sums[slot] += bucket.value
            hits[slot] += 1
            latest[slot] = max(latest[slot], bucket.index)
        }
        return (0..<count).map { slot in
            hits[slot] == 0
                ? nil
                : Column(value: sums[slot] / Double(hits[slot]), index: latest[slot])
        }
    }

    private func probe(at location: CGPoint, width: CGFloat, columns: [Column?]) {
        guard width > 0, !columns.isEmpty else { return }
        let slot = width / CGFloat(columns.count)
        let index = min(max(Int(location.x / slot), 0), columns.count - 1)
        if hovered != index { hovered = index }
        guard let column = columns[index] else {
            // A hole: there is genuinely nothing to report for that moment.
            onProbe?(nil)
            return
        }
        onProbe?(Probe(
            value: column.value,
            at: Date(timeIntervalSince1970: Double(column.index) * TrendBuffer.bucketSeconds)
        ))
    }

    // ─ Drawing ──────────────────────────────────────────────────────────────

    private func draw(grid context: GraphicsContext, size: CGSize) {
        let ink = Color.primary.opacity(0.10)

        var midline = Path()
        midline.move(to: CGPoint(x: 0, y: (size.height - 1) / 2))
        midline.addLine(to: CGPoint(x: size.width, y: (size.height - 1) / 2))
        context.stroke(
            midline,
            with: .color(ink),
            style: StrokeStyle(lineWidth: 0.5, dash: [1.5, 2.5])
        )

        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: size.height - 0.25))
        baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.25))
        context.stroke(baseline, with: .color(ink), lineWidth: 0.5)
    }

    private func draw(columns: [Column?], context: GraphicsContext, size: CGSize) {
        let values = columns.compactMap { $0?.value }
        let top = values.max() ?? 0
        let bottom = zeroBased ? 0 : (values.min() ?? 0)
        let range = top - bottom
        let flat = range < .ulpOfOne

        let slot = size.width / CGFloat(columns.count)
        let barWidth = max(1, slot - 1)
        // The baseline owns the bottom half-pixel; bars sit on it.
        let plotHeight = size.height - 1

        for (index, column) in columns.enumerated() {
            let x = CGFloat(index) * slot

            // The crosshair is drawn even over a hole, so the pointer never
            // seems to fall off the graph.
            if index == hovered {
                context.fill(
                    Path(CGRect(x: x, y: 0, width: barWidth, height: size.height)),
                    with: .color(Color.primary.opacity(0.08))
                )
            }

            guard let column else { continue }
            let normalized = flat ? 0.5 : (column.value - bottom) / range
            // A minimum of one pixel: a genuine zero still leaves a tick, so an
            // empty column and a zero column do not look the same.
            let height = max(1, CGFloat(normalized) * plotHeight)
            let rect = CGRect(x: x, y: plotHeight - height, width: barWidth, height: height)

            // The newest column is the live one, so it carries full weight and
            // the history behind it recedes; whatever is under the pointer is
            // brought forward too.
            let emphasised = index == columns.count - 1 || index == hovered
            context.fill(Path(rect), with: .color(color.opacity(emphasised ? 1.0 : 0.55)))
        }
    }
}
