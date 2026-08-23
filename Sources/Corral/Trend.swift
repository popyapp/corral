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

    /// How much time one column covers. Chosen so every range draws a similar
    /// number of columns — a fixed slice across all three would make the
    /// 15-minute view six bars wide or the 3-hour view a thousand.
    var sliceSeconds: TimeInterval {
        switch self {
        case .fifteenMinutes: return 10
        case .hour: return 30
        case .threeHours: return 60
        }
    }

    /// Columns in the grid. Fixed for the range, whatever history exists.
    var columnCount: Int { Int(seconds / sliceSeconds) }

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
/// Samples arrive every two seconds and are averaged into 10-second buckets;
/// three hours of them are kept, the longest range the header offers.
///
/// Buckets are stored with their absolute index rather than as a plain array,
/// so a gap is a real gap. A Mac that slept for an hour did not hold a steady
/// value through it, and drawing a flat line across that stretch would be a
/// claim Corral cannot make.
struct TrendBuffer {
    /// The finest slice any range asks for, so every range can be built by
    /// aggregating buckets rather than interpolating between them.
    static let bucketSeconds: TimeInterval = 10

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

    /// Values on a fixed grid anchored at `now`: one slot per slice of `range`,
    /// oldest on the left, the live moment at the right edge.
    ///
    /// This is the difference between a graph and a picture of one. Spreading
    /// whatever history exists across the full width made five minutes of data
    /// fill a three-hour chart, so the axis said one thing and the bars another.
    /// Here a slot with no samples in it is nil and stays empty, and the graph
    /// fills in from the right as time passes — which is also what makes the
    /// three ranges comparable to each other.
    func columns(_ range: TrendRange, now: Date = Date()) -> [Double?] {
        let count = range.columnCount
        var sums = [Double](repeating: 0, count: count)
        var hits = [Int](repeating: 0, count: count)

        var all = buckets
        if let openIndex, let live { all.append(Bucket(index: openIndex, value: live)) }

        for bucket in all {
            let start = Double(bucket.index) * Self.bucketSeconds
            let age = now.timeIntervalSince1970 - start
            guard age >= 0 else { continue }
            let slot = count - 1 - Int(age / range.sliceSeconds)
            guard slot >= 0, slot < count else { continue }
            sums[slot] += bucket.value
            hits[slot] += 1
        }
        return (0..<count).map { hits[$0] == 0 ? nil : sums[$0] / Double(hits[$0]) }
    }
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
        /// How far back the column sits, measured from the graph's right edge.
        let age: TimeInterval
    }

    /// One slot per slice of `range`, oldest first; nil where nothing was
    /// recorded. Built by `TrendBuffer.columns(_:now:)`.
    let columns: [Double?]
    let range: TrendRange
    var color: Color = Theme.trend
    /// Forces the y-axis to start at zero. Right for counts, where a floor of
    /// zero is meaningful; wrong for memory, where every agent holds a hundred
    /// megabytes and a zero floor would flatten every real change into nothing.
    var zeroBased = false
    /// Fires as the pointer moves across the columns, and once with nil when it
    /// leaves.
    var onProbe: ((Probe?) -> Void)?

    @State private var hovered: Int?

    var body: some View {
        GeometryReader { geometry in
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                guard columns.contains(where: { $0 != nil }) else { return }
                draw(grid: context, size: size)
                draw(bars: context, size: size)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    probe(at: location, width: geometry.size.width)
                case .ended:
                    if hovered != nil { hovered = nil }
                    onProbe?(nil)
                }
            }
        }
    }

    // ─ Pointer ──────────────────────────────────────────────────────────────

    private func probe(at location: CGPoint, width: CGFloat) {
        guard width > 0, !columns.isEmpty else { return }
        let slot = width / CGFloat(columns.count)
        let index = min(max(Int(location.x / slot), 0), columns.count - 1)
        if hovered != index { hovered = index }
        guard let value = columns[index] else {
            // An empty slot: nothing was recorded for that moment, and there is
            // nothing honest to report for it.
            onProbe?(nil)
            return
        }
        onProbe?(Probe(
            value: value,
            age: Double(columns.count - 1 - index) * range.sliceSeconds
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

    private func draw(bars context: GraphicsContext, size: CGSize) {
        let values = columns.compactMap { $0 }
        let top = values.max() ?? 0
        let bottom = zeroBased ? 0 : (values.min() ?? 0)
        let range = top - bottom
        let flat = range < .ulpOfOne

        let slot = size.width / CGFloat(columns.count)
        let barWidth = max(1, slot - 1)
        // The baseline owns the bottom half-pixel; bars sit on it.
        let plotHeight = size.height - 1

        for (index, value) in columns.enumerated() {
            let x = CGFloat(index) * slot

            // The crosshair is drawn over empty slots too, so the pointer never
            // seems to fall off the graph.
            if index == hovered {
                context.fill(
                    Path(CGRect(x: x, y: 0, width: max(barWidth, 1.5), height: size.height)),
                    with: .color(Color.primary.opacity(0.10))
                )
            }

            guard let value else { continue }
            let normalized = flat ? 0.5 : (value - bottom) / range
            // A minimum of one pixel: a genuine zero still leaves a tick, so an
            // empty slot and a zero one do not look the same.
            let height = max(1, CGFloat(normalized) * plotHeight)
            let rect = CGRect(x: x, y: plotHeight - height, width: barWidth, height: height)

            let emphasised = index == columns.count - 1 || index == hovered
            context.fill(Path(rect), with: .color(color.opacity(emphasised ? 1.0 : 0.55)))
        }
    }
}
