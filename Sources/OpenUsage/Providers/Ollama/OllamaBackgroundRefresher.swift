import Foundation
import WebKit

@MainActor
final class OllamaBackgroundRefresher: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<ProviderSnapshot?, Never>?
    private var webView: WKWebView?
    private let provider: Provider
    private let now: @Sendable () -> Date

    init(provider: Provider, now: @escaping @Sendable () -> Date) {
        self.provider = provider
        self.now = now
        super.init()
    }

    func refresh(cookie: String) async -> ProviderSnapshot? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let webView = WKWebView(frame: .zero, configuration: config)
            webView.navigationDelegate = self
            self.webView = webView

            injectCookie(cookie, into: config.websiteDataStore) {
                webView.load(URLRequest(url: URL(string: "https://ollama.com/settings")!))
            }
        }
    }

    private func injectCookie(_ value: String, into store: WKWebsiteDataStore, completion: @escaping () -> Void) {
        guard let cookie = HTTPCookie(properties: [
            .domain: ".ollama.com",
            .path: "/",
            .name: OllamaAuthStore.sessionCookieName,
            .value: value,
            .secure: "TRUE",
            .expires: Date().addingTimeInterval(86400)
        ]) else {
            completion()
            return
        }
        store.httpCookieStore.setCookie(cookie) {
            completion()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            guard let self, let continuation = self.continuation else { return }
            self.continuation = nil
            let snapshot = await self.extractSnapshot(webView: webView)
            self.webView = nil
            continuation.resume(returning: snapshot)
        }
    }

    private func extractSnapshot(webView: WKWebView) async -> ProviderSnapshot? {
        let js = "document.body.innerText"
        guard let result = try? await webView.evaluateJavaScript(js),
              let text = result as? String else { return nil }

        AppLog.info(.refresh, "ollama bg: page text: \(text.prefix(1000))")

        guard let data = OllamaUsageMapper.parseSettingsText(text, now: now()) else {
            AppLog.info(.refresh, "ollama bg: parse failed")
            return nil
        }
        AppLog.info(.refresh, "ollama bg: parse ok session=\(data.sessionPercent)% weekly=\(data.weeklyPercent)%")
        let lines = OllamaUsageMapper.buildLines(from: data)
        return ProviderSnapshot.make(provider: provider, plan: data.plan, lines: lines, refreshedAt: now())
    }
}
