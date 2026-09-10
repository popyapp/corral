import SwiftUI
import XCTest
@testable import Corral

/// The panel's outline on each edge it can be attached to.
///
/// The right and left rails are one shape turned two different ways, and a
/// wrong transform does not crash — it draws the flare on the free side and
/// the rounding against the bezel, which is the effect inverted. So each turn
/// is checked for the one property that matters: the attached edge lies on
/// the screen edge, and the shape fills the rectangle it was given.
final class HUDShapeTests: XCTestCase {

    private let rect = CGRect(x: 0, y: 0, width: 74, height: 300)

    func testEveryAnchorFillsItsRectangle() {
        for anchor in HUDAnchor.allCases {
            let bounds = HUDShape(anchor: anchor).path(in: rect).boundingRect
            XCTAssertEqual(bounds.minX, 0, accuracy: 0.5, "\(anchor)")
            XCTAssertEqual(bounds.minY, 0, accuracy: 0.5, "\(anchor)")
            XCTAssertEqual(bounds.maxX, rect.width, accuracy: 0.5, "\(anchor)")
            XCTAssertEqual(bounds.maxY, rect.height, accuracy: 0.5, "\(anchor)")
        }
    }

    /// The flare is concave and the free corners are convex, and the flare
    /// is the smaller of the two. So a point one step inside the flare's
    /// inset, near the attached edge, is inside the shape; the same point
    /// near the free edge falls inside the larger rounding and is out. That
    /// asymmetry is the orientation, and it is what a wrong transform loses.
    func testTheFlareIsOnTheAttachedEdge() {
        let inset = HUDShape(anchor: .top).flare + 1

        let right = HUDShape(anchor: .right).path(in: rect)
        XCTAssertTrue(right.contains(CGPoint(x: rect.maxX - inset, y: inset)), "attached side, right rail")
        XCTAssertFalse(right.contains(CGPoint(x: inset, y: inset)), "free side, right rail")

        let left = HUDShape(anchor: .left).path(in: rect)
        XCTAssertTrue(left.contains(CGPoint(x: inset, y: inset)), "attached side, left rail")
        XCTAssertFalse(left.contains(CGPoint(x: rect.maxX - inset, y: inset)), "free side, left rail")

        let strip = CGRect(x: 0, y: 0, width: 268, height: 40)
        let top = HUDShape(anchor: .top).path(in: strip)
        XCTAssertTrue(top.contains(CGPoint(x: inset, y: inset)), "attached side, top strip")
        XCTAssertFalse(top.contains(CGPoint(x: inset, y: strip.maxY - inset)), "free side, top strip")
    }

    /// The side edges are rails and the top is a strip; the placement setting
    /// names all three and off.
    func testPlacementsMapToAnchors() {
        XCTAssertEqual(PanelPlacement.left.anchor, .left)
        XCTAssertEqual(PanelPlacement.right.anchor, .right)
        XCTAssertEqual(PanelPlacement.top.anchor, .top)
        XCTAssertNil(PanelPlacement.off.anchor)
        XCTAssertTrue(HUDAnchor.left.isRail)
        XCTAssertTrue(HUDAnchor.right.isRail)
        XCTAssertFalse(HUDAnchor.top.isRail)
    }
}
