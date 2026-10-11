import Foundation

struct LiteLLMUsageClient: Sendable {
    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// `GET {base}/user/daily/activity?start_date=…&end_date=…` — per-day spend, token counts, and
    /// request counts with a breakdown by model, model group, provider, endpoint, API key, and MCP
    /// server. The caller's key must be allowed to read spend (see `LiteLLMAuthStore`).
    func fetchDailyActivity(
        _ configuration: LiteLLMConfiguration,
        start: Date,
        end: Date,
        calendar: Calendar = .current
    ) async throws -> HTTPResponse {
        guard var components = URLComponents(
            url: configuration.baseURL.appendingPathComponent("user/daily/activity"),
            resolvingAgainstBaseURL: false
        ) else {
            throw LiteLLMUsageError.invalidResponse
        }

        var queryItems = [
            URLQueryItem(name: "start_date", value: Self.dayKey(start, calendar: calendar)),
            URLQueryItem(name: "end_date", value: Self.dayKey(end, calendar: calendar)),
            // One page covers the whole window: the default page size paginates mid-range, which
            // silently truncated the totals (the server's page math counts underlying rows, not the
            // ~30 day buckets, so the default returned only part of the range with `has_more: true`).
            URLQueryItem(name: "page_size", value: "1000"),
            // Bucket spend by the user's local day (the mapper's day keys are local), and pull in
            // today's spend written after local midnight. Both are required for "Today" to line up.
            URLQueryItem(name: "timezone", value: String(Self.timezoneOffsetMinutes(calendar))),
            URLQueryItem(name: "include_current_utc_day", value: "true")
        ]
        if let userID = configuration.userID {
            queryItems.append(URLQueryItem(name: "user_id", value: userID))
        }
        components.queryItems = queryItems

        guard let url = components.url else { throw LiteLLMUsageError.invalidResponse }

        return try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: [
                "Authorization": "Bearer \(configuration.apiKey)",
                "Accept": "application/json"
            ],
            // The 30-day payload carries every breakdown dimension and can top 800 KB / run tens of
            // seconds when the gateway computes it cold, so allow a generous budget.
            timeout: 60
        ))
    }

    /// JavaScript `getTimezoneOffset()` convention — minutes to add to local time to reach UTC
    /// (e.g. 480 for PST). The endpoint expects this exact sign.
    static func timezoneOffsetMinutes(_ calendar: Calendar = .current) -> Int {
        -calendar.timeZone.secondsFromGMT() / 60
    }

    /// The local-calendar `yyyy-MM-dd` the endpoint's `start_date` / `end_date` expect.
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

enum LiteLLMUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let status):
            return ProviderUsageErrorText.requestFailed(statusCode: status)
        }
    }
}
