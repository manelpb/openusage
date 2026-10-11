import Foundation

/// A LiteLLM gateway card: what each upstream provider cost, as tracked by the gateway's own spend
/// logging. LiteLLM reports spend per provider for every day, so each period row carries a ranked
/// per-provider breakdown on hover rather than one widget row per provider (the widget model declares a
/// fixed descriptor set, and a gateway can route to any number of providers).
@MainActor
final class LiteLLMProvider: ProviderRuntime {
    let provider = Provider(
        id: "litellm",
        displayName: "LiteLLM",
        icon: .providerMark("litellm")
    )

    let authStore: LiteLLMAuthStore
    let usageClient: LiteLLMUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: LiteLLMAuthStore = LiteLLMAuthStore(),
        usageClient: LiteLLMUsageClient = LiteLLMUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .values(id: "\(provider.id).today", provider: provider, title: "Today",
                    metricLabel: "Today", selection: .kind(.dollars), isUsagePeriod: true),
            .values(id: "\(provider.id).month", provider: provider, title: "This Month",
                    metricLabel: "This Month", selection: .kind(.dollars), isUsagePeriod: true),
            .values(id: "\(provider.id).last30", provider: provider, title: "Last 30 Days",
                    metricLabel: "Last 30 Days", selection: .kind(.dollars), isUsagePeriod: true)
        ] + LiteLLMProviders.rows.map { row in
            // One row per upstream provider (month-to-date spend). Fixed set: a row's label comes from
            // its descriptor, so the list can't be derived from the payload. Users choose which rows
            // show — and pin up to two to the menu bar — in Customize, like any other metric.
            .values(id: "\(provider.id).provider.\(row.id)", provider: provider, title: row.title,
                    metricLabel: row.title, selection: .kind(.dollars))
        }
    }

    func hasLocalCredentials() async -> Bool {
        // Same source as `refresh()`: a configured gateway URL + spend-read key, from the config file or
        // the environment. Local-only, never the network.
        await loadOffMainActor { [authStore] in authStore.loadConfiguration() != nil }
    }

    func refresh() async -> ProviderSnapshot {
        guard let configuration = await loadOffMainActor({ [authStore] in authStore.loadConfiguration() }) else {
            return ProviderSnapshot.error(provider: provider, error: LiteLLMAuthError.missingConfiguration)
        }

        let current = now()
        let calendar = Calendar.current
        // One request covers every row: start at the earlier of the current month and the rolling
        // 30-day window.
        let windowStart = calendar.date(byAdding: .day, value: -(LiteLLMUsageMapper.windowDays - 1), to: current) ?? current
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: current)) ?? windowStart

        let response: HTTPResponse
        do {
            response = try await usageClient.fetchDailyActivity(
                configuration,
                start: min(monthStart, windowStart),
                end: current,
                calendar: calendar
            )
        } catch {
            return ProviderSnapshot.error(provider: provider, error: LiteLLMUsageError.connectionFailed)
        }

        // 401/403 means the key can't be used (bad key, or not allowed to read spend) — distinct from a
        // transient failure so the user knows to fix the key rather than retry.
        if response.statusCode == 401 || response.statusCode == 403 {
            return ProviderSnapshot.error(provider: provider, error: LiteLLMAuthError.invalidKey)
        }
        guard (200..<300).contains(response.statusCode) else {
            return ProviderSnapshot.error(provider: provider, error: LiteLLMUsageError.requestFailed(response.statusCode))
        }

        do {
            let mapped = try LiteLLMUsageMapper.mapActivity(response.body, now: current, calendar: calendar)
            return ProviderSnapshot.make(provider: provider, plan: nil, lines: mapped.lines, refreshedAt: current)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: LiteLLMUsageError.invalidResponse)
        }
    }
}
