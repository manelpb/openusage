import Foundation
import WebKit

struct OllamaLoginResult: Sendable, Equatable {
    var cookie: OllamaSessionCookie
    var data: OllamaUsageData
}

@MainActor
final class OllamaLoginController: NSObject, ObservableObject {
    @Published var loginResult: OllamaLoginResult?
    @Published var errorMessage: String?
    @Published var statusMessage: String?

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

    private func tryCapture() {
        guard let webView, !didCapture else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor [weak self] in
                guard let self, !self.didCapture else { return }
                let ollamaCookies = cookies.filter { $0.domain.contains("ollama") }
                guard let match = ollamaCookies.first(where: { $0.name == OllamaAuthStore.sessionCookieName }) else {
                    self.statusMessage = "\(ollamaCookies.count) ollama.com cookies, no session yet. Log in above."
                    return
                }
                self.statusMessage = "Session found, extracting usage..."
                await self.extractUsage(cookie: match.value, webView: webView)
            }
        }
    }

    private func extractUsage(cookie: String, webView: WKWebView) async {
        let js = "document.body.innerText"
        do {
            let result = try await webView.evaluateJavaScript(js)
            guard let text = result as? String else {
                self.errorMessage = "Could not read page content."
                return
            }
            guard let data = OllamaUsageMapper.parseSettingsText(text, now: Date()) else {
                self.statusMessage = "Waiting for usage data to load..."
                AppLog.info(.refresh, "ollama login: parse failed. text preview: \(text.prefix(500))")
                return
            }
            didCapture = true
            stopPolling()
            loginResult = OllamaLoginResult(
                cookie: OllamaSessionCookie(value: cookie, source: "in-app login"),
                data: data
            )
        } catch {
            self.errorMessage = "JS evaluation failed: \(error.localizedDescription)"
        }
    }

    private func checkCookieStore() {
        guard let webView else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let ollamaCookies = cookies.filter { $0.domain.contains("ollama") }
                if ollamaCookies.contains(where: { $0.name == OllamaAuthStore.sessionCookieName }) {
                    self.statusMessage = "Session cookie found — tap Capture to save it."
                } else {
                    self.statusMessage = "\(ollamaCookies.count) ollama.com cookies, no session yet. Log in above."
                }
            }
        }
    }
}

extension OllamaLoginController: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.tryCapture()
            self.startPolling()
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { break }
                await MainActor.run { self?.tryCapture() }
            }
        }
    }
}
