import XCTest
@testable import OpenUsage

/// Locks the pace projection chart geometry: the even-pace line, the current usage point, and the
/// projection line to the limit, all in normalized 0...1 coordinates. Pins `now` and derives
/// `resetsAt` from a target elapsed fraction so the math is deterministic (same pattern as PaceTests).
final class PaceProjectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let week: TimeInterval = 7 * 24 * 60 * 60

    private func resetsAt(elapsed: Double, period: TimeInterval) -> Date {
        now.addingTimeInterval(period * (1 - elapsed))
    }

    private func projection(used: Double, elapsed: Double, limit: Double = 100) -> PaceProjection {
        PaceProjection(
            used: used, limit: limit,
            resetsAt: resetsAt(elapsed: elapsed, period: week),
            periodDuration: week, now: now
        )
    }

    func testElapsedFractionIsShareOfWindowGone() {
        XCTAssertEqual(projection(used: 0, elapsed: 0.5).elapsedFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(projection(used: 0, elapsed: 0.25).elapsedFraction, 0.25, accuracy: 0.001)
    }

    func testUsedFractionIsShareOfLimitUsed() {
        XCTAssertEqual(projection(used: 50, elapsed: 0.5).usedFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(projection(used: 130, elapsed: 0.5).usedFraction, 1.0, accuracy: 0.001)
    }

    func testEvenPaceLineIsDiagonal() {
        let p = projection(used: 0, elapsed: 0.5)
        XCTAssertEqual(p.evenPaceY(atX: 0), 0, accuracy: 0.001)
        XCTAssertEqual(p.evenPaceY(atX: 0.5), 0.5, accuracy: 0.001)
        XCTAssertEqual(p.evenPaceY(atX: 1), 1, accuracy: 0.001)
    }

    func testRunOutFractionWhenBurningFast() {
        // Half the window gone, 60% used → rate = 120/week → hits 100% at 0.5 + 1/3 ≈ 0.833.
        let p = projection(used: 60, elapsed: 0.5)
        XCTAssertEqual(p.runOutFraction ?? 0, 0.8333, accuracy: 0.01)
        XCTAssertTrue(p.runsOutBeforeReset)
    }

    func testNoRunOutWhenProjectionLandsAfterReset() {
        // Half gone, 30% used → rate = 60/week → would hit 100% at 1.667 > 1.
        let p = projection(used: 30, elapsed: 0.5)
        XCTAssertNil(p.runOutFraction)
        XCTAssertFalse(p.runsOutBeforeReset)
        // Endpoint is the projected usage at reset: 60% used.
        XCTAssertEqual(p.projectionEndpoint.x, 1, accuracy: 0.001)
        XCTAssertEqual(p.projectionEndpoint.y, 0.6, accuracy: 0.001)
    }

    func testRunOutEndpointIsTheLimitCrossing() {
        let p = projection(used: 60, elapsed: 0.5)
        XCTAssertEqual(p.projectionEndpoint.x, 0.8333, accuracy: 0.01)
        XCTAssertEqual(p.projectionEndpoint.y, 1, accuracy: 0.001)
    }

    func testSpentHasNoRunOutCrossing() {
        let p = projection(used: 100, elapsed: 0.5)
        XCTAssertNil(p.runOutFraction)
        XCTAssertFalse(p.runsOutBeforeReset)
    }

    func testCrossingExactlyAtResetIsNotBeforeReset() {
        // Half gone, 50% used → rate = 100/week → hits 100% at exactly the reset (fraction = 1.0).
        let p = projection(used: 50, elapsed: 0.5)
        XCTAssertEqual(p.runOutFraction ?? 0, 1.0, accuracy: 0.001)
        XCTAssertFalse(p.runsOutBeforeReset)
        XCTAssertEqual(p.projectionEndpoint.x, 1, accuracy: 0.001)
        XCTAssertEqual(p.projectionEndpoint.y, 1, accuracy: 0.001)
    }

    func testZeroUsageHasFlatProjection() {
        let p = projection(used: 0, elapsed: 0.5)
        XCTAssertNil(p.runOutFraction)
        XCTAssertEqual(p.projectionEndpoint.x, 1, accuracy: 0.001)
        XCTAssertEqual(p.projectionEndpoint.y, 0, accuracy: 0.001)
    }

    func testWidgetDataPaceProjectionRequiresResetWindow() {
        var data = WidgetData(title: "Credits", icon: .providerMark("codex"), kind: .dollars,
                              used: 12, limit: 20)
        XCTAssertNil(data.paceProjection)                       // no reset window at all
        data.resetsAt = now.addingTimeInterval(week)
        XCTAssertNil(data.paceProjection)                       // reset date but unknown period
        data.periodDurationMs = Int(week * 1000)
        XCTAssertNotNil(data.paceProjection)                    // both present → geometry
    }
}
