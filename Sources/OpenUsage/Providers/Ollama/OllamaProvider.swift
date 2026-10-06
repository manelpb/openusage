import Foundation

@MainActor
final class OllamaProvider: ProviderRuntime {
    let provider = Provider(
        id: "ollama",
        displayName: "Ollama",
        icon: .providerMark("ollama"),
        links: [
            ProviderLink(label: "Usage", url: "https://ollama.com/settings"),
            ProviderLink(label: "API Keys", url: "https://ollama.com/settings/keys")
        ],
        supportsInAppSignIn: true
    )

    /// One notice for every way the plan can go missing, so a failed request and an unreadable response
    /// read the same to the user — the badge is gone for a reason, and the meters are still current.
    private static let planWarning = "Couldn't read your Ollama plan. Usage below is still up to date."

    let authStore: OllamaAuthStore
    let usageClient: OllamaUsageClient
    let resetSource: any OllamaResetSource
    let resetCache: OllamaResetCache
    let now: @Sendable () -> Date
    /// Cached presence of the web session, rewritten once per `refresh()`. The header's Sign In gate
    /// reads this during rendering, so it must never trigger a keychain (subprocess) read itself.
    private var hasSession = false

    init(
        authStore: OllamaAuthStore = OllamaAuthStore(),
        usageClient: OllamaUsageClient = OllamaUsageClient(),
        resetSource: any OllamaResetSource = OllamaHTTPResetSource(),
        resetCache: OllamaResetCache = OllamaResetCache(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.resetSource = resetSource
        self.resetCache = resetCache
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            // Not `isSessionWindow`: that treatment ("Not started" on a fresh pool) needs a reset date,
            // and Ollama publishes none — see `OllamaUsageMapper`.
            .percent(id: "ollama.session", provider: provider, title: "Session",
                     metricLabel: "Session")
                .exportingLimit("session", unit: "percent"),
            .percent(id: "ollama.weekly", provider: provider, title: "Weekly",
                     metricLabel: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            .percent(id: "ollama.monthly", provider: provider, title: "Monthly",
                     metricLabel: "Monthly")
                .exportingLimit("monthly", unit: "percent"),
            // Derived from the Session/Weekly meters above; renders "No data" until a web session supplies
            // reset instants — see OllamaResetSource.
            .projectionSummary(provider: provider),
            // Ollama reports recent spend as a single rolling four-week total, not a daily history, so
            // this is one unbounded dollar row rather than the Today/Yesterday/Last 30 Days tiles the
            // local-scanner providers ship.
            //
            // Deliberately not `isUsagePeriod`: that marks a row where $0.00 means nothing was used, and
            // this row counts charges *beyond* the plan. A subscriber can run Ollama hard all month and
            // still sit at $0.00, so the "No usage in this period" hover would be plainly wrong.
            .values(id: "ollama.last4Weeks", provider: provider, title: "Last 4 Weeks",
                    metricLabel: "Last 4 Weeks", selection: .kind(.dollars),
                    valueWord: "spent")
        ]
    }

    /// Ollama is opt-in: it never enables itself, so the user turns it on in Customize.
    ///
    /// This is the one provider whose local credential cannot answer the question the probe is asking.
    /// Ollama writes `~/.ollama/id_ed25519` the first time it runs, long before — and whether or not —
    /// `ollama signin` ever links it to an ollama.com account, and only the network knows whether that
    /// link exists. Probing the key would therefore auto-enable Ollama for everyone who runs local
    /// models, handing them a provider card whose entire content is a Cloud sign-in warning for a
    /// product they don't use. Reporting no credentials is the honest answer to "is Ollama Cloud set up
    /// here?", and it costs a Cloud subscriber one visit to Customize.
    func hasLocalCredentials() async -> Bool { false }

    /// Whether a captured ollama.com web session cookie is stored. Drives the header's Sign In button:
    /// hidden while the user is already signed in, restored once the session is rejected or cleared.
    /// Render-safe: reads the flag cached by the last `refresh()`, not the keychain.
    func hasStoredWebSession() -> Bool { hasSession }

    func refresh() async -> ProviderSnapshot {
        // The single keychain read of the web session per refresh. Done off-main, before the early
        // error returns, so `hasSession` always reflects the latest state the button gate can see.
        let sessionHeader = await loadOffMainActor { [authStore] in authStore.loadSessionHeader() }
        hasSession = sessionHeader != nil

        let key: OllamaSigningKey?
        do {
            key = try await loadOffMainActor { [authStore] in try authStore.loadSigningKey() }
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
        guard let key else {
            return ProviderSnapshot.error(provider: provider, error: OllamaAuthError.missingKey)
        }

        // The usage endpoint is required; the account endpoint is best-effort (plan name only), so a
        // failure there must not blank out the meters.
        let usage = await load { try await usageClient.fetchUsage(key: key) }
        let account = await loadAccount { try await usageClient.fetchAccount(key: key) }

        var accountBody: Data?
        var warning: String?
        switch account {
        case .success(let body):
            accountBody = body
        case .failure(let error):
            // Best-effort does not mean invisible: without this, a persistently failing plan lookup just
            // looks like an account that has no plan. Log it and carry an amber notice so the missing
            // badge is explained, while the meters below still refresh normally.
            AppLog.warn(.refresh, "ollama plan lookup failed (\(error.errorCategory.rawValue)); meters unaffected")
            warning = Self.planWarning
        }

        switch usage {
        case .success(let body):
            do {
                let resets = await resolveResets(header: sessionHeader)
                let mapped = try OllamaUsageMapper.map(usageBody: body, accountBody: accountBody,
                                                       resets: resets)
                // A 200 carrying a body OpenUsage can't read drops the badge exactly as silently as a
                // failed request did, so it earns the same notice. An account that simply has no plan
                // (`.absent`) stays quiet — that is ordinary, not a fault.
                if warning == nil, mapped.plan == .unreadable {
                    AppLog.warn(.refresh, "ollama plan response unreadable; meters unaffected")
                    warning = Self.planWarning
                }
                return ProviderSnapshot.make(provider: provider, plan: mapped.plan.name, lines: mapped.lines,
                                             refreshedAt: now(), warning: warning)
            } catch {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        case .authFailure:
            // The key parsed and signed fine, so a 401/403 means ollama.com doesn't know it: the user has
            // Ollama installed but has never run `ollama signin` (or has signed out since).
            return ProviderSnapshot.error(provider: provider, error: OllamaAuthError.notSignedIn)
        case .failed(let error):
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    /// The reset instants from the authenticated web session, if the user has one. Best-effort: a
    /// missing session header, an expired cookie, or any transport failure leaves the meters exactly as
    /// they were before resets existed. A still-valid cached pair short-circuits the settings fetch.
    /// `header` is the session read taken once at the top of `refresh()`.
    private func resolveResets(header: String?) async -> OllamaResets? {
        // Cached resets are only ever future, unexpired instants, so they stay valid even after the web
        // session is rejected — there is nothing stale to drop, and re-auth is only needed once the cache
        // expires and the source is consulted again (at which point the rejection clears the session).
        if let cached = resetCache.current(now: now()) { return cached }
        guard let header else { return nil }
        do {
            let resets = try await resetSource.resets(cookieHeader: header)?.sanitized(now: now())
            if let resets, !resets.isEmpty { resetCache.store(resets, now: now()) }
            return resets
        } catch {
            // Only an explicit auth rejection means the stored cookie is dead: drop it so the header's
            // Sign In button returns, and drop the cached resets so their stale instants don't linger.
            // Transport and parse failures are transient and must not sign the user out. The cache is
            // cleared first so it can't outlive the session even if the keychain delete fails.
            if error as? OllamaAuthError == .notSignedIn {
                hasSession = false
                resetCache.clear()
                do {
                    try await loadOffMainActor { [authStore] in try authStore.clearSessionHeader() }
                } catch {
                    AppLog.warn(.keychain, "ollama session clear failed (\(error))")
                }
            }
            AppLog.warn(.refresh, "ollama reset lookup failed (\(error)); meters unaffected")
            return nil
        }
    }

    /// Run the required usage call and classify the outcome: the body on 2xx, an auth failure on
    /// 401/403, or a typed failure for any other non-2xx or transport error.
    private func load(_ call: () async throws -> HTTPResponse) async -> UsageResult {
        do {
            let response = try await call()
            if response.statusCode == 401 || response.statusCode == 403 { return .authFailure }
            guard (200..<300).contains(response.statusCode) else {
                return .failed(.requestFailed(response.statusCode))
            }
            return .success(response.body)
        } catch {
            return .failed(.connectionFailed)
        }
    }

    /// Run the best-effort account call. It never throws into the snapshot — a transport error or a
    /// non-2xx just means "no plan name this refresh" — but it returns *why* so the caller can log the
    /// failure and warn, rather than letting it disappear.
    private func loadAccount(_ call: () async throws -> HTTPResponse) async -> Result<Data, OllamaUsageError> {
        do {
            let response = try await call()
            guard (200..<300).contains(response.statusCode) else {
                return .failure(.requestFailed(response.statusCode))
            }
            return .success(response.body)
        } catch {
            return .failure(.connectionFailed)
        }
    }
}

private enum UsageResult {
    case success(Data)
    case authFailure
    case failed(OllamaUsageError)
}
