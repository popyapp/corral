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
}

/// A small filled line chart with no axes, labels or interaction.
///
/// It answers one question — is this going up or down — and anything else it
/// drew would compete with the number printed directly above it.
struct Sparkline: View {
    let buckets: [TrendBuffer.Bucket]
    var color: Color = Theme.trend
    /// Forces the y-axis to start at zero. Right for counts, where a floor of
    /// zero is meaningful; wrong for memory, where every agent holds a hundred
    /// megabytes and a zero floor would flatten every real change into nothing.
    var zeroBased = false

    var body: some View {
        GeometryReader { geometry in
            let points = layout(in: geometry.size)
            ZStack {
                if points.count >= 2 {
                    fill(points, height: geometry.size.height)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.28), color.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    line(points)
                        .stroke(color, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                }
            }
        }
    }

    // ─ Geometry ─────────────────────────────────────────────────────────────

    /// nil marks a break in the data — a stretch where Corral was not running.
    private func layout(in size: CGSize) -> [CGPoint?] {
        guard let first = buckets.first, let last = buckets.last, buckets.count >= 2 else {
            return []
        }
        let span = Double(max(last.index - first.index, 1))
        let values = buckets.map(\.value)
        let top = values.max() ?? 0
        let bottom = zeroBased ? 0 : (values.min() ?? 0)
        // A dead-flat series would divide by zero; draw it through the middle.
        let range = top - bottom
        let flat = range < .ulpOfOne

        var result: [CGPoint?] = []
        var previousIndex: Int?
        for bucket in buckets {
            if let previous = previousIndex, bucket.index - previous > 1 {
                result.append(nil)
            }
            let x = Double(bucket.index - first.index) / span * size.width
            let normalized = flat ? 0.5 : (bucket.value - bottom) / range
            // Inset by a hair top and bottom so a peak is not clipped by the
            // frame's edge.
            let y = size.height - 1 - normalized * (size.height - 2)
            result.append(CGPoint(x: x, y: y))
            previousIndex = bucket.index
        }
        return result
    }

    private func line(_ points: [CGPoint?]) -> Path {
        var path = Path()
        var penDown = false
        for point in points {
            guard let point else { penDown = false; continue }
            if penDown { path.addLine(to: point) } else { path.move(to: point) }
            penDown = true
        }
        return path
    }

    /// Only the last unbroken run is filled: shading across a gap would imply
    /// the area under a line that was never drawn.
    private func fill(_ points: [CGPoint?], height: CGFloat) -> Path {
        let run = points.split(whereSeparator: { $0 == nil }).last?.compactMap { $0 } ?? []
        guard run.count >= 2, let first = run.first, let last = run.last else { return Path() }
        var path = Path()
        path.move(to: CGPoint(x: first.x, y: height))
        for point in run { path.addLine(to: point) }
        path.addLine(to: CGPoint(x: last.x, y: height))
        path.closeSubpath()
        return path
    }
}
