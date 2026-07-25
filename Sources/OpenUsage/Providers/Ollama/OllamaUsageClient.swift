import Foundation

struct OllamaUsageClient: Sendable {
    static let accountUsageURL = "https://ollama.com/api/account/usage"

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchAccountUsage(apiKey: String) async throws -> HTTPResponse {
        guard let url = URL(string: Self.accountUsageURL) else {
            throw OllamaUsageError.invalidResponse
        }
        return try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Accept": "application/json"
            ],
            timeout: 10
        ))
    }
}

enum OllamaUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Couldn't reach ollama.com. Check your connection."
        case .invalidResponse:
            return "Ollama usage data unavailable. Try again later."
        case .requestFailed(let status):
            return "Ollama request failed (HTTP \(status))."
        case .parseFailed:
            return "Could not parse Ollama Cloud usage from settings."
        }
    }
}
