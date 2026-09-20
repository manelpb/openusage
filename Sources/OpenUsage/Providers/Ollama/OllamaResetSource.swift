import Foundation

/// Supplies Ollama's Session/Weekly reset instants from the authenticated settings page.
///
/// Contract: `nil` means "settings page fetched, but it carried no reset data". A *failure* — a
/// transport error, a non-2xx status, an undecodable body, or an expired session that redirected to
/// the sign-in page — throws rather than returning `nil`.
protocol OllamaResetSource: Sendable {
    func resets(cookieHeader: String) async throws -> OllamaResets?
}

/// Approach A: fetch the settings HTML over plain HTTP with the captured session cookies and parse
/// `data-time` from the markup. No WebKit on the refresh path.
struct OllamaHTTPResetSource: OllamaResetSource {
    static let settingsURL = URL(string: "https://ollama.com/settings")!

    let http: any HTTPClient
    let now: @Sendable () -> Date

    init(http: any HTTPClient = URLSessionHTTPClient(), now: @escaping @Sendable () -> Date = Date.init) {
        self.http = http
        self.now = now
    }

    func resets(cookieHeader: String) async throws -> OllamaResets? {
        let response = try await http.send(HTTPRequest(
            method: "GET",
            url: Self.settingsURL,
            headers: ["Cookie": cookieHeader, "Accept": "text/html,application/xhtml+xml"],
            timeout: 20
        ))
        // A 401/403 is the server rejecting the session, not a transient transport failure. Classify it
        // the same way `OllamaProvider.load` classifies the usage call's auth statuses, so the provider
        // clears the dead cookie instead of retrying it forever.
        if response.statusCode == 401 || response.statusCode == 403 {
            throw OllamaAuthError.notSignedIn
        }
        guard (200..<300).contains(response.statusCode) else {
            throw OllamaUsageError.requestFailed(response.statusCode)
        }
        guard let html = String(data: response.body, encoding: .utf8) else {
            throw OllamaUsageError.invalidResponse
        }
        // URLSession follows redirects, so an expired cookie lands here as a 200 rendering WorkOS
        // AuthKit's sign-in page instead of the settings page. That is an auth failure, not "no data".
        if html.contains("hosted-authkit") {
            throw OllamaAuthError.notSignedIn
        }
        return OllamaResetParser.resets(fromHTML: html)
            ?? OllamaResetParser.resets(fromText: html, now: now())
    }
}
