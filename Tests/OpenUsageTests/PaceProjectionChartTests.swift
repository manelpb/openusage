import XCTest
@testable import OpenUsage

/// Locks the hover hit test: finds the trajectory point whose view-space x (scaled by canvas width) is
/// nearest the cursor within a fixed x reach. The hit test is x-dominant — y is ignored.
final class PaceProjectionChartTests: XCTestCase {
    private let size = CGSize(width: 200, height: 100)

    private func point(_ x: Double, _ y: Double, tokens: Int = 0) -> TrajectoryPoint {
        TrajectoryPoint(x: x, y: y, cumulativeTokens: tokens)
    }

    func testReturnsNearestIndexWhenPointWithinReach() {
        let trajectory = [point(0.25, 0.5), point(0.5, 0.5), point(0.75, 0.5)]
        // Point 1 maps to (100, 50); cursor 2pt off in x is within the 24pt reach.
        let location = CGPoint(x: 102, y: 52)
        XCTAssertEqual(nearestTrajectoryPointIndex(to: location, size: size, trajectory: trajectory), 1)
    }

    func testReturnsIndexWhenFarInYButNearInX() {
        let trajectory = [point(0.5, 0.5)]
        // Cursor shares point 1's x (100) but is 40pt off in y — y is ignored, so it still hits.
        let location = CGPoint(x: 100, y: 90)
        XCTAssertEqual(nearestTrajectoryPointIndex(to: location, size: size, trajectory: trajectory), 0)
    }

    func testReturnsNilWhenFarInX() {
        let trajectory = [point(0.5, 0.5)]
        // Cursor is 50pt off in x — past the 24pt reach.
        let location = CGPoint(x: 150, y: 50)
        XCTAssertNil(nearestTrajectoryPointIndex(to: location, size: size, trajectory: trajectory))
    }

    func testReturnsNilForEmptyTrajectory() {
        XCTAssertNil(nearestTrajectoryPointIndex(to: CGPoint(x: 100, y: 50), size: size, trajectory: []))
        XCTAssertNil(nearestTrajectoryPointIndex(to: CGPoint(x: 100, y: 50), size: size, trajectory: nil))
    }
}
