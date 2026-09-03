import XCTest
@testable import OpenUsage

/// Locks the per-provider summary selection: among a provider's bounded meters with a valid reset
/// window, prefer the overall weekly quota (titled "Weekly") over per-model weekly windows (e.g.
/// Fable) that share the same 7-day period, then the one with the longest reset period (the
/// weekly/monthly monitoring horizon), then the most at-risk among those with the same period
/// (smallest remaining fraction; tie-break to the most severe meter state). Pins `now` and derives
/// `resetsAt` from an elapsed fraction (same pattern as PaceTests).
final class PaceProjectionSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let week: TimeInterval = 7 * 24 * 60 * 60

    private func resetsAt(elapsed: Double, period: TimeInterval) -> Date {
        now.addingTimeInterval(period * (1 - elapsed))
    }

    private func meter(_ title: String, used: Double, limit: Double = 100,
                       elapsed: Double = 0.5, period: TimeInterval? = nil) -> BoundedMeter {
        let period = period ?? week
        return BoundedMeter(
            title: title, used: used, limit: limit,
            resetsAt: resetsAt(elapsed: elapsed, period: period),
            periodDurationMs: Int(period * 1000)
        )
    }

    func testPicksSmallestRemainingFraction() {
        // 30% used → 70% left; 60% used → 40% left; 80% used → 20% left. Picks the 80% one.
        let meters = [meter("A", used: 30), meter("B", used: 60), meter("C", used: 80)]
        XCTAssertEqual(PaceProjectionSummary.select(from: meters, now: now)?.title, "C")
    }

    func testPrefersWeeklyMeterOverMoreAtRiskPerModelWindow() {
        // "Weekly" (30% used) and "Fable" (80% used) share the same 7-day period, so the old
        // longest-period-then-most-at-risk logic would pick Fable. The overall weekly quota wins.
        let meters = [
            meter("Fable", used: 80),
            meter("Weekly", used: 30),
        ]
        XCTAssertEqual(PaceProjectionSummary.select(from: meters, now: now)?.title, "Weekly")
    }

    func testPrefersLongestPeriod() {
        // A 5-hour session meter is more at-risk (80% used) than the weekly meter (30% used), but
        // the weekly monitoring horizon wins.
        let meters = [
            meter("Session", used: 80, period: 5 * 3600),
            meter("Weekly", used: 30),
        ]
        XCTAssertEqual(PaceProjectionSummary.select(from: meters, now: now)?.title, "Weekly")
    }

    func testPicksMostAtRiskAmongSamePeriod() {
        // Same weekly period; 80% used is more at-risk than 30% used.
        let meters = [meter("A", used: 30), meter("B", used: 80)]
        XCTAssertEqual(PaceProjectionSummary.select(from: meters, now: now)?.title, "B")
    }

    func testTieBreakByMostSevereState() {
        // Equal remaining fraction (50% left) but different elapsed, so the tie-break decides.
        // A: 50 used / 0.5 elapsed → projected 100 = limit → onTrack (rank 1).
        // B: 50 used / 0.1 elapsed → projected 500 > limit → runningOut (rank 2).
        let meters = [
            meter("A", used: 50, elapsed: 0.5),
            meter("B", used: 50, elapsed: 0.1),
        ]
        XCTAssertEqual(PaceProjectionSummary.select(from: meters, now: now)?.title, "B")
    }

    func testIgnoresMetersWithoutAResetWindow() {
        var noWindow = meter("A", used: 50)
        noWindow.resetsAt = nil
        let meters = [noWindow, meter("B", used: 80)]
        XCTAssertEqual(PaceProjectionSummary.select(from: meters, now: now)?.title, "B")
    }

    func testIgnoresMetersWithoutAPeriod() {
        var noPeriod = meter("A", used: 50)
        noPeriod.periodDurationMs = nil
        let meters = [noPeriod, meter("B", used: 80)]
        XCTAssertEqual(PaceProjectionSummary.select(from: meters, now: now)?.title, "B")
    }

    func testNilWhenNoQualifyingMeters() {
        XCTAssertNil(PaceProjectionSummary.select(from: [], now: now))
        var noWindow = meter("A", used: 50)
        noWindow.resetsAt = nil
        XCTAssertNil(PaceProjectionSummary.select(from: [noWindow], now: now))
    }
}
