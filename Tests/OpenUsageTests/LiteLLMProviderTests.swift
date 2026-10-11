import XCTest
@testable import OpenUsage

final class LiteLLMAuthStoreTests: XCTestCase {
    private let config = LiteLLMAuthStore.configPath

    func testLoadsFileConfiguration() {
        let store = LiteLLMAuthStore(
            files: FakeFiles([config: #"{"baseUrl":"https://gateway.example.com","apiKey":"sk-lit","userId":"u1"}"#]),
            environment: FakeEnvironment()
        )

        let loaded = store.loadConfiguration()
        XCTAssertEqual(loaded?.baseURL.absoluteString, "https://gateway.example.com")
        XCTAssertEqual(loaded?.apiKey, "sk-lit")
        XCTAssertEqual(loaded?.userID, "u1")
    }

    func testFileWinsOverEnvironment() {
        let store = LiteLLMAuthStore(
            files: FakeFiles([config: #"{"base_url":"https://file.example.com","api_key":"sk-file"}"#]),
            environment: FakeEnvironment(["LITELLM_BASE_URL": "https://env.example.com", "LITELLM_API_KEY": "sk-env"])
        )

        let loaded = store.loadConfiguration()
        XCTAssertEqual(loaded?.baseURL.absoluteString, "https://file.example.com")
        XCTAssertEqual(loaded?.apiKey, "sk-file")
    }

    func testEnvironmentFallback() {
        let store = LiteLLMAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment(["LITELLM_BASE_URL": "https://env.example.com", "LITELLM_API_KEY": "sk-env"])
        )

        let loaded = store.loadConfiguration()
        XCTAssertEqual(loaded?.baseURL.absoluteString, "https://env.example.com")
        XCTAssertEqual(loaded?.apiKey, "sk-env")
        XCTAssertNil(loaded?.userID)
    }

    func testMissingKeyOrURLIsNil() {
        let noKey = LiteLLMAuthStore(
            files: FakeFiles([config: #"{"baseUrl":"https://gateway.example.com"}"#]),
            environment: FakeEnvironment()
        )
        XCTAssertNil(noKey.loadConfiguration())

        let noURL = LiteLLMAuthStore(
            files: FakeFiles([config: #"{"apiKey":"sk-lit"}"#]),
            environment: FakeEnvironment()
        )
        XCTAssertNil(noURL.loadConfiguration())
    }

    func testInvalidBaseURLIsNil() {
        for raw in ["not a url", "ftp://gateway.example.com", "https://"] {
            XCTAssertNil(LiteLLMAuthStore.validBaseURL(raw), raw)
        }
        XCTAssertEqual(
            LiteLLMAuthStore.validBaseURL("https://gateway.example.com")?.absoluteString,
            "https://gateway.example.com"
        )
    }
}

final class LiteLLMUsageMapperTests: XCTestCase {
    private var calendar: Calendar { .current }

    func testAggregatesPeriodsAndProviderBreakdown() throws {
        let now = date(2026, 10, 10)
        let mapped = try LiteLLMUsageMapper.mapActivity(activityJSON, now: now, calendar: calendar)

        XCTAssertEqual(try dollars(mapped.lines, "Today"), 1.5, accuracy: 0.001)
        XCTAssertEqual(try dollars(mapped.lines, "This Month"), 3.5, accuracy: 0.001)
        XCTAssertEqual(try dollars(mapped.lines, "Last 30 Days"), 6.5, accuracy: 0.001)

        // Today's hover breakdown ranks Anthropic above OpenAI.
        let breakdown = try XCTUnwrap(self.breakdown(mapped.lines, "Today"))
        XCTAssertEqual(breakdown.models.map(\.model), ["Anthropic", "OpenAI"])
        XCTAssertEqual(breakdown.models.first?.costUSD ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(breakdown.totalTokens, 1000)
        XCTAssertEqual(breakdown.sourceNote, LiteLLMUsageMapper.providerBreakdownNote)

        // Last 30 Days pulls in the September OpenAI day too.
        let last30 = try XCTUnwrap(self.breakdown(mapped.lines, "Last 30 Days"))
        XCTAssertEqual(last30.models.map(\.model).sorted(), ["Anthropic", "OpenAI"])
    }

    func testEmptyResultsProduceMeasuredZeroRowsWithoutBreakdown() throws {
        let mapped = try LiteLLMUsageMapper.mapActivity(Data(#"{"results":[]}"#.utf8), now: date(2026, 10, 10), calendar: calendar)

        XCTAssertEqual(mapped.lines.count, 3)
        XCTAssertEqual(try dollars(mapped.lines, "Today"), 0, accuracy: 0.001)
        XCTAssertNil(breakdown(mapped.lines, "Today"))
    }

    func testMalformedBodyThrows() {
        XCTAssertThrowsError(try LiteLLMUsageMapper.mapActivity(Data("not json".utf8)))
    }

    func testDisplayNames() {
        XCTAssertEqual(LiteLLMUsageMapper.displayName("anthropic"), "Anthropic")
        XCTAssertEqual(LiteLLMUsageMapper.displayName("openai"), "OpenAI")
        XCTAssertEqual(LiteLLMUsageMapper.displayName("azure_ai"), "Azure OpenAI")
        XCTAssertEqual(LiteLLMUsageMapper.displayName("vertex_ai"), "Google")
        XCTAssertEqual(LiteLLMUsageMapper.displayName("together_ai"), "Together AI")
        XCTAssertEqual(LiteLLMUsageMapper.displayName("some_new_provider"), "Some New Provider")
        XCTAssertEqual(LiteLLMUsageMapper.displayName("ollama_chat"), "Ollama")
    }

    func testProviderBreakdownAcceptsFlatShape() throws {
        // Tolerate a flat provider object (older/edge payloads) as well as the nested `metrics` shape.
        let body = Data(#"{"results":[{"date":"2026-10-10","metrics":{"spend":1},"breakdown":{"providers":{"deepseek":{"spend":1,"total_tokens":10}}}}]}"#.utf8)
        let mapped = try LiteLLMUsageMapper.mapActivity(body, now: date(2026, 10, 10), calendar: calendar)
        XCTAssertEqual(breakdown(mapped.lines, "Today")?.models.map(\.model), ["DeepSeek"])
    }

    func testProviderRowsEmitMonthToDateSpend() throws {
        // Provider rows carry month-to-date spend: Anthropic = 1.0 (Oct 10) + 2.0 (Oct 1); OpenAI only
        // its October day (the Sep 15 OpenAI day is outside the month).
        let mapped = try LiteLLMUsageMapper.mapActivity(activityJSON, now: date(2026, 10, 10), calendar: calendar)
        XCTAssertEqual(try dollars(mapped.lines, "Anthropic"), 3.0, accuracy: 0.001)
        XCTAssertEqual(try dollars(mapped.lines, "OpenAI"), 0.5, accuracy: 0.001)
        XCTAssertNil(mapped.lines.first { $0.label == "Other" }, "no unclaimed providers in this fixture")
    }

    func testUnclaimedProvidersFoldIntoOther() throws {
        let body = Data(#"{"results":[{"date":"2026-10-10","metrics":{"spend":2},"breakdown":{"providers":{"some_new_provider":{"metrics":{"spend":2,"total_tokens":5}}}}}]}"#.utf8)
        let mapped = try LiteLLMUsageMapper.mapActivity(body, now: date(2026, 10, 10), calendar: calendar)
        XCTAssertEqual(try dollars(mapped.lines, "Other"), 2.0, accuracy: 0.001)
    }

    func testProviderDisplayNameMapping() {
        XCTAssertEqual(LiteLLMProviders.rowID(forProviderKey: "ollama_chat"), "ollama")
        XCTAssertEqual(LiteLLMProviders.rowID(forProviderKey: "vertex_ai"), "google")
        XCTAssertEqual(LiteLLMProviders.rowID(forProviderKey: "azure_ai"), "azure")
        XCTAssertEqual(LiteLLMProviders.rowID(forProviderKey: "brand_new_thing"), "other")
    }

    // MARK: - Helpers

    private var activityJSON: Data {
        Data(#"""
        {
          "results": [
            {
              "date": "2026-10-10",
              "metrics": { "spend": 1.5, "total_tokens": 1000 },
              "breakdown": {
                "providers": {
                  "anthropic": { "metrics": { "spend": 1.0, "total_tokens": 600 } },
                  "openai": { "metrics": { "spend": 0.5, "total_tokens": 400 } }
                }
              }
            },
            {
              "date": "2026-10-01",
              "metrics": { "spend": 2.0, "total_tokens": 2000 },
              "breakdown": { "providers": { "anthropic": { "metrics": { "spend": 2.0, "total_tokens": 2000 } } } }
            },
            {
              "date": "2026-09-15",
              "metrics": { "spend": 3.0, "total_tokens": 3000 },
              "breakdown": { "providers": { "openai": { "metrics": { "spend": 3.0, "total_tokens": 3000 } } } }
            }
          ],
          "metadata": { "total_spend": 6.5 }
        }
        """#.utf8)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date()
    }

    private func dollars(_ lines: [MetricLine], _ label: String) throws -> Double {
        guard case .values(_, let values, _, _, _, _) = try XCTUnwrap(lines.first { $0.label == label }) else {
            throw XCTSkip("not a values line")
        }
        return try XCTUnwrap(values.first { $0.kind == .dollars }).number
    }

    private func breakdown(_ lines: [MetricLine], _ label: String) -> ModelUsageBreakdown? {
        guard case .values(_, _, _, _, _, let breakdown) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return breakdown
    }
}

@MainActor
final class LiteLLMProviderTests: XCTestCase {
    func testRefreshMapsSpendRows() async {
        let provider = LiteLLMProvider(
            authStore: makeAuthStore(),
            usageClient: LiteLLMUsageClient(http: RoutingHTTPClient { request in
                XCTAssertEqual(request.headers["Authorization"], "Bearer sk-lit")
                XCTAssertTrue(request.url.absoluteString.contains("/user/daily/activity?"))
                // The whole window must arrive in one page, bucketed to the user's local day.
                XCTAssertTrue(request.url.absoluteString.contains("page_size=1000"))
                XCTAssertTrue(request.url.absoluteString.contains("include_current_utc_day=true"))
                XCTAssertTrue(request.url.absoluteString.contains("timezone="))
                XCTAssertEqual(request.timeout, 60)
                return jsonResponse([
                    "results": [[
                        "date": LiteLLMUsageClient.dayKey(Date()),
                        "metrics": ["spend": 4.25, "total_tokens": 100],
                        "breakdown": ["providers": ["anthropic": ["spend": 4.25, "total_tokens": 100]]]
                    ]]
                ])
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertFalse(snapshot.lines.contains { $0.isError })
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertNotNil(snapshot.line(label: "This Month"))
        XCTAssertNotNil(snapshot.line(label: "Last 30 Days"))
    }

    func testRefreshWithoutConfigurationReportsNotLoggedIn() async {
        let provider = LiteLLMProvider(
            authStore: LiteLLMAuthStore(files: FakeFiles(), environment: FakeEnvironment()),
            usageClient: LiteLLMUsageClient(http: RoutingHTTPClient { _ in
                XCTFail("should not hit the network without configuration")
                return jsonResponse([:])
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.lines.first?.label, "Error")
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    func testRefreshOnForbiddenReportsInvalidKey() async {
        // A plain inference-only virtual key is refused by the spend endpoints (403).
        let provider = LiteLLMProvider(
            authStore: makeAuthStore(),
            usageClient: LiteLLMUsageClient(http: RoutingHTTPClient { _ in
                HTTPResponse(statusCode: 403, headers: [:], body: Data("{}".utf8))
            })
        )

        let forbidden = await provider.refresh()
        XCTAssertEqual(forbidden.errorCategory, .authInvalid)
    }

    func testRefreshOnTransportFailureReportsNetwork() async {
        let provider = LiteLLMProvider(
            authStore: makeAuthStore(),
            usageClient: LiteLLMUsageClient(http: RoutingHTTPClient { _ in
                throw LiteLLMUsageError.connectionFailed
            })
        )

        let failed = await provider.refresh()
        XCTAssertEqual(failed.errorCategory, .network)
    }

    func testHasLocalCredentialsMirrorsRefreshSources() async {
        let configured = LiteLLMProvider(authStore: makeAuthStore())
        let configuredHasCredentials = await configured.hasLocalCredentials()
        XCTAssertTrue(configuredHasCredentials)

        let unconfigured = LiteLLMProvider(authStore: LiteLLMAuthStore(files: FakeFiles(), environment: FakeEnvironment()))
        let unconfiguredHasCredentials = await unconfigured.hasLocalCredentials()
        XCTAssertFalse(unconfiguredHasCredentials)
    }

    func testProviderDeclaresSpendRows() {
        let provider = LiteLLMProvider(authStore: makeAuthStore())
        let ids = provider.widgetDescriptors.map(\.id)
        XCTAssertEqual(Array(ids.prefix(3)), ["litellm.today", "litellm.month", "litellm.last30"])
        XCTAssertEqual(Array(ids.dropFirst(3)), LiteLLMProviders.rows.map { "litellm.provider.\($0.id)" })
        XCTAssertTrue(provider.widgetDescriptors.allSatisfy { $0.limitResources.isEmpty })
    }

    private func makeAuthStore() -> LiteLLMAuthStore {
        LiteLLMAuthStore(
            files: FakeFiles([LiteLLMAuthStore.configPath: #"{"baseUrl":"https://gateway.example.com","apiKey":"sk-lit"}"#]),
            environment: FakeEnvironment()
        )
    }
}

private func jsonResponse(_ object: [String: Any]) -> HTTPResponse {
    let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    return HTTPResponse(statusCode: 200, headers: [:], body: body)
}
