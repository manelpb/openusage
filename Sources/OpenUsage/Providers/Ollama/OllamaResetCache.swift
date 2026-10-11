import Foundation

/// Caches the quota state scraped from Ollama's authenticated settings page.
///
/// Ollama's signed usage API used to carry the meters but no reset times; the resets came from a separate
/// web-session fetch. As of late 2026 the API no longer carries the meters either, so the settings page is
/// the source for both the percentages and the resets. A reset instant stays meaningful until it passes,
/// so caching the pair avoids hitting the settings page on every refresh without ever showing a countdown
/// that has already run out.
final class OllamaResetCache {
    /// `v2` carries the utilization percentages as well as the reset instants. A `v1` entry holds resets
    /// only, so leaving it in place would keep the meters empty forever: `current(now:)` short-circuits on
    /// the cache and never refetches the page that now carries the percentages.
    static let defaultsKey = "openusage.ollama.resets.v2"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// The cached quota state, but only while **every** stored reset instant is still in the future. If a
    /// stored instant has elapsed the whole entry is treated as stale and `nil` is returned, so the
    /// provider refetches rather than attaching an expired reset (and the newly-started window is
    /// recovered). A percent-only entry (no resets at all) stays valid. `nil` also when nothing is cached.
    func current(now: Date) -> OllamaResets? {
        guard let stored = userDefaults.dictionary(forKey: Self.defaultsKey) else { return nil }
        let resets = OllamaResets(
            session: (stored["session"] as? Double).map { Date(timeIntervalSince1970: $0) },
            weekly: (stored["weekly"] as? Double).map { Date(timeIntervalSince1970: $0) },
            sessionPercent: stored["sessionPercent"] as? Double,
            weeklyPercent: stored["weeklyPercent"] as? Double
        )
        let instants = [resets.session, resets.weekly].compactMap { $0 }
        guard instants.allSatisfy({ $0 > now }) else { return nil }
        return resets.sanitized(now: now)
    }

    /// Drop the cached pair. Called when the web session that produced it is rejected, so a stale
    /// reset instant can't outlive its source.
    func clear() {
        userDefaults.removeObject(forKey: Self.defaultsKey)
    }

    /// Persist only the future-dated instants plus the current percentages. An already-elapsed instant
    /// is dropped rather than reused.
    func store(_ resets: OllamaResets, now: Date) {
        let future = resets.sanitized(now: now)
        var stored: [String: Double] = [:]
        if let session = future.session {
            stored["session"] = session.timeIntervalSince1970
        }
        if let weekly = future.weekly {
            stored["weekly"] = weekly.timeIntervalSince1970
        }
        if let percent = future.sessionPercent {
            stored["sessionPercent"] = percent
        }
        if let percent = future.weeklyPercent {
            stored["weeklyPercent"] = percent
        }
        if stored.isEmpty {
            userDefaults.removeObject(forKey: Self.defaultsKey)
        } else {
            userDefaults.set(stored, forKey: Self.defaultsKey)
        }
    }
}
