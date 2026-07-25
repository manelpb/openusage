import Foundation

@MainActor
final class OllamaProvider: ProviderRuntime {
    let provider = Provider(
        id: "ollama",
        displayName: "Ollama",
        icon: .providerMark("ollama"),
        links: [
            ProviderLink(label: "Settings", url: "https://ollama.com/settings"),
            ProviderLink(label: "Keys", url: "https://ollama.com/settings/keys")
        ]
    )

    let authStore: OllamaAuthStore
    let usageClient: OllamaUsageClient
    let now: @Sendable () -> Date
    private var lastGoodSnapshot: ProviderSnapshot? = {
        guard let data = UserDefaults.standard.data(forKey: "ollama_last_snapshot") else { return nil }
        return try? JSONDecoder().decode(ProviderSnapshot.self, from: data)
    }()

    func acceptSnapshot(_ snapshot: ProviderSnapshot) {
        lastGoodSnapshot = snapshot
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: "ollama_last_snapshot")
        }
    }

    init(
        authStore: OllamaAuthStore = OllamaAuthStore(),
        usageClient: OllamaUsageClient = OllamaUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "ollama.session", provider: provider, title: "Session", isSessionWindow: true)
                .exportingLimit("session", unit: "percent"),
            .percent(id: "ollama.weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        if await loadOffMainActor({ [authStore] in authStore.loadSessionCookie() }) != nil {
            return true
        }
        return await loadOffMainActor({ [authStore] in authStore.loadAPIKey() }) != nil
    }

    func refresh() async -> ProviderSnapshot {
        if let cookie = await loadOffMainActor({ [authStore] in authStore.loadSessionCookie() }) {
            return await refreshWithCookie(cookie)
        }

        if let apiKey = await loadOffMainActor({ [authStore] in authStore.loadAPIKey() }) {
            return await refreshWithAPIKey(apiKey)
        }

        return ProviderSnapshot.error(provider: provider, error: OllamaAuthError.missingSession)
    }

    private func refreshWithCookie(_ cookie: OllamaSessionCookie) async -> ProviderSnapshot {
        guard let text = await WebPageRefresher().fetchText(
            url: "https://ollama.com/settings",
            cookies: [WebPageRefresher.Cookie(
                name: OllamaAuthStore.sessionCookieName,
                value: cookie.value,
                domain: ".ollama.com"
            )]
        ), let data = OllamaUsageMapper.parseSettingsText(text, now: now()) else {
            if let cached = lastGoodSnapshot { return cached }
            return ProviderSnapshot.error(provider: provider, error: OllamaUsageError.parseFailed)
        }
        let lines = OllamaUsageMapper.buildLines(from: data)
        let snapshot = ProviderSnapshot.make(provider: provider, plan: data.plan, lines: lines, refreshedAt: now())
        lastGoodSnapshot = snapshot
        if let encoded = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(encoded, forKey: "ollama_last_snapshot")
        }
        return snapshot
    }

    private func refreshWithAPIKey(_ apiKey: String) async -> ProviderSnapshot {
        do {
            let response = try await usageClient.fetchAccountUsage(apiKey: apiKey)
            if response.statusCode == 401 || response.statusCode == 403 {
                return ProviderSnapshot.error(provider: provider, error: OllamaAuthError.invalidAPIKey)
            }
            guard (200..<300).contains(response.statusCode) else {
                return ProviderSnapshot.error(provider: provider, error: OllamaUsageError.requestFailed(response.statusCode))
            }
            guard let data = OllamaUsageMapper.parseAPIUsage(response.body) else {
                return ProviderSnapshot.error(provider: provider, error: OllamaUsageError.parseFailed)
            }
            let lines = OllamaUsageMapper.buildLines(from: data)
            return ProviderSnapshot.make(provider: provider, plan: data.plan, lines: lines, refreshedAt: now())
        } catch {
            return ProviderSnapshot.error(provider: provider, error: OllamaUsageError.connectionFailed)
        }
    }
}
