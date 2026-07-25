import Foundation

struct OllamaUsageData: Sendable, Equatable {
    var plan: String?
    var sessionPercent: Double
    var weeklyPercent: Double
    var sessionResetsAt: Date?
    var weeklyResetsAt: Date?
    var source: String
}

enum OllamaUsageMapper {
    static let sessionMs = 5 * 60 * 60 * 1000
    static let weekMs = 7 * 24 * 60 * 60 * 1000

    static func parseAPIUsage(_ data: Data) -> OllamaUsageData? {
        guard let json = ProviderParse.jsonObject(data) else { return nil }
        let body = (json["data"] as? [String: Any]) ?? json

        let session = nestedObject(body, keys: ["session", "session_usage", "sessionUsage"])
        let weekly = nestedObject(body, keys: ["weekly", "weekly_usage", "weeklyUsage"])

        let sessionPercent = clampPercent(
            session?["used_percent"] ?? session?["usedPercent"] ?? session?["percent"] ?? session?["percentage"]
            ?? body["session_percent"] ?? body["sessionPercent"]
        )
        let weeklyPercent = clampPercent(
            weekly?["used_percent"] ?? weekly?["usedPercent"] ?? weekly?["percent"] ?? weekly?["percentage"]
            ?? body["weekly_percent"] ?? body["weeklyPercent"]
        )

        guard let sessionPercent, let weeklyPercent else { return nil }

        return OllamaUsageData(
            plan: (body["plan"] ?? body["tier"] ?? body["subscription"]).flatMap { ($0 as? String)?.nilIfEmpty },
            sessionPercent: sessionPercent,
            weeklyPercent: weeklyPercent,
            sessionResetsAt: (session?["resets_at"] ?? session?["resetsAt"] ?? body["session_resets_at"]).flatMap { ($0 as? String).flatMap(OpenUsageISO8601.date) },
            weeklyResetsAt: (weekly?["resets_at"] ?? weekly?["resetsAt"] ?? body["weekly_resets_at"]).flatMap { ($0 as? String).flatMap(OpenUsageISO8601.date) },
            source: "API"
        )
    }

    static func parseSettingsText(_ text: String, now: Date) -> OllamaUsageData? {
        let percentages = extractPercentages(text)
        AppLog.info(.refresh, "ollama parse: found \(percentages.count) percentages: \(percentages)")

        guard let sessionStart = text.range(of: "Session usage", options: .caseInsensitive) else { return nil }
        let afterSession = String(text[sessionStart.lowerBound...])

        guard let weeklyStart = afterSession.range(of: "Weekly usage", options: .caseInsensitive) else { return nil }
        let sessionSection = String(afterSession[..<weeklyStart.lowerBound])
        let weeklySection = String(afterSession[weeklyStart.lowerBound...])

        AppLog.info(.refresh, "ollama parse: sessionSection=\(sessionSection.prefix(200))")
        AppLog.info(.refresh, "ollama parse: weeklySection=\(weeklySection.prefix(200))")

        let sessionPercent: Double
        let weeklyPercent: Double

        if percentages.count >= 2 {
            sessionPercent = percentages[0] ?? 0
            weeklyPercent = percentages[1] ?? 0
        } else if percentages.count == 1 {
            if sessionSection.contains("%") {
                sessionPercent = percentages[0] ?? 0
                weeklyPercent = 0
                AppLog.info(.refresh, "ollama parse: assign to session (section has %)")
            } else {
                // Single percentage in weekly section means session is blocked (weekly limit reached).
                // Show session as 100% used so "remaining" mode shows 0% left — accurate since
                // the user can't start new sessions.
                sessionPercent = 100
                weeklyPercent = percentages[0] ?? 0
                AppLog.info(.refresh, "ollama parse: assign to weekly, session blocked (100% used)")
            }
        } else {
            return nil
        }

        let sessionResetsAt = extractSessionReset(sessionSection, now: now) ?? extractRelativeReset(sessionSection, now: now)
        let weeklyResetsAt = extractRelativeReset(weeklySection, now: now)

        AppLog.info(.refresh, "ollama parse: session=\(sessionPercent)% resets=\(String(describing: sessionResetsAt)), weekly=\(weeklyPercent)% resets=\(String(describing: weeklyResetsAt))")

        return OllamaUsageData(
            plan: nil,
            sessionPercent: sessionPercent,
            weeklyPercent: weeklyPercent,
            sessionResetsAt: sessionResetsAt,
            weeklyResetsAt: weeklyResetsAt,
            source: "settings"
        )
    }

    private static func extractSessionReset(_ text: String, now: Date) -> Date? {
        let pattern = try! NSRegularExpression(pattern: #"Sessions resume in\s+(\d+)\s*(day|days|hour|hours|minute|minutes)"#, options: .caseInsensitive)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range) else { return nil }
        let nsText = text as NSString
        let amountStr = nsText.substring(with: match.range(at: 1))
        let unit = nsText.substring(with: match.range(at: 2)).lowercased()
        guard let amount = Double(amountStr) else { return nil }
        let factor: Double
        if unit.hasPrefix("minute") { factor = 60 }
        else if unit.hasPrefix("hour") { factor = 3600 }
        else { factor = 86400 }
        return now.addingTimeInterval(amount * factor)
    }

    private static func extractRelativeReset(_ text: String, now: Date) -> Date? {
        let pattern = try! NSRegularExpression(pattern: #"Resets in\s+(?:less than\s+)?(\d+(?:\.\d+)?)\s*(second|seconds|minute|minutes|min|m|hour|hours|h|day|days|d|week|weeks|w)"#, options: .caseInsensitive)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range) else { return nil }
        let nsText = text as NSString
        let amountStr = nsText.substring(with: match.range(at: 1))
        let unit = nsText.substring(with: match.range(at: 2)).lowercased()
        guard let amount = Double(amountStr), amount >= 0 else { return nil }
        let factor: Double
        if unit.hasPrefix("second") || unit == "s" { factor = 1 }
        else if unit.hasPrefix("minute") || unit == "min" || unit == "m" { factor = 60 }
        else if unit.hasPrefix("hour") || unit == "h" { factor = 3600 }
        else if unit.hasPrefix("day") || unit == "d" { factor = 86400 }
        else if unit.hasPrefix("week") || unit == "w" { factor = 604800 }
        else { return nil }
        return now.addingTimeInterval(amount * factor)
    }

    static func buildLines(from data: OllamaUsageData) -> [MetricLine] {
        [
            .progress(
                label: "Session",
                used: data.sessionPercent,
                limit: 100,
                format: .percent,
                resetsAt: data.sessionResetsAt,
                periodDurationMs: sessionMs
            ),
            .progress(
                label: "Weekly",
                used: data.weeklyPercent,
                limit: 100,
                format: .percent,
                resetsAt: data.weeklyResetsAt,
                periodDurationMs: weekMs
            )
        ]
    }

    // MARK: - Helpers

    private static func nestedObject(_ dict: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let value = dict[key] as? [String: Any] { return value }
        }
        return nil
    }

    private static func clampPercent(_ value: Any?) -> Double? {
        let n: Double?
        if let d = value as? Double { n = d }
        else if let s = value as? String { n = Double(s) }
        else { return nil }
        guard let n, n.isFinite else { return nil }
        return max(0, min(100, n))
    }

    private static func extractPercentages(_ text: String) -> [Double?] {
        var results: [Double?] = []
        let regex = try! NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)%\s*used"#, options: .caseInsensitive)
        let range = NSRange(text.startIndex..., in: text)
        regex.enumerateMatches(in: text, range: range) { match, _, stop in
            guard results.count < 2, let match else { return }
            let nsText = text as NSString
            let numStr = nsText.substring(with: match.range(at: 1))
            results.append(Double(numStr))
        }
        return results
    }
}
