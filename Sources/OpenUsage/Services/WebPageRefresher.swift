import Foundation
import WebKit

@MainActor
final class WebPageRefresher: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<String?, Never>?
    private var webView: WKWebView?

    struct Cookie {
        var name: String
        var value: String
        var domain: String
    }

    /// Loads `url`, optionally injects cookies, and returns the rendered page text
    /// (`document.body.innerText`) once the page finishes loading.
    func fetchText(url: String, cookies: [Cookie] = []) async -> String? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let webView = WKWebView(frame: .zero, configuration: config)
            webView.navigationDelegate = self
            self.webView = webView

            let store = config.websiteDataStore
            injectAll(cookies, into: store) {
                webView.load(URLRequest(url: URL(string: url)!))
            }
        }
    }

    private func injectAll(_ cookies: [Cookie], into store: WKWebsiteDataStore, completion: @escaping () -> Void) {
        guard !cookies.isEmpty else { completion(); return }
        var remaining = cookies
        func injectNext() {
            guard let next = remaining.popLast() else { completion(); return }
            guard let httpCookie = HTTPCookie(properties: [
                .domain: next.domain,
                .path: "/",
                .name: next.name,
                .value: next.value,
                .secure: "TRUE",
                .expires: Date().addingTimeInterval(86400)
            ]) else { injectNext(); return }
            store.httpCookieStore.setCookie(httpCookie) { injectNext() }
        }
        injectNext()
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            guard let self, let continuation = self.continuation else { return }
            self.continuation = nil
            let text = await self.extractText(webView: webView)
            self.webView = nil
            continuation.resume(returning: text)
        }
    }

    private func extractText(webView: WKWebView) async -> String? {
        guard let result = try? await webView.evaluateJavaScript("document.body.innerText"),
              let text = result as? String else { return nil }
        return text
    }
}
