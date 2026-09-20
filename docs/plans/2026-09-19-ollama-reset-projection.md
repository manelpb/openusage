# Ollama Reset Times & Run-out Projection — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Give Ollama's Session/Weekly meters real reset times (countdown + derived Run-out row) by reading the authenticated settings page, while keeping the signed `/api/usage` call as the source of the percentages.

**Architecture:** Keep `OllamaProvider.refresh()`'s signed-API path for values. Add an injectable `OllamaResetSource` that fetches `https://ollama.com/settings` with a captured `Cookie` header and a pure `OllamaResetParser` (prefers the `data-time` attribute, falls back to the old text regexes). Resets are cached until they pass, then merged into the `.progress` lines with `periodDurationMs` (5h/7d). A restored in-app WKWebView sign-in captures the session cookie header into the Keychain. A `.projectionSummary` descriptor + `ollama.projection` default metric renders the Run-out row.

**Tech Stack:** Swift 6, SwiftUI, SwiftPM (`swift build` / `swift test`), XCTest, WebKit (system framework — no `Package.swift` change).

**Design doc:** `docs/plans/2026-09-19-ollama-reset-projection-design.md`

**Prerequisite fact:** The signed key cannot read the settings HTML (it 302s to `signin.ollama.com`), so a web session cookie is required. Cookie names are not hardcoded (NextAuth's `__Secure-session` is stale; the page is now WorkOS `wos-session`) — capture the whole `ollama.com` cookie set.

---

## Task 1: `OllamaResets` model and pure parser

**Files:**
- Create: `Sources/OpenUsage/Providers/Ollama/OllamaResets.swift`
- Test: `Tests/OpenUsageTests/OllamaResetParserTests.swift`

**Step 1: Write the failing tests**

```swift
import XCTest
@testable import OpenUsage

final class OllamaResetParserTests: XCTestCase {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    // data-time attributes, in DOM order → session then weekly.
    func testParsesDataTimeAttributesInOrder() {
        let html = """
        <span data-time="2026-09-19T19:55:00Z">Resets in 3h</span>
        <span data-time="2026-09-24T11:55:00Z">Resets in 5d</span>
        """
        let resets = OllamaResetParser.resets(fromHTML: html)
        XCTAssertEqual(resets?.session, OpenUsageISO8601.date("2026-09-19T19:55:00Z"))
        XCTAssertEqual(resets?.weekly, OpenUsageISO8601.date("2026-09-24T11:55:00Z"))
    }

    func testSingleDataTimeYieldsSessionOnly() {
        let html = #"<span data-time="2026-09-19T19:55:00Z">Resets in 3h</span>"#
        let resets = OllamaResetParser.resets(fromHTML: html)
        XCTAssertNotNil(resets?.session)
        XCTAssertNil(resets?.weekly)
    }

    func testFallsBackToTextRegexWhenNoDataTime() {
        let text = """
        Session usage 3.2% used Sessions resume in 2 hours
        Weekly usage 32.3% used Resets in 5 days
        """
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let resets = OllamaResetParser.resets(fromText: text, now: now)
        XCTAssertEqual(resets?.session, now.addingTimeInterval(2 * 3600))
        XCTAssertEqual(resets?.weekly, now.addingTimeInterval(5 * 86400))
    }

    func testReturnsNilWhenNothingParseable() {
        XCTAssertNil(OllamaResetParser.resets(fromHTML: "<html>no resets here</html>"))
        XCTAssertNil(OllamaResetParser.resets(fromText: "nothing", now: Date()))
    }
}
```

**Step 2: Run to verify failure**

Run: `swift test --filter OllamaResetParserTests`
Expected: FAIL — `cannot find 'OllamaResetParser' in scope`.

**Step 3: Implement**

```swift
import Foundation

/// Reset instants for Ollama's two quota windows, read from the authenticated settings page.
/// Either field may be nil (the page may only expose one window).
struct OllamaResets: Equatable, Sendable {
    var session: Date?
    var weekly: Date?

    var isEmpty: Bool { session == nil && weekly == nil }
}

/// Reads reset instants from the settings page. `data-time` attributes are preferred (they are ISO
/// instants and survive copy changes); the rendered-text regexes are the fallback for when that
/// attribute is absent. Pure — no I/O — so it tests directly against fixtures.
enum OllamaResetParser {
    /// ISO instants from every `data-time="…"` attribute, in document order.
    static func resets(fromHTML html: String) -> OllamaResets? {
        let dates = dataTimeDates(in: html)
        guard !dates.isEmpty else { return nil }
        return OllamaResets(session: dates[0], weekly: dates.count > 1 ? dates[1] : nil)
    }

    /// Fallback: read the "Sessions resume in …" / "Resets in …" copy from the rendered page text.
    static func resets(fromText text: String, now: Date) -> OllamaResets? {
        guard let sessionStart = text.range(of: "Session usage", options: .caseInsensitive) else { return nil }
        let afterSession = String(text[sessionStart.lowerBound...])
        guard let weeklyStart = afterSession.range(of: "Weekly usage", options: .caseInsensitive) else { return nil }
        let sessionSection = String(afterSession[..<weeklyStart.lowerBound])
        let weeklySection = String(afterSession[weeklyStart.lowerBound...])

        let session = extractSessionReset(sessionSection, now: now)
            ?? extractRelativeReset(sessionSection, now: now)
        let weekly = extractRelativeReset(weeklySection, now: now)
        guard session != nil || weekly != nil else { return nil }
        return OllamaResets(session: session, weekly: weekly)
    }

    private static func dataTimeDates(in html: String) -> [Date] {
        let pattern = try! NSRegularExpression(pattern: #"data-time="([^"]+)""#)
        let range = NSRange(html.startIndex..., in: html)
        return pattern.matches(in: html, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: html) else { return nil }
            return OpenUsageISO8601.date(String(html[r]))
        }
    }

    private static func extractSessionReset(_ text: String, now: Date) -> Date? {
        let pattern = try! NSRegularExpression(
            pattern: #"Sessions resume in\s+(\d+)\s*(day|days|hour|hours|minute|minutes)"#,
            options: .caseInsensitive)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range) else { return nil }
        let nsText = text as NSString
        guard let amount = Double(nsText.substring(with: match.range(at: 1))) else { return nil }
        let unit = nsText.substring(with: match.range(at: 2)).lowercased()
        let factor: Double = unit.hasPrefix("minute") ? 60 : unit.hasPrefix("hour") ? 3600 : 86400
        return now.addingTimeInterval(amount * factor)
    }

    private static func extractRelativeReset(_ text: String, now: Date) -> Date? {
        let pattern = try! NSRegularExpression(
            pattern: #"Resets in\s+(?:less than\s+)?(\d+(?:\.\d+)?)\s*(second|seconds|minute|minutes|min|m|hour|hours|h|day|days|d|week|weeks|w)"#,
            options: .caseInsensitive)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range) else { return nil }
        let nsText = text as NSString
        guard let amount = Double(nsText.substring(with: match.range(at: 1))), amount >= 0 else { return nil }
        let unit = nsText.substring(with: match.range(at: 2)).lowercased()
        let factor: Double
        if unit.hasPrefix("second") || unit == "s" { factor = 1 }
        else if unit.hasPrefix("minute") || unit == "min" || unit == "m" { factor = 60 }
        else if unit.hasPrefix("hour") || unit == "h" { factor = 3600 }
        else if unit.hasPrefix("day") || unit == "d" { factor = 86400 }
        else if unit.hasPrefix("week") || unit == "w" { factor = 604800 }
        else { return nil }
        return now.addingTimeInterval(amount * factor)
    }
}
```

**Step 4: Run to verify pass**

Run: `swift test --filter OllamaResetParserTests`
Expected: PASS (4 tests).

**Step 5: Commit**

```bash
git add Sources/OpenUsage/Providers/Ollama/OllamaResets.swift Tests/OpenUsageTests/OllamaResetParserTests.swift
git commit -m "feat(ollama): add reset parser for the settings page"
```

---

## Task 2: HTTP reset source behind a protocol

**Files:**
- Create: `Sources/OpenUsage/Providers/Ollama/OllamaResetSource.swift`
- Test: `Tests/OpenUsageTests/OllamaResetSourceTests.swift`

**Step 1: Write the failing tests** (uses `FakeHTTPClient` from `Tests/OpenUsageTests/TestSupport.swift:325`)

```swift
import XCTest
@testable import OpenUsage

final class OllamaResetSourceTests: XCTestCase {
    func testParsesResetsFromSettingsHTML() async throws {
        let html = #"<span data-time="2026-09-19T19:55:00Z"></span><span data-time="2026-09-24T11:55:00Z"></span>"#
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data(html.utf8)))
        let source = OllamaHTTPResetSource(http: http)
        let resets = try await source.resets(cookieHeader: "wos-session=abc")
        XCTAssertEqual(resets?.session, OpenUsageISO8601.date("2026-09-19T19:55:00Z"))
        XCTAssertEqual(resets?.weekly, OpenUsageISO8601.date("2026-09-24T11:55:00Z"))
        XCTAssertEqual(http.requests.first?.headers["Cookie"], "wos-session=abc")
    }

    func testNon2xxThrows() async {
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 500, headers: [:], body: Data()))
        let source = OllamaHTTPResetSource(http: http)
        do { _ = try await source.resets(cookieHeader: "x"); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? OllamaUsageError, .requestFailed(500)) }
    }

    func testUnparseablePageReturnsNil() async throws {
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data("<html/>".utf8)))
        let source = OllamaHTTPResetSource(http: http)
        XCTAssertNil(try await source.resets(cookieHeader: "x"))
    }
}
```

**Step 2: Run to verify failure**

Run: `swift test --filter OllamaResetSourceTests`
Expected: FAIL — `cannot find 'OllamaHTTPResetSource'`.

**Step 3: Implement**

```swift
import Foundation

/// Supplies Ollama's Session/Weekly reset instants from the authenticated settings page.
/// `nil` means "page fetched but no reset data" — a failure to fetch throws.
protocol OllamaResetSource: Sendable {
    func resets(cookieHeader: String) async throws -> OllamaResets?
}

/// Approach A: fetch the settings HTML over plain HTTP with the captured session cookies and parse
/// `data-time` from the markup. No WebKit on the refresh path.
struct OllamaHTTPResetSource: OllamaResetSource {
    static let settingsURL = "https://ollama.com/settings"

    var http: any HTTPClient
    var now: @Sendable () -> Date

    init(http: any HTTPClient = URLSessionHTTPClient(), now: @escaping @Sendable () -> Date = Date.init) {
        self.http = http
        self.now = now
    }

    func resets(cookieHeader: String) async throws -> OllamaResets? {
        guard let url = URL(string: Self.settingsURL) else { return nil }
        let response = try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: ["Cookie": cookieHeader, "Accept": "text/html,application/xhtml+xml"],
            timeout: 20
        ))
        guard (200..<300).contains(response.statusCode) else {
            throw OllamaUsageError.requestFailed(response.statusCode)
        }
        guard let html = String(data: response.body, encoding: .utf8) else { return nil }
        return OllamaResetParser.resets(fromHTML: html)
            ?? OllamaResetParser.resets(fromText: html, now: now())
    }
}
```

**Step 4: Run to verify pass**

Run: `swift test --filter OllamaResetSourceTests`
Expected: PASS (3 tests).

**Step 5: Commit**

```bash
git add Sources/OpenUsage/Providers/Ollama/OllamaResetSource.swift Tests/OpenUsageTests/OllamaResetSourceTests.swift
git commit -m "feat(ollama): add HTTP reset source"
```

---

## Task 3: Merge resets into the mapper's lines

**Files:**
- Modify: `Sources/OpenUsage/Providers/Ollama/OllamaUsageMapper.swift`
- Test: `Tests/OpenUsageTests/OllamaProviderTests.swift` (add to `OllamaUsageMapperTests`)

**Step 1: Write the failing tests**

```swift
func testResetsAreAttachedToTheMetersWithPeriodLengths() throws {
    let resets = OllamaResets(session: OpenUsageISO8601.date("2026-09-19T19:55:00Z"),
                              weekly: OpenUsageISO8601.date("2026-09-24T11:55:00Z"))
    let mapped = try OllamaUsageMapper.map(usageBody: data(usageJSON), accountBody: nil, resets: resets)
    guard case .progress(_, _, _, _, let sessionReset, let sessionMs, _) = mapped.lines[0],
          case .progress(_, _, _, _, let weeklyReset, let weeklyMs, _) = mapped.lines[1] else {
        return XCTFail("expected progress lines")
    }
    XCTAssertEqual(sessionReset, resets.session)
    XCTAssertEqual(weeklyReset, resets.weekly)
    XCTAssertEqual(sessionMs, OllamaUsageMapper.sessionMs)
    XCTAssertEqual(weeklyMs, OllamaUsageMapper.weekMs)
}

func testNoResetsLeavesTheMetersUnchanged() throws {
    let mapped = try OllamaUsageMapper.map(usageBody: data(usageJSON), accountBody: nil)
    guard case .progress(_, _, _, _, let reset, let period, _) = mapped.lines[0] else { return XCTFail() }
    XCTAssertNil(reset)
    XCTAssertNil(period)
}
```

**Step 2: Run to verify failure**

Run: `swift test --filter OllamaUsageMapperTests`
Expected: FAIL — `map` has no `resets:` parameter / no `sessionMs`.

**Step 3: Implement**

In `OllamaUsageMapper`, add constants and a `resets:` parameter, and thread it through `percentLine`. Additive — the existing `map(usageBody:accountBody:)` call sites keep compiling via the default.

```swift
    static let sessionMs = 5 * 60 * 60 * 1000
    static let weekMs = 7 * 24 * 60 * 60 * 1000

    static func map(usageBody: Data, accountBody: Data?,
                    resets: OllamaResets? = nil) throws -> (plan: String?, lines: [MetricLine]) {
        let plan = accountBody.flatMap { planName(from: $0) }
        return (plan, try usageLines(usageBody, resets: resets))
    }

    static func usageLines(_ body: Data, resets: OllamaResets? = nil) throws -> [MetricLine] {
        // ... unchanged guard on `limits` ...
        var lines: [MetricLine] = []
        if let session = percentLine(limits["session"], label: "Session",
                                     resetsAt: resets?.session, periodDurationMs: Self.sessionMs) {
            lines.append(session)
        }
        if let weekly = percentLine(limits["weekly"], label: "Weekly",
                                    resetsAt: resets?.weekly, periodDurationMs: Self.weekMs) {
            lines.append(weekly)
        }
        // ... unchanged activity line ...
    }

    /// A period duration without a reset instant renders a static "Resets in 5h" that never counts
    /// down, so the period is only attached when a real reset instant is known.
    private static func percentLine(_ entry: Any?, label: String,
                                    resetsAt: Date?, periodDurationMs: Int) -> MetricLine? {
        guard let entry = entry as? [String: Any],
              let fraction = ProviderParse.number(entry["usage"]) else { return nil }
        return .progress(
            label: label,
            used: ProviderParse.clampPercent(fraction * 100),
            limit: 100,
            format: .percent,
            resetsAt: resetsAt,
            periodDurationMs: resetsAt == nil ? nil : periodDurationMs
        )
    }
```

Update the type's doc comment: resets are carried only when the web session supplies them.

**Step 4: Run to verify pass**

Run: `swift test --filter OllamaUsageMapperTests`
Expected: PASS (including the existing no-reset tests).

**Step 5: Commit**

```bash
git add Sources/OpenUsage/Providers/Ollama/OllamaUsageMapper.swift Tests/OpenUsageTests/OllamaProviderTests.swift
git commit -m "feat(ollama): attach reset instants to the session/weekly meters"
```

---

## Task 4: Session store (Keychain) + provider wiring + cache

**Files:**
- Modify: `Sources/OpenUsage/Providers/Ollama/OllamaAuthStore.swift`
- Create: `Sources/OpenUsage/Providers/Ollama/OllamaResetCache.swift`
- Modify: `Sources/OpenUsage/Providers/Ollama/OllamaProvider.swift`
- Test: `Tests/OpenUsageTests/OllamaProviderTests.swift`

**Step 1: Write the failing tests**

```swift
final class OllamaResetCacheTests: XCTestCase {
    func testReusesResetsWhileInTheFuture() {
        let suite = "ollamaResetCache.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cache = OllamaResetCache(userDefaults: defaults)
        cache.store(OllamaResets(session: now.addingTimeInterval(3600),
                                 weekly: now.addingTimeInterval(86400)),
                    now: now)
        XCTAssertNotNil(cache.current(now: now))
        XCTAssertNil(cache.current(now: now.addingTimeInterval(9 * 86400)))
    }
}

final class OllamaProviderResetTests: XCTestCase {
    func testProviderAttachesResetsFromSource() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let resets = OllamaResets(session: now.addingTimeInterval(3600),
                                  weekly: now.addingTimeInterval(86400))
        let provider = makeProvider(http: RoutedHTTPClient(responses: [
            OllamaUsageClient.usagePath: ok(usageJSON),
            OllamaUsageClient.accountPath: ok(accountJSON)
        ]), resetSource: FakeResetSource(result: resets), now: now)
        let snapshot = await provider.refresh()
        guard case .progress(_, _, _, _, let reset, _ , _) = snapshot.lines[0] else { return XCTFail() }
        XCTAssertEqual(reset, resets.session)
    }

    func testProviderWithoutSessionSkipsResets() async {
        let provider = makeProvider(http: RoutedHTTPClient(responses: [
            OllamaUsageClient.usagePath: ok(usageJSON),
            OllamaUsageClient.accountPath: ok(accountJSON)
        ]), resetSource: FakeResetSource(result: nil))
        let snapshot = await provider.refresh()
        guard case .progress(_, _, _, _, let reset, _, _) = snapshot.lines[0] else { return XCTFail() }
        XCTAssertNil(reset)
    }
}

private struct FakeResetSource: OllamaResetSource {
    var result: OllamaResets?
    func resets(cookieHeader: String) async throws -> OllamaResets? { result }
}
```

**Step 2: Run to verify failure**

Run: `swift test --filter 'OllamaResetCacheTests|OllamaProviderResetTests'`
Expected: FAIL — missing `OllamaResetCache`, `resetSource:`, `now:` in `makeProvider`.

**Step 3: Implement**

`OllamaAuthStore` — add Keychain-backed session storage (keep the existing `files` init parameter):

```swift
    static let keychainSessionService = "OpenUsage Ollama Session"

    private let keychain: any KeychainAccessing

    init(files: any TextFileAccessing = LocalTextFileAccessor(),
         keychain: any KeychainAccessing = SecurityKeychainAccessor()) {
        self.files = files
        self.keychain = keychain
    }

    func loadSessionHeader() -> String? {
        (try? keychain.readGenericPasswordForCurrentUser(service: Self.keychainSessionService))?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    func saveSessionHeader(_ header: String) throws {
        try keychain.writeGenericPasswordForCurrentUser(service: Self.keychainSessionService, value: header)
    }
```

`OllamaResetCache`:

```swift
import Foundation

/// Remembers the last parsed reset instants so most refreshes need no page load. A reset instant is
/// stable until it passes, so the cache is consulted before hitting the settings page.
struct OllamaResetCache {
    private let userDefaults: UserDefaults
    private let key = "openusage.ollama.resets"

    init(userDefaults: UserDefaults = .standard) { self.userDefaults = userDefaults }

    func current(now: Date) -> OllamaResets? {
        guard let raw = userDefaults.dictionary(forKey: key) else { return nil }
        let resets = OllamaResets(
            session: (raw["session"] as? Double).map(Date.init(timeIntervalSince1970:)),
            weekly: (raw["weekly"] as? Double).map(Date.init(timeIntervalSince1970:))
        )
        guard !resets.isEmpty else { return nil }
        // A session reset in the past means the window rolled over — refetch. A weekly reset still in
        // the future is worth keeping even if the session one has passed.
        let hasFuture = [resets.session, resets.weekly].compactMap { $0 }.contains { $0 > now }
        return hasFuture ? resets : nil
    }

    func store(_ resets: OllamaResets, now: Date) {
        var raw: [String: Double] = [:]
        if let s = resets.session { raw["session"] = s.timeIntervalSince1970 }
        if let w = resets.weekly { raw["weekly"] = w.timeIntervalSince1970 }
        userDefaults.set(raw, forKey: key)
    }
}
```

`OllamaProvider` — add injectable `resetSource` + `resetCache`, and resolve resets before mapping:

```swift
    let resetSource: any OllamaResetSource
    let resetCache: OllamaResetCache

    init(authStore: OllamaAuthStore = OllamaAuthStore(),
         usageClient: OllamaUsageClient = OllamaUsageClient(),
         resetSource: any OllamaResetSource = OllamaHTTPResetSource(),
         resetCache: OllamaResetCache = OllamaResetCache(),
         now: @escaping @Sendable () -> Date = Date.init) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.resetSource = resetSource
        self.resetCache = resetCache
        self.now = now
    }

    private func resolveResets() async -> OllamaResets? {
        if let cached = resetCache.current(now: now()) { return cached }
        guard let header = await loadOffMainActor({ [authStore] in authStore.loadSessionHeader() }) else {
            return nil
        }
        do {
            let resets = try await resetSource.resets(cookieHeader: header)
            if let resets { resetCache.store(resets, now: now()) }
            return resets
        } catch {
            AppLog.warn(.refresh, "ollama reset lookup failed (\(error)); meters unaffected")
            return nil
        }
    }
```

In `refresh()`'s success branch, add `let resets = await resolveResets()` before mapping and pass `resets: resets` into `OllamaUsageMapper.map`.

Add `"ollama.projection"` to `widgetDescriptors` via `.projectionSummary(provider: provider)` after the weekly descriptor (see Task 5).

**Step 4: Run to verify pass**

Run: `swift test --filter Ollama`
Expected: PASS (all Ollama tests, existing + new).

**Step 5: Commit**

```bash
git add Sources/OpenUsage/Providers/Ollama Tests/OpenUsageTests/OllamaProviderTests.swift
git commit -m "feat(ollama): layer web session resets into the provider"
```

---

## Task 5: Run-out projection row descriptor + default placement

**Files:**
- Modify: `Sources/OpenUsage/Providers/Ollama/OllamaProvider.swift`
- Modify: `Sources/OpenUsage/Stores/DefaultLayout.swift:44`
- Test: `Tests/OpenUsageTests/OllamaProviderTests.swift`

**Step 1: Write the failing tests**

```swift
func testOffersAProjectionRow() async {
    let labels = await MainActor.run { OllamaProvider().widgetDescriptors.map(\.id) }
    XCTAssertTrue(labels.contains("ollama.projection"), "expected Run-out row: \(labels)")
}

func testProjectionRowIsAlwaysVisibleAndUnpinnedByDefault() {
    XCTAssertTrue(DefaultLayout.metricIDs.contains("ollama.projection"))
    XCTAssertFalse(DefaultLayout.expandedMetricIDs.contains("ollama.projection"))
    XCTAssertFalse(DefaultLayout.pinnedMetricIDs.contains("ollama.projection"))
}
```

**Step 2: Run to verify failure**

Run: `swift test --filter OllamaProviderTests`
Expected: FAIL — `ollama.projection` not present.

**Step 3: Implement**

- In `OllamaProvider.widgetDescriptors`, after the weekly descriptor:
  ```swift
  // Derived from the Session/Weekly meters above; nil (renders "No data") until a web session
  // supplies reset instants — see OllamaResetSource.
  .projectionSummary(provider: provider)
  ```
- In `DefaultLayout.metricIDs`, change line 44 to:
  ```swift
  "ollama.session", "ollama.weekly", "ollama.projection", "ollama.last4Weeks",
  ```
  (Always Visible + unpinned: absent from `expandedMetricIDs` and `pinnedMetricIDs`.)

**Step 4: Run to verify pass**

Run: `swift test --filter 'OllamaProviderTests|LayoutStoreTests'`
Expected: PASS.

**Step 5: Commit**

```bash
git add Sources/OpenUsage/Providers/Ollama/OllamaProvider.swift Sources/OpenUsage/Stores/DefaultLayout.swift Tests/OpenUsageTests/OllamaProviderTests.swift
git commit -m "feat(ollama): add Run-out projection row"
```

---

## Task 6: Restore `WebPageRefresher` and the in-app sign-in

**Files:**
- Create: `Sources/OpenUsage/Services/WebPageRefresher.swift` (contents of `git show 2bc8660e:Sources/OpenUsage/Services/WebPageRefresher.swift`)
- Create: `Sources/OpenUsage/Providers/Ollama/OllamaLoginController.swift` (contents of `git show dd127949:Sources/OpenUsage/Providers/Ollama/OllamaLoginController.swift`, adapted below)
- Create: `Sources/OpenUsage/Views/OllamaLoginView.swift` (contents of `git show dd127949:Sources/OpenUsage/Views/OllamaLoginView.swift`, adapted below)

**Step 1: Restore `WebPageRefresher` verbatim**

Use the file exactly as in `2bc8660e`. It is a `@MainActor` `NSObject`/`WKNavigationDelegate` that loads a URL with injected cookies into a non-persistent store and returns `document.body.innerText`. (Full source available in that commit.)

**Step 2: Adapt the login controller**

Start from `dd127949:.../OllamaLoginController.swift`. Changes:
- Drop the single-cookie assumption (`sessionCookieName`). After the page parses, capture **all** `ollama.com` cookies into one header:
  ```swift
  private func cookieHeader(from webView: WKWebView) async -> String? {
      await withCheckedContinuation { cont in
          webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
              let header = cookies
                  .filter { $0.domain.contains("ollama") }
                  .map { "\($0.name)=\($0.value)" }
                  .joined(separator: "; ")
              cont.resume(returning: header.isEmpty ? nil : header)
          }
      }
  }
  ```
- Replace `OllamaUsageData`/`parseSettingsText` with `OllamaResetParser`: success when `OllamaResetParser.resets(fromText: text, now: Date())` returns non-nil, OR simply when the page text contains "Session usage" (so sign-in succeeds even if no reset is shown yet). Return a `OllamaLoginResult { cookieHeader: String }`.
- Keep the 1.5s polling loop and `didCapture` guard.

**Step 3: Adapt the login view**

Same `500x520` sheet with `WebBrowserView: NSViewRepresentable`, Cancel button, and `.onChange(of: controller.loginResult)`. Change `OllamaLoginResult` to carry `cookieHeader: String` instead of a cookie + usage data.

**Step 4: Build**

Run: `swift build`
Expected: build succeeds (WebKit is a system framework; no `Package.swift` change).

**Step 5: Commit**

```bash
git add Sources/OpenUsage/Services/WebPageRefresher.swift Sources/OpenUsage/Providers/Ollama/OllamaLoginController.swift Sources/OpenUsage/Views/OllamaLoginView.swift
git commit -m "feat(ollama): restore in-app WKWebView sign-in"
```

---

## Task 7: Thread the Sign In action to the provider header

**Files:**
- Modify: `Sources/OpenUsage/Views/ProviderSectionHeader.swift` (button after line 94)
- Modify: `Sources/OpenUsage/Views/WidgetGroupedListView.swift`
- Modify: `Sources/OpenUsage/Views/DashboardContentView.swift`
- Modify: `Sources/OpenUsage/Views/DashboardView.swift`

**Step 1: Add `onSignIn` to the header** (`ProviderSectionHeader.swift`, after the warning glyph, before `Spacer(minLength: 8)`):

```swift
if let onSignIn {
    Button("Sign In", action: onSignIn)
        .buttonStyle(.bordered)
        .controlSize(.mini)
}
```

Add `var onSignIn: (() -> Void)?` to the stored properties and an init parameter (with default `nil`), matching the removed `dd127949` shape.

**Step 2: Thread it down** — `WidgetGroupedListView` gains `var onSignIn: ((String) -> Void)?` and passes `onSignIn.map { cb in { cb(group.provider.id) } }` into the header; `DashboardContentView` gains and forwards the same closure. (Mirror `dd127949`.)

**Step 3: Present the sheet** — in `DashboardView`:

```swift
@State private var signInProvider: SignInProvider?
private let ollamaAuthStore = OllamaAuthStore()

// on DashboardContentView(..., onSignIn: { signInProvider = SignInProvider(id: $0) })

.sheet(item: $signInProvider) { provider in
    OllamaLoginView { result in
        try? ollamaAuthStore.saveSessionHeader(result.cookieHeader)
        Task { await dataStore.refresh(providerID: provider.id, force: true) }
    }
}
```

Add the private `SignInProvider: Identifiable` struct (`let id: String`), and clear `signInProvider` in `resetTransientState()`. Attach `.sheet` to the modifier chain ending at `DashboardView.swift:254`.

**Step 4: Build + run**

Run: `swift build` then relaunch the app per `script/build_and_run.sh`.
Expected: Ollama header shows a **Sign In** button; clicking opens the sheet.

**Step 5: Commit**

```bash
git add Sources/OpenUsage/Views/ProviderSectionHeader.swift Sources/OpenUsage/Views/WidgetGroupedListView.swift Sources/OpenUsage/Views/DashboardContentView.swift Sources/OpenUsage/Views/DashboardView.swift
git commit -m "feat(ollama): add Sign In action to the provider header"
```

---

## Task 8: Probe the live page; confirm or fall back to a WKWebView source

**Files:**
- Create (temporary): a dev dump of the authenticated settings HTML
- Test fixture: `Tests/OpenUsageTests/Fixtures/ollama-settings.html` (sanitized)

**Step 1: Capture** — after signing in and refreshing once, add a temporary log of the fetched HTML (`AppLog.info(.refresh, html.prefix(4000))`), or dump it from the sign-in webview. **Redact** any account identifiers (email, name, avatar URL) before saving as a fixture.

**Step 2: Verify the parser against reality**

- If the HTML contains `data-time="…"` for both windows in session-then-weekly order, Task 2's HTTP source is correct: add a parser test using the sanitized fixture and remove the temporary log. Done.
- If the reset markup is **not** in the server HTML (JS-rendered), implement `OllamaWebViewResetSource: OllamaResetSource` using the restored `WebPageRefresher` (load `/settings` with the session cookies, `evaluateJavaScript` the `data-time` elements), and default `OllamaProvider.resetSource` to it. Add a test with a fake `WebPageRefresher` returning canned text.

**Step 3: Commit**

```bash
git add Tests/OpenUsageTests Sources/OpenUsage/Providers/Ollama
git commit -m "test(ollama): pin the reset parser to a live settings fixture"
```

---

## Task 9: Docs and error surface

**Files:**
- Modify: `docs/providers/ollama.md`
- Modify: `Sources/OpenUsage/Providers/Ollama/OllamaProvider.swift` (warning on expired session — optional, only if Task 8 shows it's needed)

**Step 1:** Update `docs/providers/ollama.md`:
- Session/Weekly now show a reset countdown once you sign in (in-app Sign In button), and a Run-out row appears.
- Sign-in stores an ollama.com web-session cookie in the Keychain; values still come from the signed API.
- "No countdown / No data on Run-out" → not signed in to the web, or the session expired; click Sign In again.
- Note the reset times come from the settings page (undocumented); a page change may disable them until updated.

**Step 2:** Verify docs build-free and run the full suite.

Run: `swift test --filter Ollama`
Expected: PASS.

**Step 3: Commit**

```bash
git add docs/providers/ollama.md
git commit -m "docs(ollama): document reset countdown and run-out row"
```

---

## Task 10: End-to-end verification

**Step 1:** Build and relaunch: `script/build_and_run.sh` (kill the running instance first — no hot reload).

**Step 2:** In Customize, confirm Ollama's Session/Weekly/Run-out are enabled and Run-out is Always Visible; the Run-out row shows a chart, not "No data".

**Step 3:** Confirm the Session/Weekly rows show a real countdown, and the menu-bar pins still show percentages.

**Step 4:** Sign out / clear the stored session (Keychain) and refresh: verify the meters still show values (API path) with no countdown, and **no** "No data" regression that hides the meters.

**Step 5:** Take a screenshot of the Ollama card and attach it to the PR (visual change → required by AGENTS.md).

**Step 6: Commit any final fixes**, then open the PR using the repo's PR template (TL;DR / What was happening / What this changes / Heads-up / Tests / Screenshots).

```bash
git add -A
git commit -m "test(ollama): verify reset countdown and run-out row end to end"
```

---

## Notes for the implementer

- **No hot reload:** every code change needs a full rebuild and relaunch (AGENTS.md).
- **Never invent a period without a reset:** `periodDurationMs` is only attached when `resetsAt` is present (Task 3), or the row reads a static "Resets in 5h" that never moves.
- **`hasLocalCredentials()` stays `false`:** Ollama remains opt-in; the web session is not a local credential probe.
- **Upstream conflict risk:** `OllamaProvider.swift` is upstream-owned; keep the diff minimal.
- **Cookie names are opaque:** never hardcode `wos-session`/`__Secure-session`; capture/forward the whole cookie header.
