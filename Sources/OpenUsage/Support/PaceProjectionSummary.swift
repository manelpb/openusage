import Foundation

/// One bounded meter's projection inputs, extracted from a provider's `.progress` line. The summary
/// row scans a provider's meters and picks the most at-risk one to draw.
struct BoundedMeter: Hashable, Sendable {
    var title: String
    var used: Double
    var limit: Double
    var resetsAt: Date?
    var periodDurationMs: Int?
}

/// Picks the provider's bounded meter for the inline run-out summary graph: prefer the overall weekly
/// quota (titled "Weekly") over per-model weekly windows (e.g. Fable) that share the same 7-day period,
/// then the longest reset period (the weekly/monthly monitoring horizon over short session windows and
/// per-model quotas), then the most at-risk among those with the same period (smallest remaining
/// fraction), tie-broken to the most severe meter state (running-out > cutting-it-close > healthy).
/// Only meters with a valid reset window qualify; `nil` when none do. Pure logic so it's
/// unit-testable like `Pace`.
enum PaceProjectionSummary {
    static func select(from meters: [BoundedMeter], now: Date = Date()) -> BoundedMeter? {
        let valid = meters.filter { $0.limit > 0 && $0.resetsAt != nil && ($0.periodDurationMs ?? 0) > 0 }
        // Prefer the overall weekly quota (titled "Weekly") over per-model weekly windows (e.g. Fable),
        // which share the same 7-day period and would otherwise win by being more at-risk.
        if let weekly = valid.first(where: { $0.title == "Weekly" }) {
            return weekly
        }
        return valid.max { lhs, rhs in
                let lhsPeriod = TimeInterval(lhs.periodDurationMs ?? 0)
                let rhsPeriod = TimeInterval(rhs.periodDurationMs ?? 0)
                // Prefer the longer reset period (the weekly/monthly monitoring horizon) over short
                // session windows and per-model quotas.
                if lhsPeriod != rhsPeriod { return lhsPeriod < rhsPeriod }
                let lhsRemaining = (lhs.limit - lhs.used) / lhs.limit
                let rhsRemaining = (rhs.limit - rhs.used) / rhs.limit
                if lhsRemaining != rhsRemaining { return lhsRemaining > rhsRemaining }
                return severityRank(lhs, now: now) < severityRank(rhs, now: now)
            }
    }

    /// 0 = healthy, 1 = closeToLimit, 2 = runningOut/spent — higher is more at risk.
    private static func severityRank(_ meter: BoundedMeter, now: Date) -> Int {
        guard let resetsAt = meter.resetsAt, let periodDurationMs = meter.periodDurationMs,
              periodDurationMs > 0, meter.limit > 0 else { return 0 }
        let period = TimeInterval(periodDurationMs) / 1000
        let elapsed = now.timeIntervalSince(resetsAt.addingTimeInterval(-period))
        guard elapsed > 0 else { return 0 }
        let projected = meter.used / elapsed * period
        if meter.used >= meter.limit { return 2 }
        if projected > meter.limit { return 2 }
        if projected > meter.limit * 0.9 { return 1 }
        return 0
    }
}
