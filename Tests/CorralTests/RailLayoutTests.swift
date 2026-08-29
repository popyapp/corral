import XCTest
@testable import Corral

/// The rail is laid out by SwiftUI and hit-tested by AppKit.
///
/// Those are two different pieces of code reading the same numbers, and if they
/// ever disagree the symptom is not a crash — it is a rail that highlights the
/// wrong ring, or none, which reads to the user as the app being broken. These
/// tests pin the arithmetic both sides share.
final class RailLayoutTests: XCTestCase {

    /// The height has to be exactly the stack SwiftUI builds: margins at both
    /// ends, items, and the gaps between them. A rail an item too short would
    /// clip the last ring; one too tall would leave the shape hanging past it.
    func testHeightIsTheStackItActuallyDraws() {
        XCTAssertEqual(
            RailLayout.height(for: 3),
            RailLayout.margin * 2 + RailLayout.itemHeight * 3 + RailLayout.spacing * 2
        )
    }

    /// One ring still gets both margins and no gaps.
    func testASingleRingHasNoGaps() {
        XCTAssertEqual(
            RailLayout.height(for: 1),
            RailLayout.margin * 2 + RailLayout.itemHeight
        )
    }

    /// An empty rail is still drawn as one row tall, because a window of zero
    /// height cannot be hovered, moved, or turned back off.
    func testAnEmptyRailIsStillTouchable() {
        XCTAssertEqual(RailLayout.height(for: 0), RailLayout.height(for: 1))
    }

    /// Pointing at the middle of a ring finds that ring. This is the round trip
    /// the popover's position depends on: `centre` places it, `index` finds it.
    func testTheCentreOfEveryRingFindsItself() {
        for count in 1...4 {
            for index in 0..<count {
                XCTAssertEqual(
                    RailLayout.index(atDepth: RailLayout.centre(of: index), count: count),
                    index,
                    "ring \(index) of \(count)"
                )
            }
        }
    }

    /// The gap between two rings belongs to neither. Rounding it into the
    /// nearer one would make the popover flicker between two vendors as the
    /// pointer crossed the space between them.
    func testTheGapBetweenRingsBelongsToNeither() {
        let gap = RailLayout.margin + RailLayout.itemHeight + RailLayout.spacing / 2
        XCTAssertNil(RailLayout.index(atDepth: gap, count: 3))
    }

    /// The margins are shape, not target.
    func testTheMarginsAreNotAnyRing() {
        XCTAssertNil(RailLayout.index(atDepth: RailLayout.margin - 1, count: 3))
        XCTAssertNil(RailLayout.index(atDepth: -20, count: 3))
    }

    /// Past the last ring is nothing, however tall the window happens to be.
    func testBelowTheLastRingIsNothing() {
        XCTAssertNil(RailLayout.index(atDepth: RailLayout.centre(of: 3), count: 3))
        XCTAssertNil(RailLayout.index(atDepth: 10, count: 0))
    }

    /// The edges of a ring are still the ring: a target this small cannot
    /// afford to be smaller than it looks.
    func testTheEdgesOfARingAreStillTheRing() {
        let top = RailLayout.margin
        let bottom = RailLayout.margin + RailLayout.itemHeight
        XCTAssertEqual(RailLayout.index(atDepth: top, count: 2), 0)
        XCTAssertEqual(RailLayout.index(atDepth: bottom, count: 2), 0)
    }
}
