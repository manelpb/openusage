import Foundation

/// One normalized point on the run-out chart's usage trajectory: `x` = time through the window
/// (0...1), `y` = share of the limit used (0...1).
struct TrajectoryPoint: Hashable, Sendable {
    var x: Double
    var y: Double
    var label: String? = nil
    var cumulativeTokens: Int? = nil
}

/// Builds the real cumulative-usage trajectory for the run-out chart from the provider's per-day token
/// series within the meter's window, scaled so the final point lands at the meter's current used
/// fraction. The trajectory's *shape* is real (from actual daily usage); the absolute scale is
/// normalized to the meter because the daily series is in tokens while the meter is a fraction.
/// `nil` when there's no per-day data inside the window (e.g. a 5-hour session), so the chart falls
/// back to a straight line. Pure logic so it's unit-testable like `Pace`.
enum PaceProjectionTrajectory {
    static func points(
        used: Double, limit: Double,
        resetsAt: Date, periodDuration: TimeInterval,
        now: Date,
        daily: [DailyUsageEntry],
        calendar: Calendar = .current
    ) -> [TrajectoryPoint]? {
        guard limit > 0, periodDuration > 0 else { return nil }
        let windowStart = resetsAt.addingTimeInterval(-periodDuration)
        let entries = daily.compactMap { entry -> (Date, Int)? in
            guard let date = Self.parseDayKey(entry.date, calendar: calendar) else { return nil }
            return (date, entry.totalTokens)
        }
        .filter { $0.0 >= windowStart && $0.0 <= now }
        .sorted { $0.0 < $1.0 }
        let total = entries.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return nil }
        let scale = (used / limit) / Double(total)
        var cumulative = 0.0
        var points: [TrajectoryPoint] = []
        var labelStyle = Date.FormatStyle()
        labelStyle.locale = Locale(identifier: "en_US_POSIX")
        labelStyle.timeZone = calendar.timeZone
        labelStyle.calendar = calendar
        for (date, tokens) in entries {
            cumulative += Double(tokens)
            let x = min(max(date.timeIntervalSince(windowStart) / periodDuration, 0), 1)
            let y = min(max(cumulative * scale, 0), 1)
            points.append(TrajectoryPoint(
                x: x, y: y,
                label: date.formatted(labelStyle.weekday(.abbreviated)),
                cumulativeTokens: Int(cumulative)
            ))
        }
        return points
    }

    private static func parseDayKey(_ key: String, calendar: Calendar) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        return formatter.date(from: key)
    }
}
