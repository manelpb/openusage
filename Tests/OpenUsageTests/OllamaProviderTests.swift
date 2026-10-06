import CryptoKit
import XCTest
@testable import OpenUsage

/// A live `GET /api/usage` response, trimmed to the fields OpenUsage reads.
private let usageJSON = #"""
{"activity":{"cost":"1.25000","period":{"type":"last_4_weeks","starting_at":"2026-08-03T00:00:00Z","ending_at":"2026-08-24T19:39:56Z"},"models":[]},
 "limits":{"session":{"usage":0.349,"models":[{"name":"minimax-m3","request_count":139}]},
           "weekly":{"usage":0.316,"models":[{"name":"minimax-m3","request_count":646}]}}}
"""#

private let accountJSON = #"{"ID":"527bb449","Email":"user@example.com","Name":"user","Plan":"pro"}"#

private func data(_ json: String) -> Data { Data(json.utf8) }

private func ok(_ json: String) -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: [:], body: data(json))
}

/// Answers per request path, so the required usage call and the best-effort account call can have
/// different outcomes — the case a single canned `FakeHTTPClient` response cannot express.
private final class RoutedHTTPClient: HTTPClient, @unchecked Sendable {
    private let responses: [String: HTTPResponse]

    init(_ responses: [String: HTTPResponse]) { self.responses = responses }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        responses[request.url.path] ?? HTTPResponse(statusCode: 404, headers: [:], body: Data())
    }
}

/// Builds an unencrypted OpenSSH ed25519 private key in memory, so no key material is ever committed
/// to the repository (a hardcoded PEM is a real private key as far as any secret scanner is concerned,
/// throwaway or not). Mirrors the container OpenSSH documents in `PROTOCOL.key`:
///
///     "openssh-key-v1\0" | string cipher | string kdf | string kdfoptions | uint32 keycount
///                        | string publickey | string privatekeys
///
/// Generating it per run also makes the parser tests stronger than a fixture would: they prove a real
/// round-trip rather than that one frozen blob still parses.
private enum TestSigningKey {
    /// `declaredPublicKey` overrides the container's outer public key — the half sent in the
    /// `Authorization` header — without touching the private half, reproducing the damaged file that
    /// signs correctly but identifies the wrong account.
    static func make(declaredPublicKey: Data? = nil) -> (pem: String, publicKeyRaw: Data) {
        let privateKey = Curve25519.Signing.PrivateKey()
        let seed = privateKey.rawRepresentation
        let publicKeyRaw = privateKey.publicKey.rawRepresentation
        let publicKeyBlob = string("ssh-ed25519") + string(declaredPublicKey ?? publicKeyRaw)

        var privateSection = uint32(0x1234_5678) + uint32(0x1234_5678)  // matching checkints
        privateSection += string("ssh-ed25519")
        privateSection += string(publicKeyRaw)
        privateSection += string(seed + publicKeyRaw)                   // ed25519 private = seed || public
        privateSection += string("")                                    // comment
        // The "none" cipher still pads to an 8-byte block, with 1, 2, 3, … as the filler.
        var padding: UInt8 = 1
        while privateSection.count % 8 != 0 {
            privateSection.append(padding)
            padding += 1
        }

        var blob = Data("openssh-key-v1\0".utf8)
        blob += string("none") + string("none") + string("")            // cipher, kdf, kdfoptions
        blob += uint32(1)                                               // key count
        blob += string(publicKeyBlob)
        blob += string(privateSection)

        let body = blob.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let pem = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        \(body)
        -----END OPENSSH PRIVATE KEY-----
        """
        return (pem, publicKeyRaw)
    }

    /// SSH wire format: a big-endian `uint32` length followed by the payload.
    private static func string(_ payload: Data) -> Data { uint32(UInt32(payload.count)) + payload }
    private static func string(_ text: String) -> Data { string(Data(text.utf8)) }

    private static func uint32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}

private let testKey = TestSigningKey.make()
private let testPrivateKeyPEM = testKey.pem

// MARK: - Key parsing

final class OpenSSHEd25519KeyTests: XCTestCase {
    func testParsesUnencryptedEd25519Key() throws {
        let key = try XCTUnwrap(OpenSSHEd25519Key.parse(pem: testPrivateKeyPEM))

        XCTAssertEqual(key.seed.count, 32)
        // The public half is the SSH wire-format blob: the "ssh-ed25519" type string (4 + 11 bytes)
        // followed by the 32-byte raw key (4 + 32), and it must be the key that was written.
        let blob = try XCTUnwrap(Data(base64Encoded: key.publicKeyBase64))
        XCTAssertEqual(blob.count, 51)
        XCTAssertTrue(String(decoding: blob, as: UTF8.self).contains("ssh-ed25519"))
        XCTAssertEqual(Data(blob.suffix(32)), testKey.publicKeyRaw)
        // The seed round-trips too: it must derive the same public key.
        let derived = try Curve25519.Signing.PrivateKey(rawRepresentation: key.seed)
        XCTAssertEqual(derived.publicKey.rawRepresentation, testKey.publicKeyRaw)
    }

    /// Regression: the outer public key is what the `Authorization` header carries, while the signature
    /// comes from the seed. A file pairing an intact private key with a foreign public half used to parse
    /// fine, then get rejected by ollama.com as "not signed in" — a dead end the user cannot fix by
    /// signing in again.
    func testRejectsKeyWhoseDeclaredPublicHalfDoesNotMatchItsPrivateHalf() {
        let foreign = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let damaged = TestSigningKey.make(declaredPublicKey: foreign)

        XCTAssertNil(OpenSSHEd25519Key.parse(pem: damaged.pem))
    }

    func testRejectsMalformedAndTruncatedKeys() {
        let body = testPrivateKeyPEM
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        let truncated = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        \(String(body.prefix(body.count / 2)))
        -----END OPENSSH PRIVATE KEY-----
        """
        let cases = [
            "",
            "not a key at all",
            "-----BEGIN OPENSSH PRIVATE KEY-----\nZm9v\n-----END OPENSSH PRIVATE KEY-----",
            truncated
        ]

        for pem in cases {
            XCTAssertNil(OpenSSHEd25519Key.parse(pem: pem), pem.prefix(40).description)
        }
    }
}

// MARK: - Auth store

final class OllamaAuthStoreTests: XCTestCase {
    func testReturnsNilWhenOllamaIsNotInstalled() throws {
        let store = OllamaAuthStore(files: FakeFiles())
        XCTAssertNil(try store.loadSigningKey())
    }

    func testReadsTheKeyOllamaWrites() throws {
        let store = OllamaAuthStore(files: FakeFiles([OllamaAuthStore.keyPath: testPrivateKeyPEM]))
        XCTAssertNotNil(try store.loadSigningKey())
    }

    func testUnparseableKeyThrowsInsteadOfReadingAsLoggedOut() {
        let store = OllamaAuthStore(files: FakeFiles([OllamaAuthStore.keyPath: "garbage"]))
        XCTAssertThrowsError(try store.loadSigningKey()) { error in
            XCTAssertEqual(error as? OllamaAuthError, .invalidKey)
        }
    }

    func testSessionHeaderRoundTripsThroughTheKeychain() throws {
        let store = OllamaAuthStore(files: FakeFiles(), keychain: FakeKeychain())

        XCTAssertNil(store.loadSessionHeader())
        try store.saveSessionHeader("wos-session=abc")
        XCTAssertEqual(store.loadSessionHeader(), "wos-session=abc")
    }

    func testClearingTheSessionHeaderRemovesItFromTheKeychain() throws {
        let store = OllamaAuthStore(files: FakeFiles(), keychain: FakeKeychain())
        try store.saveSessionHeader("wos-session=abc")
        XCTAssertNotNil(store.loadSessionHeader())

        try store.clearSessionHeader()

        XCTAssertNil(store.loadSessionHeader())
    }
}

// MARK: - Request signing

final class OllamaRequestSignerTests: XCTestCase {
    func testSignsTheMethodAndTimestampedURIOllamaExpects() async throws {
        let key = try XCTUnwrap(OpenSSHEd25519Key.parse(pem: testPrivateKeyPEM))
        let http = FakeHTTPClient(response: ok(usageJSON))
        let client = OllamaUsageClient(http: http, now: { Date(timeIntervalSince1970: 1_700_000_000) })

        _ = try await client.fetchUsage(key: key)

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url.absoluteString, "https://ollama.com/api/usage?ts=1700000000")

        // The header is "<base64 public key>:<base64 signature>" over "<METHOD>,<request-uri>".
        let header = try XCTUnwrap(request.headers["Authorization"])
        let parts = header.split(separator: ":", maxSplits: 1).map(String.init)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0], key.publicKeyBase64)

        let signature = try XCTUnwrap(Data(base64Encoded: parts[1]))
        let blob = try XCTUnwrap(Data(base64Encoded: key.publicKeyBase64))
        // The raw public key is the last 32 bytes of the SSH blob (type string + length + key).
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(blob.suffix(32)))
        XCTAssertTrue(publicKey.isValidSignature(signature, for: Data("GET,/api/usage?ts=1700000000".utf8)))
    }

    func testAccountRequestIsAPost() async throws {
        let key = try XCTUnwrap(OpenSSHEd25519Key.parse(pem: testPrivateKeyPEM))
        let http = FakeHTTPClient(response: ok(accountJSON))
        let client = OllamaUsageClient(http: http, now: { Date(timeIntervalSince1970: 1_700_000_000) })

        _ = try await client.fetchAccount(key: key)

        XCTAssertEqual(http.requests.first?.method, "POST")
        XCTAssertEqual(http.requests.first?.url.absoluteString, "https://ollama.com/api/me?ts=1700000000")
    }
}

// MARK: - Mapping

final class OllamaUsageMapperTests: XCTestCase {
    func testMapsLiveResponseToSessionWeeklyAndSpend() throws {
        let mapped = try OllamaUsageMapper.map(usageBody: data(usageJSON), accountBody: data(accountJSON))

        XCTAssertEqual(mapped.plan, .named("Pro"))
        XCTAssertEqual(mapped.lines.count, 3)

        // `usage` arrives as a fraction of the plan allowance, so 0.349 is 34.9%, not 0.349%.
        guard case .progress(let label, let used, let limit, let format, let resetsAt, let periodMs, _) =
                mapped.lines[0] else {
            return XCTFail("expected a session meter, got \(mapped.lines[0])")
        }
        XCTAssertEqual(label, "Session")
        XCTAssertEqual(used, 34.9, accuracy: 0.0001)
        XCTAssertEqual(limit, 100)
        XCTAssertEqual(format, .percent)
        // The usage payload itself carries neither a reset instant nor the current window's start, and
        // this call passes no `resets`, so the meter carries no countdown and no period — a period
        // without a reset date renders as a static "Resets in 5h".
        XCTAssertNil(resetsAt)
        XCTAssertNil(periodMs)

        guard case .progress(let weeklyLabel, let weeklyUsed, _, _, _, let weeklyPeriod, _) =
                mapped.lines[1] else {
            return XCTFail("expected a weekly meter, got \(mapped.lines[1])")
        }
        XCTAssertEqual(weeklyLabel, "Weekly")
        XCTAssertEqual(weeklyUsed, 31.6, accuracy: 0.0001)
        XCTAssertNil(weeklyPeriod)

        // `cost` is a decimal string, not a number.
        guard case .values(let spendLabel, let values, _, _, _, _) = mapped.lines[2] else {
            return XCTFail("expected a spend row, got \(mapped.lines[2])")
        }
        XCTAssertEqual(spendLabel, "Last 4 Weeks")
        XCTAssertEqual(values.map(\.kind), [.dollars])
        XCTAssertEqual(values.first?.number, 1.25)
    }

    func testMetricLabelsMatchTheProvidersWidgetDescriptors() async throws {
        let mapped = try OllamaUsageMapper.map(usageBody: data(usageJSON), accountBody: nil)
        // The Run-out row is derived by `WidgetDataStore`, not emitted in the snapshot, so it is the one
        // descriptor without a matching mapped line.
        let descriptors = await MainActor.run { OllamaProvider().widgetDescriptors }
        XCTAssertEqual(descriptors.filter(\.isProjectionSummary).map(\.id), ["ollama.projection"])
        let labels = descriptors.filter { !$0.isProjectionSummary }.map(\.metricLabel)

        // This captured response predates the monthly meter and must still omit absent limits.
        XCTAssertEqual(mapped.lines.map(\.label), labels.filter { $0 != "Monthly" })
    }

    func testMissingLimitsIsALoudFailureRatherThanAnEmptyDashboard() {
        XCTAssertThrowsError(try OllamaUsageMapper.usageLines(data(#"{"activity":{"cost":"0"}}"#))) { error in
            XCTAssertEqual(error as? OllamaUsageError, .invalidResponse)
        }
        XCTAssertThrowsError(try OllamaUsageMapper.usageLines(data("not json"))) { error in
            XCTAssertEqual(error as? OllamaUsageError, .invalidResponse)
        }
    }

    func testAbsentMeterIsOmittedRatherThanShownAtZero() throws {
        let lines = try OllamaUsageMapper.usageLines(data(#"{"limits":{"weekly":{"usage":0.5}}}"#))

        XCTAssertEqual(lines.map(\.label), ["Weekly"])
    }

    func testEmptyLimitsReadAsNoUsageData() throws {
        XCTAssertEqual(try OllamaUsageMapper.usageLines(data(#"{"limits":{}}"#)), [.noUsageData])
    }

    func testPlanNameAcceptsBothCasingsAndIsTitleCased() {
        XCTAssertEqual(OllamaUsageMapper.plan(from: data(#"{"Plan":"pro"}"#)), .named("Pro"))
        XCTAssertEqual(OllamaUsageMapper.plan(from: data(#"{"plan":"max"}"#)), .named("Max"))
        // An explicitly empty plan is an account without one — ordinary, and not a failure.
        XCTAssertEqual(OllamaUsageMapper.plan(from: data(#"{"Plan":""}"#)), .absent)
        // Anything OpenUsage cannot read as an account is a failure, including a renamed or retyped
        // field, so the provider can say why the badge is missing instead of dropping it silently.
        XCTAssertEqual(OllamaUsageMapper.plan(from: data("not json")), .unreadable)
        XCTAssertEqual(OllamaUsageMapper.plan(from: data("[]")), .unreadable)
        XCTAssertEqual(OllamaUsageMapper.plan(from: data(#"{"Name":"user"}"#)), .unreadable)
        XCTAssertEqual(OllamaUsageMapper.plan(from: data(#"{"Plan":42}"#)), .unreadable)
    }

    func testResetsAreAttachedToTheMetersWithPeriodLengths() throws {
        let resets = OllamaResets(session: OpenUsageISO8601.date(from: "2026-09-19T19:55:00Z"),
                                  weekly: OpenUsageISO8601.date(from: "2026-09-24T11:55:00Z"))
        let mapped = try OllamaUsageMapper.map(usageBody: data(usageJSON), accountBody: nil, resets: resets)
        guard case .progress(_, _, _, _, let sessionReset, let sessionMs, _) = mapped.lines[0],
              case .progress(_, _, _, _, let weeklyReset, let weeklyMs, _) = mapped.lines[1] else {
            return XCTFail("expected progress lines")
        }
        XCTAssertEqual(sessionReset, resets.session)
        XCTAssertEqual(weeklyReset, resets.weekly)
        XCTAssertEqual(sessionMs, 18_000_000)
        XCTAssertEqual(weeklyMs, 604_800_000)
    }

    func testWeeklyOnlyResetLeavesSessionUnbounded() throws {
        let resets = OllamaResets(session: nil, weekly: OpenUsageISO8601.date(from: "2026-09-24T11:55:00Z"))
        let mapped = try OllamaUsageMapper.map(usageBody: data(usageJSON), accountBody: nil, resets: resets)
        guard case .progress(_, _, _, _, let sessionReset, let sessionMs, _) = mapped.lines[0],
              case .progress(_, _, _, _, let weeklyReset, let weeklyMs, _) = mapped.lines[1] else {
            return XCTFail("expected Session and Weekly progress lines")
        }
        XCTAssertNil(sessionReset)
        XCTAssertNil(sessionMs, "a session meter with no reset instant must not carry a period")
        XCTAssertEqual(weeklyReset, resets.weekly)
        XCTAssertEqual(weeklyMs, 604_800_000)
    }

    func testNoResetsLeavesTheMetersUnchanged() throws {
        let mapped = try OllamaUsageMapper.map(usageBody: data(usageJSON), accountBody: nil)
        guard case .progress(_, _, _, _, let reset, let period, _) = mapped.lines[0] else { return XCTFail() }
        XCTAssertNil(reset)
        XCTAssertNil(period)
    }
}

// MARK: - Provider

@MainActor
final class OllamaProviderRefreshTests: XCTestCase {
    func testMissingKeyReportsNotLoggedInWithoutCallingTheNetwork() async {
        let http = FakeHTTPClient(response: ok(usageJSON))
        let provider = OllamaProvider(
            authStore: OllamaAuthStore(files: FakeFiles()),
            usageClient: OllamaUsageClient(http: http, now: { Date(timeIntervalSince1970: 0) })
        )

        let snapshot = await provider.refresh()

        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    func testUnauthorizedUsageReportsSignInRatherThanAnHTTPError() async {
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 401, headers: [:], body: Data()))
        let provider = makeProvider(http: http)

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertEqual(snapshot.lines.first?.label, MetricLine.errorBadgeLabel)
    }

    func testServerErrorSurfacesAsAnHTTPFailure() async {
        let provider = makeProvider(http: FakeHTTPClient(
            response: HTTPResponse(statusCode: 503, headers: [:], body: Data())
        ))

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .http5xx)
    }

    /// The account call is best-effort: `FakeHTTPClient` answers every request with the usage body, so
    /// the plan can't be read — the meters must still map.
    func testMetersSurviveAnUnreadablePlanResponse() async {
        let provider = makeProvider(http: FakeHTTPClient(response: ok(usageJSON)))

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.plan)
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Last 4 Weeks"])
    }

    /// Ollama is opt-in: the signing key exists from Ollama's first run, so probing it would auto-enable
    /// the provider for every local-models user and greet them with a Cloud sign-in warning. The probe
    /// must stay false even when a perfectly good key is on disk.
    func testProviderIsOptInEvenWithAUsableKeyOnDisk() async {
        let provider = makeProvider(http: FakeHTTPClient(response: ok(usageJSON)))

        let hasCredentials = await provider.hasLocalCredentials()

        XCTAssertFalse(hasCredentials)
    }

    /// Regression: a failing plan lookup used to be indistinguishable from an account that simply has
    /// no plan. The meters must still refresh, but the failure has to be visible.
    func testFailedPlanLookupWarnsAndKeepsTheMeters() async {
        let provider = makeProvider(http: RoutedHTTPClient([
            OllamaUsageClient.usagePath: ok(usageJSON),
            OllamaUsageClient.accountPath: HTTPResponse(statusCode: 500, headers: [:], body: Data())
        ]))

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.plan)
        XCTAssertNotNil(snapshot.warning)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Last 4 Weeks"])
    }

    /// Regression: the failure path covered HTTP 500, but a `200 OK` carrying a body OpenUsage cannot
    /// read dropped the plan badge with no warning at all — the silent disappearance this warning exists
    /// to prevent.
    func testUnreadablePlanResponseWarnsAndKeepsTheMeters() async {
        for body in ["not json", "[]", #"{"Name":"user"}"#] {
            let provider = makeProvider(http: RoutedHTTPClient([
                OllamaUsageClient.usagePath: ok(usageJSON),
                OllamaUsageClient.accountPath: ok(body)
            ]))

            let snapshot = await provider.refresh()

            XCTAssertNil(snapshot.errorCategory, body)
            XCTAssertNil(snapshot.plan, body)
            XCTAssertNotNil(snapshot.warning, body)
            XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Last 4 Weeks"], body)
        }
    }

    /// The same warning text for both causes, so a failed request and an unreadable body are not two
    /// different-looking problems to the user.
    func testUnreadableAndFailedPlanLookupsShareOneWarning() async {
        let unreadable = makeProvider(http: RoutedHTTPClient([
            OllamaUsageClient.usagePath: ok(usageJSON),
            OllamaUsageClient.accountPath: ok("not json")
        ]))
        let failed = makeProvider(http: RoutedHTTPClient([
            OllamaUsageClient.usagePath: ok(usageJSON),
            OllamaUsageClient.accountPath: HTTPResponse(statusCode: 500, headers: [:], body: Data())
        ]))

        let unreadableWarning = await unreadable.refresh().warning
        let failedWarning = await failed.refresh().warning

        XCTAssertNotNil(unreadableWarning)
        XCTAssertEqual(unreadableWarning, failedWarning)
    }

    /// An account with no plan is not a fault: the badge is simply absent, with nothing to warn about.
    func testAccountWithoutAPlanIsNotTreatedAsAFailure() async {
        let provider = makeProvider(http: RoutedHTTPClient([
            OllamaUsageClient.usagePath: ok(usageJSON),
            OllamaUsageClient.accountPath: ok(#"{"Name":"user","Plan":""}"#)
        ]))

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.plan)
        XCTAssertNil(snapshot.warning)
    }

    func testSuccessfulPlanLookupCarriesNoWarning() async {
        let provider = makeProvider(http: RoutedHTTPClient([
            OllamaUsageClient.usagePath: ok(usageJSON),
            OllamaUsageClient.accountPath: ok(accountJSON)
        ]))

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertNil(snapshot.warning)
    }

    /// The spend row counts charges beyond the plan, so $0.00 does not mean an idle period. Marking it
    /// as a usage period would give it the "No usage in this period" hover, which would be wrong for a
    /// subscriber who used Ollama heavily inside their allowance.
    func testSpendRowIsNotMarkedAsAUsagePeriod() {
        let descriptors = OllamaProvider().widgetDescriptors
        let spend = descriptors.first { $0.id == "ollama.last4Weeks" }

        XCTAssertEqual(spend?.sample.isUsagePeriod, false)
    }

    func testOffersAProjectionRow() {
        let ids = OllamaProvider().widgetDescriptors.map(\.id)
        XCTAssertTrue(ids.contains("ollama.projection"), "expected Run-out row: \(ids)")
    }

    func testProjectionRowIsAlwaysVisibleAndUnpinnedByDefault() {
        XCTAssertTrue(DefaultLayout.metricIDs.contains("ollama.projection"))
        XCTAssertFalse(DefaultLayout.expandedMetricIDs.contains("ollama.projection"))
        XCTAssertFalse(DefaultLayout.pinnedMetricIDs.contains("ollama.projection"))
    }

    /// Drives the header's Sign In gating: false until a refresh has cached the (off-main) keychain
    /// read, then true only while a web session cookie is stored. Never reads the keychain itself.
    func testHasStoredWebSessionReflectsTheLastRefresh() async {
        let withSession = makeProvider(http: FakeHTTPClient(response: ok(usageJSON)),
                                       sessionHeader: "wos-session=abc")
        let withoutSession = makeProvider(http: FakeHTTPClient(response: ok(usageJSON)))

        XCTAssertFalse(withSession.hasStoredWebSession(), "no keychain read before a refresh")
        XCTAssertFalse(withoutSession.hasStoredWebSession())

        _ = await withSession.refresh()
        _ = await withoutSession.refresh()

        XCTAssertTrue(withSession.hasStoredWebSession())
        XCTAssertFalse(withoutSession.hasStoredWebSession())
    }

}

/// A provider wired to the in-memory key fixture, a canned HTTP client, and an optional web session.
/// `sessionHeader` is seeded through the fake keychain, so a provider with no header behaves exactly
/// like the pre-session provider. Each call gets an isolated reset cache so no test touches the real
/// `UserDefaults` domain.
@MainActor
private func makeProvider(
    http: any HTTPClient,
    resetSource: any OllamaResetSource = FakeResetSource(result: nil),
    resetCache: OllamaResetCache = OllamaResetCache(
        userDefaults: UserDefaults(suiteName: "ollamaProviderTests.\(UUID().uuidString)")!
    ),
    now: Date = Date(timeIntervalSince1970: 0),
    sessionHeader: String? = nil
) -> OllamaProvider {
    OllamaProvider(
        authStore: OllamaAuthStore(
            files: FakeFiles([OllamaAuthStore.keyPath: testPrivateKeyPEM]),
            keychain: FakeKeychain(sessionHeader)
        ),
        usageClient: OllamaUsageClient(http: http, now: { now }),
        resetSource: resetSource,
        resetCache: resetCache,
        now: { now }
    )
}

/// Same wiring as `makeProvider`, but hands back the keychain so a test can assert the stored session
/// survived or was cleared by a refresh.
@MainActor
private func makeProvider(
    http: any HTTPClient,
    keychain: FakeKeychain,
    resetSource: any OllamaResetSource = FakeResetSource(result: nil),
    resetCache: OllamaResetCache = OllamaResetCache(
        userDefaults: UserDefaults(suiteName: "ollamaProviderTests.\(UUID().uuidString)")!
    ),
    now: Date = Date(timeIntervalSince1970: 0)
) -> OllamaProvider {
    OllamaProvider(
        authStore: OllamaAuthStore(
            files: FakeFiles([OllamaAuthStore.keyPath: testPrivateKeyPEM]),
            keychain: keychain
        ),
        usageClient: OllamaUsageClient(http: http, now: { now }),
        resetSource: resetSource,
        resetCache: resetCache,
        now: { now }
    )
}

private struct FakeResetSource: OllamaResetSource {
    var result: OllamaResets?
    var error: Error?
    func resets(cookieHeader: String) async throws -> OllamaResets? {
        if let error { throw error }
        return result
    }
}

/// Reads back a stored session but fails every delete, so a test can prove the session flag and cache
/// still clear after a rejected session even when local cleanup fails.
private final class DeleteFailingKeychain: KeychainAccessing, @unchecked Sendable {
    private let value: String

    init(_ value: String) { self.value = value }

    func readGenericPassword(service: String) throws -> String? { value }
    func writeGenericPassword(service: String, value: String) throws {}
    func deleteGenericPasswordForCurrentUser(service: String) throws {
        throw KeychainError.deleteFailed("delete unavailable")
    }
}

/// Counts calls so a test can prove the cache short-circuits the settings fetch.
private final class CountingResetSource: OllamaResetSource, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var result: OllamaResets?

    init(result: OllamaResets?) { self.result = result }

    var calls: Int { lock.withLock { count } }

    func resets(cookieHeader: String) async throws -> OllamaResets? {
        lock.withLock { count += 1 }
        return result
    }
}

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

    func testEmptyResetsAreNotStored() {
        let suite = "ollamaResetCache.empty.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cache = OllamaResetCache(userDefaults: defaults)

        cache.store(OllamaResets(session: nil, weekly: nil), now: now)

        XCTAssertNil(cache.current(now: now))
    }

    /// Once the 5h session instant elapses, the cached pair must stop being served even while the 7d
    /// weekly instant is still in the future — otherwise a past session reset is attached for days.
    func testElapsedSessionResetInvalidatesCache() {
        let suite = "ollamaResetCache.elapsed.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cache = OllamaResetCache(userDefaults: defaults)
        cache.store(OllamaResets(session: now.addingTimeInterval(3600),
                                 weekly: now.addingTimeInterval(7200)),
                    now: now)

        XCTAssertNil(cache.current(now: now.addingTimeInterval(5400)))
    }
}

final class OllamaResetsTests: XCTestCase {
    func testSanitizedDropsElapsedInstantsAndKeepsFutureOnes() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let resets = OllamaResets(session: now.addingTimeInterval(-1),
                                  weekly: now.addingTimeInterval(3600))

        XCTAssertEqual(resets.sanitized(now: now),
                       OllamaResets(session: nil, weekly: now.addingTimeInterval(3600)))
    }

    func testSanitizedOfFullyElapsedResetsIsEmpty() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let resets = OllamaResets(session: now.addingTimeInterval(-3600),
                                  weekly: now.addingTimeInterval(-1))

        XCTAssertEqual(resets.sanitized(now: now), OllamaResets(session: nil, weekly: nil))
    }
}

@MainActor
final class OllamaProviderResetTests: XCTestCase {
    func testProviderAttachesResetsFromSource() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let resets = OllamaResets(session: now.addingTimeInterval(3600),
                                  weekly: now.addingTimeInterval(86400))
        let provider = makeProvider(http: RoutedHTTPClient([
            OllamaUsageClient.usagePath: ok(usageJSON),
            OllamaUsageClient.accountPath: ok(accountJSON)
        ]), resetSource: FakeResetSource(result: resets), now: now,
           sessionHeader: "wos-session=abc")
        let snapshot = await provider.refresh()
        guard case .progress(_, _, _, _, let reset, _, _) = snapshot.lines[0] else { return XCTFail() }
        XCTAssertEqual(reset, resets.session)
    }

    func testProviderWithoutSessionSkipsResets() async {
        let provider = makeProvider(http: RoutedHTTPClient([
            OllamaUsageClient.usagePath: ok(usageJSON),
            OllamaUsageClient.accountPath: ok(accountJSON)
        ]), resetSource: FakeResetSource(result: nil))
        let snapshot = await provider.refresh()
        guard case .progress(_, _, _, _, let reset, _, _) = snapshot.lines[0] else { return XCTFail() }
        XCTAssertNil(reset)
    }

    /// With no captured web session, the settings fetch must not even be attempted — the meters stay
    /// exactly as they were before resets existed.
    func testNoSessionHeaderDoesNotConsultTheSource() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let source = CountingResetSource(result: OllamaResets(
            session: now.addingTimeInterval(3600), weekly: now.addingTimeInterval(86400)))
        let provider = makeProvider(http: RoutedHTTPClient([
            OllamaUsageClient.usagePath: ok(usageJSON),
            OllamaUsageClient.accountPath: ok(accountJSON)
        ]), resetSource: source, now: now)

        let snapshot = await provider.refresh()

        XCTAssertEqual(source.calls, 0)
        guard case .progress(_, _, _, _, let reset, _, _) = snapshot.lines[0] else { return XCTFail() }
        XCTAssertNil(reset)
    }

    /// A cached reset that is still in the future must short-circuit the settings fetch entirely.
    func testCachedResetsSkipTheSettingsFetch() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let suite = "ollamaProviderResetCache.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = OllamaResetCache(userDefaults: defaults)
        cache.store(OllamaResets(session: now.addingTimeInterval(3600),
                                 weekly: now.addingTimeInterval(86400)),
                    now: now)
        let source = CountingResetSource(result: nil)
        let provider = makeProvider(http: RoutedHTTPClient([
            OllamaUsageClient.usagePath: ok(usageJSON),
            OllamaUsageClient.accountPath: ok(accountJSON)
        ]), resetSource: source, resetCache: cache, now: now, sessionHeader: "wos-session=abc")

        let snapshot = await provider.refresh()

        XCTAssertEqual(source.calls, 0)
        guard case .progress(_, _, _, _, let reset, _, _) = snapshot.lines[0] else { return XCTFail() }
        XCTAssertEqual(reset, now.addingTimeInterval(3600))
    }

    /// A cache whose session instant has since elapsed must not be trusted: the provider refetches and
    /// attaches the fresh instant instead of the stale one.
    func testExpiredCacheTriggersRefetch() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let suite = "ollamaProviderExpiredCache.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = OllamaResetCache(userDefaults: defaults)
        // Stored while both instants were future; the session instant has since elapsed.
        cache.store(OllamaResets(session: now.addingTimeInterval(-3600),
                                 weekly: now.addingTimeInterval(86400)),
                    now: now.addingTimeInterval(-7200))
        let freshSession = now.addingTimeInterval(1800)
        let source = CountingResetSource(result: OllamaResets(
            session: freshSession, weekly: now.addingTimeInterval(86400)))
        let provider = makeProvider(http: RoutedHTTPClient([
            OllamaUsageClient.usagePath: ok(usageJSON),
            OllamaUsageClient.accountPath: ok(accountJSON)
        ]), resetSource: source, resetCache: cache, now: now, sessionHeader: "wos-session=abc")

        let snapshot = await provider.refresh()

        XCTAssertEqual(source.calls, 1)
        guard case .progress(_, _, _, _, let reset, _, _) = snapshot.lines[0] else { return XCTFail() }
        XCTAssertEqual(reset, freshSession)
    }

    /// A rejected web session is not merely best-effort: the stored cookie must be dropped so the
    /// header's Sign In button returns, while the meters still render from the signed API.
    func testSignedOutResetSourceClearsTheStoredSessionAndStillReturnsMeters() async {
        let keychain = FakeKeychain("wos-session=abc")
        let provider = makeProvider(
            http: RoutedHTTPClient([
                OllamaUsageClient.usagePath: ok(usageJSON),
                OllamaUsageClient.accountPath: ok(accountJSON)
            ]),
            keychain: keychain,
            resetSource: FakeResetSource(result: nil, error: OllamaAuthError.notSignedIn)
        )
        XCTAssertFalse(provider.hasStoredWebSession(), "no keychain read before a refresh")

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Last 4 Weeks"])
        XCTAssertFalse(provider.hasStoredWebSession())
        XCTAssertNil(keychain.value, "the rejected session must be deleted from the keychain")
    }

    /// Signing out also drops the cached reset instants, so a stale countdown can't outlive its session.
    func testSignedOutResetSourceDropsTheCachedResets() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let suite = "ollamaProviderSignOutCache.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // Seed an already-elapsed session instant alongside a future weekly one, so `current` reports
        // the cache stale and the source is consulted.
        defaults.set(["session": now.addingTimeInterval(-3600).timeIntervalSince1970,
                      "weekly": now.addingTimeInterval(86400).timeIntervalSince1970],
                     forKey: OllamaResetCache.defaultsKey)
        let provider = makeProvider(
            http: RoutedHTTPClient([
                OllamaUsageClient.usagePath: ok(usageJSON),
                OllamaUsageClient.accountPath: ok(accountJSON)
            ]),
            keychain: FakeKeychain("wos-session=abc"),
            resetSource: FakeResetSource(result: nil, error: OllamaAuthError.notSignedIn),
            resetCache: OllamaResetCache(userDefaults: defaults),
            now: now
        )

        _ = await provider.refresh()

        XCTAssertNil(defaults.object(forKey: OllamaResetCache.defaultsKey))
    }

    /// The server has rejected the session regardless of local cleanup, so a failing keychain delete
    /// must not keep the Sign In button hidden or leave stale cached resets behind.
    func testSignedOutResetSourceClearsStateEvenWhenKeychainDeleteFails() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let suite = "ollamaProviderDeleteFailure.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // Seed an elapsed session + future weekly so `current` reports the cache stale and the source runs.
        defaults.set(["session": now.addingTimeInterval(-3600).timeIntervalSince1970,
                      "weekly": now.addingTimeInterval(86400).timeIntervalSince1970],
                     forKey: OllamaResetCache.defaultsKey)
        let provider = OllamaProvider(
            authStore: OllamaAuthStore(
                files: FakeFiles([OllamaAuthStore.keyPath: testPrivateKeyPEM]),
                keychain: DeleteFailingKeychain("wos-session=abc")
            ),
            usageClient: OllamaUsageClient(
                http: RoutedHTTPClient([
                    OllamaUsageClient.usagePath: ok(usageJSON),
                    OllamaUsageClient.accountPath: ok(accountJSON)
                ]),
                now: { now }
            ),
            resetSource: FakeResetSource(result: nil, error: OllamaAuthError.notSignedIn),
            resetCache: OllamaResetCache(userDefaults: defaults),
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertFalse(provider.hasStoredWebSession())
        XCTAssertNil(defaults.object(forKey: OllamaResetCache.defaultsKey),
                     "cache must clear even when the keychain delete fails")
    }

    /// A transport/parse failure is transient: it must leave the stored session in place so a flaky
    /// network never signs the user out.
    func testTransientResetFailureKeepsTheStoredSession() async {
        let keychain = FakeKeychain("wos-session=abc")
        let provider = makeProvider(
            http: RoutedHTTPClient([
                OllamaUsageClient.usagePath: ok(usageJSON),
                OllamaUsageClient.accountPath: ok(accountJSON)
            ]),
            keychain: keychain,
            resetSource: FakeResetSource(result: nil, error: OllamaUsageError.connectionFailed)
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertTrue(provider.hasStoredWebSession())
    }

    /// A reset-source failure is best-effort: it must leave the meters intact and must not turn the
    /// whole snapshot into an error.
    func testSourceFailureYieldsNilResetsWithoutErrorSnapshot() async {
        let provider = makeProvider(http: RoutedHTTPClient([
            OllamaUsageClient.usagePath: ok(usageJSON),
            OllamaUsageClient.accountPath: ok(accountJSON)
        ]), resetSource: FakeResetSource(result: nil, error: OllamaAuthError.notSignedIn),
           sessionHeader: "wos-session=abc")

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Last 4 Weeks"])
        guard case .progress(_, _, _, _, let reset, _, _) = snapshot.lines[0] else { return XCTFail() }
        XCTAssertNil(reset)
    }
}

/// The in-app Sign In button is capability-driven, not hardcoded: only providers that declare
/// `supportsInAppSignIn` render it (Ollama today).
@MainActor
final class ProviderSignInCapabilityTests: XCTestCase {
    func testOllamaOptsIntoInAppSignIn() {
        XCTAssertTrue(OllamaProvider().provider.supportsInAppSignIn)
    }

    func testOtherProvidersDoNotOptIntoInAppSignIn() {
        XCTAssertFalse(CursorProvider().provider.supportsInAppSignIn)
    }
}
