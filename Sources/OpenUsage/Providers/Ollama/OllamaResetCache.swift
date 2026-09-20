import Foundation

/// Caches the reset instants scraped from Ollama's authenticated settings page.
///
/// The signed usage API carries the meters but no reset times; those come from a separate web-session
/// fetch. A reset instant stays meaningful until it passes, so caching the pair avoids hitting the
/// settings page on every refresh without ever showing a countdown that has already run out.
final class OllamaResetCache {
    static let defaultsKey = "openusage.ollama.resets"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// The cached resets, but only while **every** stored instant is still in the future. If any
    /// stored instant has elapsed the whole pair is treated as stale and `nil` is returned, so the
    /// provider refetches rather than attaching an expired reset (and the newly-started window is
    /// recovered). `nil` also when nothing is cached.
    func current(now: Date) -> OllamaResets? {
        guard let stored = userDefaults.dictionary(forKey: Self.defaultsKey) else { return nil }
        let resets = OllamaResets(
            session: (stored["session"] as? Double).map { Date(timeIntervalSince1970: $0) },
            weekly: (stored["weekly"] as? Double).map { Date(timeIntervalSince1970: $0) }
        )
        let instants = [resets.session, resets.weekly].compactMap { $0 }
        guard !instants.isEmpty, instants.allSatisfy({ $0 > now }) else { return nil }
        return resets.sanitized(now: now)
    }

    /// Drop the cached pair. Called when the web session that produced it is rejected, so a stale
    /// reset instant can't outlive its source.
    func clear() {
        userDefaults.removeObject(forKey: Self.defaultsKey)
    }

    /// Persist only the future-dated instants. An already-elapsed instant is dropped rather than reused.
    func store(_ resets: OllamaResets, now: Date) {
        let future = resets.sanitized(now: now)
        var stored: [String: Double] = [:]
        if let session = future.session {
            stored["session"] = session.timeIntervalSince1970
        }
        if let weekly = future.weekly {
            stored["weekly"] = weekly.timeIntervalSince1970
        }
        if stored.isEmpty {
            userDefaults.removeObject(forKey: Self.defaultsKey)
        } else {
            userDefaults.set(stored, forKey: Self.defaultsKey)
        }
    }
}
