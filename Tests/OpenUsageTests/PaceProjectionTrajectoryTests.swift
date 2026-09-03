import XCTest
@testable import OpenUsage

/// Locks the trajectory computation: normalized cumulative-usage points (x = time through the window,
/// y = share of the limit) built from the provider's per-day token series within the window, scaled so
/// the final point lands at the meter's current used fraction. Pins `now` and derives `resetsAt` from
/// an elapsed fraction (same pattern as PaceTests).
final class PaceProjectionTrajectoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let week: TimeInterval = 7 * 24 * 60 * 60
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }

    private func resetsAt(elapsed: Double, period: TimeInterval) -> Date {
        now.addingTimeInterval(period * (1 - elapsed))
    }

    private func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        return f.string(from: date)
    }

    private func entry(_ date: Date, tokens: Int) -> DailyUsageEntry {
        DailyUsageEntry(date: dayKey(date), totalTokens: tokens, costUSD: nil)
    }

    func testBuildsCumulativePointsScaledToUsedFraction() {
        // windowStart at a known midnight; now = windowStart + 3.5 days (half a week gone).
        let windowStart = calendar.date(from: DateComponents(year: 2023, month: 11, day: 13))!
        let now = windowStart.addingTimeInterval(0.5 * week)
        let resetsAt = windowStart.addingTimeInterval(week)
        let daily = [
            entry(windowStart.addingTimeInterval(1 * 24 * 3600), tokens: 100),
            entry(windowStart.addingTimeInterval(2 * 24 * 3600), tokens: 200),
            entry(windowStart.addingTimeInterval(3 * 24 * 3600), tokens: 300)
        ]
        let points = PaceProjectionTrajectory.points(
            used: 50, limit: 100, resetsAt: resetsAt, periodDuration: week, now: now,
            daily: daily, calendar: calendar
        )
        XCTAssertEqual(points?.count, 3)
        // Total 600 tokens → scale = 0.5/600. Cumulative 100 → 0.0833, 300 → 0.25, 600 → 0.5.
        XCTAssertEqual(points?[0].y ?? 0, 0.0833, accuracy: 0.001)
        XCTAssertEqual(points?[1].y ?? 0, 0.25, accuracy: 0.001)
        XCTAssertEqual(points?[2].y ?? 0, 0.5, accuracy: 0.001)
        // windowStart is midnight, so each day's x = N/7.
        XCTAssertEqual(points?[0].x ?? 0, 1.0 / 7.0, accuracy: 0.001)
        XCTAssertEqual(points?[2].x ?? 0, 3.0 / 7.0, accuracy: 0.001)
    }

    func testNilWhenNoDailyDataInWindow() {
        let reset = resetsAt(elapsed: 0.5, period: week)
        let windowStart = reset.addingTimeInterval(-week)
        // A 5-hour session window has no daily entries inside it.
        let session: TimeInterval = 5 * 3600
        let sessionReset = now.addingTimeInterval(session * 0.5)
        let daily = [entry(windowStart, tokens: 100)] // outside the session window
        XCTAssertNil(PaceProjectionTrajectory.points(
            used: 10, limit: 100, resetsAt: sessionReset, periodDuration: session, now: now,
            daily: daily, calendar: calendar
        ))
    }

    func testNilWhenNoTokens() {
        let reset = resetsAt(elapsed: 0.5, period: week)
        let windowStart = reset.addingTimeInterval(-week)
        let daily = [entry(windowStart.addingTimeInterval(3600), tokens: 0)]
        XCTAssertNil(PaceProjectionTrajectory.points(
            used: 10, limit: 100, resetsAt: reset, periodDuration: week, now: now,
            daily: daily, calendar: calendar
        ))
    }

    func testPointsCarryDayOfWeekLabels() {
        let windowStart = calendar.date(from: DateComponents(year: 2023, month: 11, day: 13))! // a Monday
        let now = windowStart.addingTimeInterval(0.5 * week)
        let resetsAt = windowStart.addingTimeInterval(week)
        let daily = [
            entry(windowStart.addingTimeInterval(1 * 24 * 3600), tokens: 100), // Tuesday
            entry(windowStart.addingTimeInterval(2 * 24 * 3600), tokens: 200)  // Wednesday
        ]
        let points = PaceProjectionTrajectory.points(
            used: 50, limit: 100, resetsAt: resetsAt, periodDuration: week, now: now,
            daily: daily, calendar: calendar
        )
        XCTAssertEqual(points?[0].label, "Tue")
        XCTAssertEqual(points?[1].label, "Wed")
    }

    func testPointsCarryCumulativeTokenCounts() {
        let windowStart = calendar.date(from: DateComponents(year: 2023, month: 11, day: 13))!
        let now = windowStart.addingTimeInterval(0.5 * week)
        let resetsAt = windowStart.addingTimeInterval(week)
        let daily = [
            entry(windowStart.addingTimeInterval(1 * 24 * 3600), tokens: 100),
            entry(windowStart.addingTimeInterval(2 * 24 * 3600), tokens: 300)
        ]
        let points = PaceProjectionTrajectory.points(
            used: 50, limit: 100, resetsAt: resetsAt, periodDuration: week, now: now,
            daily: daily, calendar: calendar
        )
        XCTAssertEqual(points?[0].cumulativeTokens, 100)
        XCTAssertEqual(points?[1].cumulativeTokens, 400)
    }
}
