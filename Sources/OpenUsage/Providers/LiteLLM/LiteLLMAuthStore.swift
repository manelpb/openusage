import Foundation

/// A configured LiteLLM gateway: the proxy root URL plus a key allowed to read spend. Reading spend
/// needs a key the gateway lets reach the spend endpoints (a `proxy_admin_viewer` key for the whole
/// gateway, or an internal-user key to read that user's own activity) — a plain inference-only virtual
/// key is refused with 403.
struct LiteLLMConfiguration: Hashable, Sendable {
    /// Proxy root, e.g. `https://litellm.example.com` (no `/v1` suffix — the spend endpoints live at the root).
    var baseURL: URL
    var apiKey: String
    /// Optional `user_id`. `/user/daily/activity` is per-user, so an admin key must name the user whose
    /// activity to read.
    var userID: String?
}

enum LiteLLMAuthError: Error, LocalizedError, Equatable {
    case missingConfiguration
    case invalidKey

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "No LiteLLM gateway configured. Add a baseUrl and apiKey to ~/.config/openusage/litellm.json."
        case .invalidKey:
            return "LiteLLM key rejected. Check the key — and that it is allowed to read spend — in the gateway's settings."
        }
    }
}

/// Reads a LiteLLM gateway URL + spend-read key the user has placed on the machine. LiteLLM has no
/// companion app that stashes a credential, so the values come from a small config file or environment
/// variables (the config file wins, matching the other user-key providers).
///
/// `~/.config/openusage/litellm.json`:
/// ```json
/// { "baseUrl": "https://litellm.example.com", "apiKey": "sk-..." }
/// ```
/// Environment fallbacks: `LITELLM_BASE_URL` / `LITELLM_URL`, `LITELLM_API_KEY` / `LITELLM_MASTER_KEY`,
/// and the optional `LITELLM_USER_ID`.
struct LiteLLMAuthStore: Sendable {
    static let configPath = "~/.config/openusage/litellm.json"
    static let baseURLEnvironmentNames = ["LITELLM_BASE_URL", "LITELLM_URL"]
    static let apiKeyEnvironmentNames = ["LITELLM_API_KEY", "LITELLM_MASTER_KEY"]
    static let userIDEnvironmentNames = ["LITELLM_USER_ID"]

    var files: TextFileAccessing
    var environment: EnvironmentReading

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader()
    ) {
        self.files = files
        self.environment = environment
    }

    /// The configured gateway, or `nil` when the URL or key is missing or the URL isn't usable.
    func loadConfiguration() -> LiteLLMConfiguration? {
        let file = loadFileConfiguration()
        guard let rawBaseURL = firstValue(file.baseURL, Self.baseURLEnvironmentNames),
              let apiKey = firstValue(file.apiKey, Self.apiKeyEnvironmentNames),
              let url = Self.validBaseURL(rawBaseURL)
        else { return nil }
        return LiteLLMConfiguration(
            baseURL: url,
            apiKey: apiKey,
            userID: firstValue(file.userID, Self.userIDEnvironmentNames)
        )
    }

    // MARK: - Sources

    private struct FileConfiguration {
        var baseURL: String?
        var apiKey: String?
        var userID: String?
    }

    private func loadFileConfiguration() -> FileConfiguration {
        guard files.exists(Self.configPath),
              let text = try? files.readText(Self.configPath),
              let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return FileConfiguration() }
        return FileConfiguration(
            baseURL: Self.string(object, ["baseUrl", "base_url", "url"]),
            apiKey: Self.string(object, ["apiKey", "api_key", "key"]),
            userID: Self.string(object, ["userId", "user_id"])
        )
    }

    /// Config file first, environment second — the file is the explicit path a user edits, so it wins
    /// over a stale exported value.
    private func firstValue(_ fileValue: String?, _ names: [String]) -> String? {
        if let fileValue, !fileValue.isEmpty { return fileValue }
        for name in names {
            if let value = environment.value(for: name)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func string(_ object: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// Accept only an absolute `http(s)` URL with a host.
    static func validBaseURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }
}
