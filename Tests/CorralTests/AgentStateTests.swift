import XCTest
@testable import Corral

/// The status dot's whole job is to be trusted at a glance, so the rules behind
/// it are pinned here rather than left to be judged by eye against a live
/// machine — where the interesting cases (a two-day-old agent, one mid-compile)
/// are the ones you cannot conjure on demand.
final class AgentStateTests: XCTestCase {

    private let threshold = AgentInventory.idleThreshold
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func activity(
        cpu: Double = 0,
        quietFor: TimeInterval? = nil,
        wroteAgo: TimeInterval? = nil
    ) -> Activity {
        Activity(
            cpuLoad: cpu,
            quietSince: quietFor.map { now.addingTimeInterval(-$0) },
            lastTerminalActivity: wroteAgo.map { now.addingTimeInterval(-$0) }
        )
    }

    private func classify(
        _ activity: Activity,
        child: (role: ProcessRole, load: Double)? = nil
    ) -> AgentState {
        GroupActivity.classify(
            root: activity,
            idleThreshold: threshold,
            busiestChild: child,
            now: now
        )
    }

    // ─ Working ──────────────────────────────────────────────────────────────

    func testCpuAboveThresholdIsWorking() {
        XCTAssertEqual(classify(activity(cpu: 0.4)), .working)
    }

    /// The case the old root-only rule got wrong in the other direction: an
    /// agent streaming a reply spends almost no CPU on it, but it is plainly
    /// working, and the terminal write is the proof.
    func testRecentTerminalOutputIsWorkingEvenWithNoCpu() {
        let subject = activity(cpu: 0, quietFor: 120, wroteAgo: 3)
        XCTAssertEqual(classify(subject), .working)
    }

    /// CLI agents animate a thinking indicator while they wait on the model, so
    /// the window has to be long enough to bridge the gaps between redraws —
    /// and short enough that a finished agent stops claiming to work.
    func testOutputOlderThanTheWindowIsNotWorking() {
        let justInside = activity(cpu: 0, quietFor: 60, wroteAgo: 29)
        let justOutside = activity(cpu: 0, quietFor: 60, wroteAgo: 31)
        XCTAssertEqual(classify(justInside), .working)
        XCTAssertEqual(classify(justOutside), .idle)
    }

    // ─ Waiting ──────────────────────────────────────────────────────────────

    /// The bug this whole change exists for: a `swift build` burning a core
    /// while the agent that started it sits on a read. Reading the root process
    /// alone called that idle, and offered to kill it.
    func testBusyChildMeansWaitingNotIdle() {
        let subject = activity(cpu: 0, quietFor: 600, wroteAgo: 600)
        let state = classify(subject, child: (role: .tooling, load: 0.95))
        XCTAssertEqual(state, .waiting)
        XCTAssertTrue(state.isBusy)
    }

    /// An MCP server ticking over on a heartbeat is not work, and must not keep
    /// a forgotten agent looking alive forever.
    func testBarelyTickingChildDoesNotCountAsWork() {
        let subject = activity(cpu: 0, quietFor: 7_200, wroteAgo: 7_200)
        let state = classify(subject, child: (role: .mcpServer, load: 0.002))
        XCTAssertEqual(state, .stale)
    }

    func testChildThresholdBoundary() {
        let subject = activity(cpu: 0, quietFor: 600, wroteAgo: 600)
        let below = GroupActivity.childBusyThreshold - 0.001
        let at = GroupActivity.childBusyThreshold
        XCTAssertEqual(classify(subject, child: (role: .tooling, load: below)), .idle)
        XCTAssertEqual(classify(subject, child: (role: .tooling, load: at)), .waiting)
    }

    // ─ Idle, graded ─────────────────────────────────────────────────────────

    func testIdleGradesByHowLongItHasBeenQuiet() {
        XCTAssertEqual(classify(activity(quietFor: 300, wroteAgo: 300)), .idle)
        XCTAssertEqual(classify(activity(quietFor: 7_200, wroteAgo: 7_200)), .stale)
        XCTAssertEqual(classify(activity(quietFor: 200_000, wroteAgo: 200_000)), .abandoned)
    }

    func testGradeBoundaries() {
        XCTAssertEqual(classify(activity(quietFor: 3_599, wroteAgo: 3_599)), .idle)
        XCTAssertEqual(classify(activity(quietFor: 3_601, wroteAgo: 3_601)), .stale)
        XCTAssertEqual(classify(activity(quietFor: 86_401, wroteAgo: 86_401)), .abandoned)
    }

    /// With no terminal to read, idle time can only reach back to when Corral
    /// started watching — the grade still has to work off that.
    func testIdleWithoutATerminalStillGrades() {
        let subject = activity(cpu: 0, quietFor: 7_200, wroteAgo: nil)
        XCTAssertEqual(classify(subject), .stale)
    }

    // ─ Not yet known ────────────────────────────────────────────────────────

    /// A process seen exactly once has no second sample to compare against.
    /// Borrowing the working colour there would be a guess, and the guess would
    /// be wrong for every agent that was already asleep when Corral opened.
    func testFirstSightingIsStartingNotWorking() {
        let subject = activity(cpu: 0, quietFor: nil, wroteAgo: nil)
        XCTAssertEqual(classify(subject), .starting)
        XCTAssertFalse(classify(subject).isBusy)
    }

    /// A brand-new process that has already written something is working — the
    /// output is evidence even when the CPU sample is not there yet.
    func testFirstSightingWithFreshOutputIsWorking() {
        let subject = activity(cpu: 0, quietFor: nil, wroteAgo: 1)
        XCTAssertEqual(classify(subject), .working)
    }

    // ─ Busy states are protected from bulk stops ────────────────────────────

    func testOnlyQuietStatesAreEligibleForReclaim() {
        XCTAssertTrue(AgentState.working.isBusy)
        XCTAssertTrue(AgentState.waiting.isBusy)
        for state in [AgentState.starting, .idle, .stale, .abandoned] {
            XCTAssertFalse(state.isBusy, "\(state) must not read as busy")
        }
    }
}

/// The header sparklines.
final class TrendBufferTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testSamplesAverageIntoBuckets() throws {
        var buffer = TrendBuffer()
        // Four samples inside one 30-second bucket.
        for (offset, value) in [(0.0, 2.0), (2.0, 4.0), (4.0, 6.0), (6.0, 8.0)] {
            buffer.record(value, at: start.addingTimeInterval(offset))
        }
        XCTAssertEqual(try XCTUnwrap(buffer.live), 5.0, accuracy: 0.001)
        XCTAssertTrue(buffer.buckets.isEmpty, "an open bucket is not closed early")

        // A sample in the next bucket closes the previous one.
        buffer.record(10, at: start.addingTimeInterval(40))
        XCTAssertEqual(buffer.buckets.count, 1)
        XCTAssertEqual(buffer.buckets[0].value, 5.0, accuracy: 0.001)
        XCTAssertEqual(buffer.latest, 10)
    }

    /// A gap has to survive as a gap: the sparkline breaks its line there, and
    /// it can only do that if the missing buckets are actually missing.
    func testAGapInSamplingLeavesAGapInTheBuckets() {
        var buffer = TrendBuffer()
        buffer.record(1, at: start)
        buffer.record(2, at: start.addingTimeInterval(30))
        // The Mac slept for ten minutes.
        buffer.record(3, at: start.addingTimeInterval(630))

        let indices = buffer.series(.hour).map(\.index)
        XCTAssertEqual(indices.count, 3)
        XCTAssertEqual(indices[1] - indices[0], 1)
        XCTAssertEqual(indices[2] - indices[1], 20, "ten minutes is twenty buckets")
    }

    func testOlderThanThreeHoursIsDropped() {
        var buffer = TrendBuffer()
        buffer.record(1, at: start)
        buffer.record(2, at: start.addingTimeInterval(4 * 3_600))
        XCTAssertEqual(buffer.buckets.count, 0, "the four-hour-old bucket is gone")
        XCTAssertEqual(buffer.latest, 2)
    }

    func testRangeWindowsTheSeries() {
        var buffer = TrendBuffer()
        // Two hours of samples, one per bucket.
        for step in 0..<240 {
            buffer.record(Double(step), at: start.addingTimeInterval(Double(step) * 30))
        }
        XCTAssertEqual(buffer.series(.fifteenMinutes).count, 30)
        XCTAssertEqual(buffer.series(.hour).count, 120)
        XCTAssertEqual(buffer.series(.threeHours).count, 240)
    }

    func testShapeNeedsMoreThanAPointOrTwo() {
        var buffer = TrendBuffer()
        XCTAssertFalse(buffer.hasShape(.hour))
        buffer.record(1, at: start)
        buffer.record(2, at: start.addingTimeInterval(30))
        XCTAssertFalse(buffer.hasShape(.hour))
        buffer.record(3, at: start.addingTimeInterval(60))
        XCTAssertTrue(buffer.hasShape(.hour))
    }

    func testRangeCycles() {
        XCTAssertEqual(TrendRange.fifteenMinutes.next, .hour)
        XCTAssertEqual(TrendRange.hour.next, .threeHours)
        XCTAssertEqual(TrendRange.threeHours.next, .fifteenMinutes)
    }
}

/// Icon resolution — the path arithmetic, which is the only part that can be
/// tested without knowing what is installed on the machine running the tests.
final class ToolIconTests: XCTestCase {

    func testBundleIsTakenFromTheExecutablePath() {
        XCTAssertEqual(
            ToolIcon.bundlePath(forExecutable: "/Applications/Cursor.app/Contents/MacOS/Cursor"),
            "/Applications/Cursor.app"
        )
    }

    /// Electron nests a helper bundle inside the app bundle. The product is the
    /// outer one; taking the last `.app` would label every renderer with the
    /// helper's generic icon.
    func testNestedHelperBundleResolvesToTheOuterApp() {
        let path = "/Applications/Cursor.app/Contents/Frameworks/"
            + "Cursor Helper (Renderer).app/Contents/MacOS/Cursor Helper (Renderer)"
        XCTAssertEqual(ToolIcon.bundlePath(forExecutable: path), "/Applications/Cursor.app")
    }

    func testAnAppInstalledInTheHomeFolderIsStillFound() {
        XCTAssertEqual(
            ToolIcon.bundlePath(forExecutable: "/Users/x/Applications/Windsurf.app/Contents/MacOS/Windsurf"),
            "/Users/x/Applications/Windsurf.app"
        )
    }

    /// A CLI agent is a bare binary. It has no bundle, and saying so is what
    /// sends the caller to the vendor-app fallback instead of a wrong guess.
    func testABareBinaryHasNoBundle() {
        XCTAssertNil(ToolIcon.bundlePath(forExecutable: "/Users/x/.local/share/claude/versions/2.1.235"))
        XCTAssertNil(ToolIcon.bundlePath(forExecutable: "/opt/homebrew/bin/codex"))
    }
}
