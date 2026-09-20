import Foundation
import Observation
import WebKit

struct OllamaLoginResult: Sendable, Equatable {
    var cookieHeader: String
}

@MainActor
@Observable
final class OllamaLoginController: NSObject {
    var loginResult: OllamaLoginResult?
    var errorMessage: String?
    var statusMessage: String?

    private var webView: WKWebView?
    private var pollTask: Task<Void, Never>?
    private var didCapture = false

    func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        self.webView = webView
        webView.load(URLRequest(url: URL(string: "https://ollama.com/settings")!))
        return webView
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func setStatus(_ message: String) {
        if statusMessage != message { statusMessage = message }
    }

    private func setError(_ message: String?) {
        if errorMessage != message { errorMessage = message }
    }

    private func tryCapture() async {
        guard let webView, !didCapture else { return }
        guard let text = await pageText(from: webView) else { return }

        let ready = text.localizedCaseInsensitiveContains("Session usage")
            || OllamaResetParser.resets(fromText: text, now: Date()) != nil
        guard ready else {
            setStatus("Sign in above to load usage.")
            return
        }

        setError(nil)
        setStatus("Session found, capturing cookies...")
        guard let header = await cookieHeader(from: webView) else {
            setStatus("Signed in, waiting for session cookies...")
            return
        }

        didCapture = true
        stopPolling()
        loginResult = OllamaLoginResult(cookieHeader: header)
    }

    private func pageText(from webView: WKWebView) async -> String? {
        do {
            let result = try await webView.evaluateJavaScript("document.body.innerText")
            return result as? String
        } catch {
            setError("JS evaluation failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func cookieHeader(from webView: WKWebView) async -> String? {
        await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let header = cookies
                    .filter { $0.domain == "ollama.com" || $0.domain.hasSuffix(".ollama.com") }
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")
                continuation.resume(returning: header.isEmpty ? nil : header)
            }
        }
    }
}

extension OllamaLoginController: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.tryCapture()
            if !self.didCapture { self.startPolling() }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let message = "Couldn't load ollama.com — \(error.localizedDescription)"
        Task { @MainActor [weak self] in
            self?.setError(message)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        let message = "Couldn't load ollama.com — \(error.localizedDescription)"
        Task { @MainActor [weak self] in
            self?.setError(message)
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { break }
                await self.tryCapture()
            }
        }
    }
}
