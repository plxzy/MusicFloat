import XCTest
@testable import MusicFloat

final class FloatingPanelPlacementTests: XCTestCase {
    func testDefaultFrameCentersNearTopAndStaysInsideVisibleFrame() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)

        let frame = FloatingPanelPlacement.defaultFrame(
            size: CGSize(width: 400, height: 120),
            visibleFrame: visibleFrame,
            topInset: 80
        )

        XCTAssertEqual(frame.origin.x, 300, accuracy: 0.001)
        XCTAssertEqual(frame.origin.y, 600, accuracy: 0.001)
        XCTAssertEqual(frame.width, 400, accuracy: 0.001)
        XCTAssertEqual(frame.height, 120, accuracy: 0.001)
    }

    func testClampedFrameCannotLeaveVisibleFrame() {
        let visibleFrame = CGRect(x: 100, y: 200, width: 500, height: 300)

        let frame = FloatingPanelPlacement.clamped(
            CGRect(x: -200, y: 700, width: 640, height: 400),
            to: visibleFrame
        )

        XCTAssertEqual(frame.origin.x, 100, accuracy: 0.001)
        XCTAssertEqual(frame.origin.y, 200, accuracy: 0.001)
        XCTAssertEqual(frame.width, 500, accuracy: 0.001)
        XCTAssertEqual(frame.height, 300, accuracy: 0.001)
    }

    func testResizePreservesTopCenter() {
        let current = CGRect(x: 200, y: 300, width: 400, height: 120)

        let frame = FloatingPanelPlacement.framePreservingTopCenter(
            currentFrame: current,
            size: CGSize(width: 600, height: 160)
        )

        XCTAssertEqual(frame.midX, current.midX, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, current.maxY, accuracy: 0.001)
        XCTAssertEqual(frame.width, 600, accuracy: 0.001)
        XCTAssertEqual(frame.height, 160, accuracy: 0.001)
    }

    func testSavedPlacementFollowsDisplayAfterRearrangementAndResize() throws {
        let saved = FloatingPanelPlacement.savedPosition(
            CGRect(x: 600, y: 450, width: 400, height: 100),
            display: .init(id: "external", visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        )
        let frame = try XCTUnwrap(FloatingPanelPlacement.restoredFrame(
            saved, size: CGSize(width: 400, height: 100), displays: [
                .init(id: "built-in", visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)),
                .init(id: "external", visibleFrame: CGRect(x: -1600, y: 200, width: 1600, height: 800))
            ], fallbackDisplayID: "built-in"
        ))
        XCTAssertEqual(frame.maxX, 0, accuracy: 0.001)
        XCTAssertEqual(frame.midY, 600, accuracy: 0.001)
    }

    func testMissingDisplayFallsBackAndClampsOversizedPanel() throws {
        let bounds = CGRect(x: 100, y: -400, width: 300, height: 200)
        let frame = try XCTUnwrap(FloatingPanelPlacement.restoredFrame(
            .init(displayID: "disconnected", horizontalFraction: 1, verticalFraction: 1),
            size: CGSize(width: 600, height: 250), displays: [
                .init(id: "other", visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800)),
                .init(id: "active", visibleFrame: bounds)
            ], fallbackDisplayID: "active"
        ))
        XCTAssertEqual(frame, bounds)
    }

    func testInvalidSavedCoordinatesAreIgnored() {
        XCTAssertNil(FloatingPanelPlacement.restoredFrame(
            .init(displayID: "screen", horizontalFraction: .nan, verticalFraction: 0),
            size: CGSize(width: 400, height: 100),
            displays: [.init(id: "screen", visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))],
            fallbackDisplayID: "screen"
        ))
    }

    func testSnappingPadsNearCornerAndLeavesDistantPositionAlone() {
        let bounds = CGRect(x: -1000, y: 100, width: 1000, height: 800)
        let snapped = FloatingPanelPlacement.snapped(
            CGRect(x: -995, y: 795, width: 400, height: 100), to: bounds
        )
        XCTAssertEqual(snapped.minX, bounds.minX + 12)
        XCTAssertEqual(snapped.maxY, bounds.maxY - 12)
        let centered = CGRect(x: -650, y: 450, width: 400, height: 100)
        XCTAssertEqual(FloatingPanelPlacement.snapped(centered, to: bounds), centered)
        XCTAssertEqual(FloatingPanelPlacement.snapped(bounds, to: bounds), bounds)
    }


    func testSnappingChoosesNearestEdgeWhenBothAreWithinThreshold() {
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 500)
        let nearRight = CGRect(x: 29, y: 200, width: 460, height: 100)
        let snapped = FloatingPanelPlacement.snapped(nearRight, to: bounds)
        XCTAssertEqual(snapped.minX, 28)
        XCTAssertEqual(FloatingPanelPlacement.snapped(snapped, to: bounds), snapped)
    }


    func testAutomaticFallbackKeepsRememberedDisplayUntilUserMoves() {
        let previous = FloatingPanelPlacement.SavedPosition(displayID: "external", horizontalFraction: 1, verticalFraction: 1)
        let fallback = FloatingPanelPlacement.Display(id: "built-in", visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let frame = CGRect(x: 200, y: 300, width: 400, height: 100)
        let preserved = FloatingPanelPlacement.savedPosition(
            frame, display: fallback, previous: previous, connectedDisplayIDs: ["built-in"], userInitiated: false
        )
        XCTAssertEqual(preserved.displayID, "external")
        XCTAssertEqual(preserved.horizontalFraction, 1)
        let moved = FloatingPanelPlacement.savedPosition(
            frame, display: fallback, previous: previous, connectedDisplayIDs: ["built-in"], userInitiated: true
        )
        XCTAssertEqual(moved.displayID, "built-in")
        XCTAssertEqual(moved.horizontalFraction, 1.0 / 3.0, accuracy: 0.001)
    }

}
