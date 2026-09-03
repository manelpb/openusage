import Foundation

/// The geometry for the pace projection chart: the even-pace line, the current usage point, and the
/// projection line to the limit, all in normalized 0...1 coordinates (x = time through the reset
/// window, y = share of the limit used). Pure logic so it's unit-testable like `Pace`.
struct PaceProjection: Hashable, Sendable {
    let used: Double
    let limit: Double
    let resetsAt: Date
    let periodDuration: TimeInterval
    let now: Date

    var windowStart: Date { resetsAt.addingTimeInterval(-periodDuration) }

    var elapsed: TimeInterval { now.timeIntervalSince(windowStart) }

    var elapsedFraction: Double {
        guard periodDuration > 0 else { return 0 }
        return min(max(elapsed / periodDuration, 0), 1)
    }

    var usedFraction: Double {
        guard limit > 0 else { return 0 }
        return min(max(used / limit, 0), 1)
    }

    func evenPaceY(atX x: Double) -> Double { min(max(x, 0), 1) }

    var rate: Double {
        guard elapsed > 0 else { return 0 }
        return used / elapsed
    }

    var runOutFraction: Double? {
        guard rate > 0, used < limit else { return nil }
        let secondsToLimit = (limit - used) / rate
        let t = now.addingTimeInterval(secondsToLimit)
        let fraction = t.timeIntervalSince(windowStart) / periodDuration
        return fraction <= 1 ? fraction : nil
    }

    var runsOutBeforeReset: Bool {
        guard let runOutFraction else { return false }
        return runOutFraction < 1
    }

    var projectionEndpoint: (x: Double, y: Double) {
        if let runOutFraction, runOutFraction < 1 {
            return (runOutFraction, 1)
        }
        let projected = rate * periodDuration
        let y = limit > 0 ? min(max(projected / limit, 0), 1) : 0
        return (1, y)
    }
}
