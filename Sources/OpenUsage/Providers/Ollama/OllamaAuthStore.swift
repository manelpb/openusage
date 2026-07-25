import Foundation

struct OllamaSessionCookie: Hashable, Sendable {
    var value: String
    var source: String
}

enum OllamaAuthError: Error, LocalizedError, Equatable {
    case missingSession
    case sessionExpired
    case missingAPIKey
    case invalidAPIKey

    var errorDescription: String? {
        switch self {
        case .missingSession:
            return "No Ollama session. Set OLLAMA_SESSION_COOKIE or sign in with your browser."
        case .sessionExpired:
            return "Ollama session expired. Update your session cookie."
        case .missingAPIKey:
            return "No Ollama API key. Set OLLAMA_API_KEY."
        case .invalidAPIKey:
            return "Ollama API key invalid."
        }
    }
}

struct OllamaAuthStore: Sendable {
    static let sessionCookieName = "__Secure-session"
    static let keychainSessionService = "OpenUsage Ollama Session"
    static let keychainCookieService = "OpenUsage Ollama Cookie"

    var keychain: KeychainAccessing
    var environment: EnvironmentReading

    init(
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader()
    ) {
        self.keychain = keychain
        self.environment = environment
    }

    func loadSessionCookie() -> OllamaSessionCookie? {
        if let envSession = extractCookie(from: environment.value(for: "OLLAMA_SESSION_COOKIE")) {
            return OllamaSessionCookie(value: envSession, source: "OLLAMA_SESSION_COOKIE")
        }
        if let envCookie = extractCookie(from: environment.value(for: "OLLAMA_COOKIE")) {
            return OllamaSessionCookie(value: envCookie, source: "OLLAMA_COOKIE")
        }
        if let keychainSession = extractCookie(from: try? keychain.readGenericPasswordForCurrentUser(service: Self.keychainSessionService)) {
            return OllamaSessionCookie(value: keychainSession, source: "keychain")
        }
        if let keychainCookie = extractCookie(from: try? keychain.readGenericPasswordForCurrentUser(service: Self.keychainCookieService)) {
            return OllamaSessionCookie(value: keychainCookie, source: "keychain")
        }
        return nil
    }

    func saveSessionCookieToKeychain(_ cookie: OllamaSessionCookie) throws {
        try keychain.writeGenericPasswordForCurrentUser(
            service: Self.keychainSessionService,
            value: cookie.value
        )
    }

    func loadAPIKey() -> String? {
        environment.value(for: "OLLAMA_API_KEY")?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func extractCookie(from raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
        let header = text.replacing(/^Cookie:\s*/, with: "")
        let parts = header.components(separatedBy: ";")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            let eq = trimmed.firstIndex(of: "=")
            guard let eq else { continue }
            let name = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            if name == Self.sessionCookieName {
                return String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces).nilIfEmpty
            }
        }
        if !header.contains(";") { return header }
        return nil
    }
}
