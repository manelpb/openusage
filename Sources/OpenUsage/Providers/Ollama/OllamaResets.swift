import Foundation

/// Reset instants for Ollama's two quota windows, read from the authenticated settings page.
/// Either field may be nil (the page may only expose one window).
struct OllamaResets: Equatable, Sendable {
    var session: Date?
    var weekly: Date?

    var isEmpty: Bool { session == nil && weekly == nil }

    /// Drop any instant at or before `now`. An elapsed reset can't drive a countdown, so it must never
    /// reach the meters; the result may be empty.
    func sanitized(now: Date) -> OllamaResets {
        OllamaResets(session: session.flatMap { $0 > now ? $0 : nil },
                     weekly: weekly.flatMap { $0 > now ? $0 : nil })
    }
}

/// Reads reset instants from the settings page. `data-time` attributes are preferred (they are ISO
/// instants and survive copy changes); the rendered-text regexes are the fallback for when that
/// attribute is absent. Pure — no I/O — so it tests directly against fixtures.
enum OllamaResetParser {
    /// ISO instants from every `data-time="…"` attribute, in document order. Unparseable attributes
    /// stay in place as `nil` so a malformed first value cannot shift the weekly date into session.
    static func resets(fromHTML html: String) -> OllamaResets? {
        let dates = dataTimeDates(in: html)
        guard !dates.isEmpty, dates.contains(where: { $0 != nil }) else { return nil }
        return OllamaResets(session: dates[0], weekly: dates.count > 1 ? dates[1] : nil)
    }

    /// Fallback: read the "Sessions resume in …" / "Resets in …" copy from the rendered page text.
    static func resets(fromText text: String, now: Date) -> OllamaResets? {
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

        guard session != nil || weekly != nil else { return nil }
        return OllamaResets(session: session, weekly: weekly)
    }

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
