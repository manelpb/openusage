import Foundation

/// The quota state for Ollama's two limit windows, read from the authenticated settings page: the
/// current utilization and the reset instant. Either field may be nil — the page may expose only one
/// window, or expose a window's percentage without a reset.
///
/// This used to be resets-only: Ollama's signed `/api/usage` carried the percentages but no reset times.
/// As of late 2026 that endpoint no longer returns a `limits` block at all (it now reports request-count
/// activity), so *both* the percentages and the resets come from this settings-page scrape.
struct OllamaResets: Equatable, Sendable {
    var session: Date?
    var weekly: Date?
    /// Session utilization as a 0–100 percentage, when the page exposes it.
    var sessionPercent: Double?
    /// Weekly utilization as a 0–100 percentage, when the page exposes it.
    var weeklyPercent: Double?

    init(session: Date? = nil, weekly: Date? = nil,
         sessionPercent: Double? = nil, weeklyPercent: Double? = nil) {
        self.session = session
        self.weekly = weekly
        self.sessionPercent = sessionPercent
        self.weeklyPercent = weeklyPercent
    }

    var isEmpty: Bool {
        session == nil && weekly == nil && sessionPercent == nil && weeklyPercent == nil
    }

    /// Drop anything tied to a window whose reset has already elapsed. An elapsed reset can't drive a
    /// countdown, and the percentage measured against that window is equally stale — the window has
    /// restarted. A percentage with no reset instant at all is kept: we simply don't know when it rolls.
    /// The result may be empty.
    func sanitized(now: Date) -> OllamaResets {
        let sessionReset = session.flatMap { $0 > now ? $0 : nil }
        let weeklyReset = weekly.flatMap { $0 > now ? $0 : nil }
        return OllamaResets(
            session: sessionReset,
            weekly: weeklyReset,
            sessionPercent: session == nil || sessionReset != nil ? sessionPercent : nil,
            weeklyPercent: weekly == nil || weeklyReset != nil ? weeklyPercent : nil
        )
    }
}

/// Reads the quota state from Ollama's settings page. `data-time` attributes are preferred for the reset
/// instants (they are ISO values and survive copy changes); the rendered "N% used" copy is the source for
/// the percentages. Pure — no I/O — so it tests directly against fixtures.
enum OllamaResetParser {
    /// Parse the settings HTML: reset instants from every `data-time="…"` (document order: session then
    /// weekly) and the "Session usage N% used" / "Weekly usage N% used" percentages. `nil` when the page
    /// carried no `data-time` at all, so the caller falls back to the rendered-text parse.
    static func resets(fromHTML html: String) -> OllamaResets? {
        let dates = dataTimeDates(in: html)
        // The `data-time` attributes remain the primary signal: only parse the HTML when at least one is
        // present, so a page without them falls through to the text fallback below (which reads the
        // percentages too). A malformed first value stays in place as `nil` so it cannot shift the weekly
        // date into session.
        guard dates.contains(where: { $0 != nil }) else { return nil }
        let percents = percents(in: html)
        let resets = OllamaResets(
            session: dates.count > 0 ? dates[0] : nil,
            weekly: dates.count > 1 ? dates[1] : nil,
            sessionPercent: percents.session,
            weeklyPercent: percents.weekly
        )
        return resets.isEmpty ? nil : resets
    }

    /// Fallback when the `data-time` attributes are absent: read the percentages and the "Resets in …"
    /// copy from the rendered page text.
    static func resets(fromText text: String, now: Date) -> OllamaResets? {
        let percents = percents(in: text)
        let sessionAnchor = text.range(of: "Session usage", options: .caseInsensitive)
        let weeklyAnchor = text.range(of: "Weekly usage", options: .caseInsensitive)

        let session: Date?
        if let sessionStart = sessionAnchor {
            let end: String.Index
            if let weeklyStart = weeklyAnchor, weeklyStart.lowerBound > sessionStart.lowerBound {
                end = weeklyStart.lowerBound
            } else {
                end = text.endIndex
            }
            let sessionSection = String(text[sessionStart.lowerBound..<end])
            session = extractSessionReset(sessionSection, now: now)
                ?? extractRelativeReset(sessionSection, now: now)
        } else {
            session = nil
        }

        let weekly: Date?
        if let weeklyStart = weeklyAnchor {
            weekly = extractRelativeReset(String(text[weeklyStart.lowerBound...]), now: now)
        } else {
            weekly = nil
        }

        let resets = OllamaResets(session: session, weekly: weekly,
                                  sessionPercent: percents.session, weeklyPercent: percents.weekly)
        return resets.isEmpty ? nil : resets
    }

    // MARK: - Percentages

    /// `(session, weekly)` utilization percentages, each the first "N% used" after its "… usage" anchor.
    private static func percents(in text: String) -> (session: Double?, weekly: Double?) {
        func percent(after anchor: String, until end: String?) -> Double? {
            guard let start = text.range(of: anchor, options: .caseInsensitive) else { return nil }
            let tail: String
            if let end,
               let endRange = text.range(of: end, options: .caseInsensitive,
                                         range: start.upperBound..<text.endIndex),
               endRange.lowerBound > start.upperBound {
                tail = String(text[start.upperBound..<endRange.lowerBound])
            } else {
                tail = String(text[start.upperBound...])
            }
            let pattern = try! NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)\s*%\s*used"#,
                                                   options: .caseInsensitive)
            let ns = tail as NSString
            guard let match = pattern.firstMatch(in: tail, range: NSRange(location: 0, length: ns.length)) else {
                return nil
            }
            return Double(ns.substring(with: match.range(at: 1)))
        }
        return (percent(after: "Session usage", until: "Weekly usage"),
                percent(after: "Weekly usage", until: nil))
    }

    // MARK: - Resets

    private static func dataTimeDates(in html: String) -> [Date?] {
        let pattern = try! NSRegularExpression(pattern: #"data-time="([^"]+)""#)
        let range = NSRange(html.startIndex..., in: html)
        return pattern.matches(in: html, range: range).map { match in
            guard let r = Range(match.range(at: 1), in: html) else { return nil }
            return OpenUsageISO8601.date(from: String(html[r]))
        }
    }

    private static func extractSessionReset(_ text: String, now: Date) -> Date? {
        let pattern = try! NSRegularExpression(
            pattern: #"Sessions resume in\s+(\d+)\s*(day|days|hour|hours|minute|minutes)"#,
            options: .caseInsensitive)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range) else { return nil }
        let nsText = text as NSString
        guard let amount = Double(nsText.substring(with: match.range(at: 1))) else { return nil }
        let unit = nsText.substring(with: match.range(at: 2)).lowercased()
        let factor: Double = unit.hasPrefix("minute") ? 60 : unit.hasPrefix("hour") ? 3600 : 86400
        return now.addingTimeInterval(amount * factor)
    }

    private static func extractRelativeReset(_ text: String, now: Date) -> Date? {
        let pattern = try! NSRegularExpression(
            pattern: #"Resets in\s+(?:less than\s+)?(\d+(?:\.\d+)?)\s*(second|seconds|minute|minutes|min|m|hour|hours|h|day|days|d|week|weeks|w)"#,
            options: .caseInsensitive)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range) else { return nil }
        let nsText = text as NSString
        guard let amount = Double(nsText.substring(with: match.range(at: 1))), amount >= 0 else { return nil }
        let unit = nsText.substring(with: match.range(at: 2)).lowercased()
        let factor: Double
        if unit.hasPrefix("second") { factor = 1 }
        else if unit.hasPrefix("minute") || unit == "min" || unit == "m" { factor = 60 }
        else if unit.hasPrefix("hour") || unit == "h" { factor = 3600 }
        else if unit.hasPrefix("day") || unit == "d" { factor = 86400 }
        else if unit.hasPrefix("week") || unit == "w" { factor = 604800 }
        else { return nil }
        return now.addingTimeInterval(amount * factor)
    }
}
