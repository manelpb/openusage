import XCTest
@testable import OpenUsage

final class OllamaResetSourceTests: XCTestCase {
    func testParsesResetsFromSettingsHTML() async throws {
        let html = #"<span data-time="2026-09-19T19:55:00Z"></span><span data-time="2026-09-24T11:55:00Z"></span>"#
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data(html.utf8)))
        let source = OllamaHTTPResetSource(http: http)
        let resets = try await source.resets(cookieHeader: "wos-session=abc")
        XCTAssertEqual(resets?.session, OpenUsageISO8601.date(from: "2026-09-19T19:55:00Z"))
        XCTAssertEqual(resets?.weekly, OpenUsageISO8601.date(from: "2026-09-24T11:55:00Z"))
        XCTAssertEqual(http.requests.first?.headers["Cookie"], "wos-session=abc")
    }

    func testNon2xxThrows() async {
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 500, headers: [:], body: Data()))
        let source = OllamaHTTPResetSource(http: http)
        do { _ = try await source.resets(cookieHeader: "x"); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? OllamaUsageError, .requestFailed(500)) }
    }

    /// A 401/403 from the settings fetch is the server rejecting the session, not a transient failure —
    /// the provider relies on this classification to clear the dead cookie.
    func testUnauthorizedThrowsNotSignedIn() async {
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 401, headers: [:], body: Data()))
        let source = OllamaHTTPResetSource(http: http)
        do { _ = try await source.resets(cookieHeader: "expired"); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? OllamaAuthError, .notSignedIn) }
    }

    func testForbiddenThrowsNotSignedIn() async {
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 403, headers: [:], body: Data()))
        let source = OllamaHTTPResetSource(http: http)
        do { _ = try await source.resets(cookieHeader: "expired"); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? OllamaAuthError, .notSignedIn) }
    }

    func testUndecodableBodyThrowsInvalidResponse() async {
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data([0xFF, 0xFE, 0xFD])))
        let source = OllamaHTTPResetSource(http: http)
        do {
            _ = try await source.resets(cookieHeader: "x")
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? OllamaUsageError, .invalidResponse)
        }
    }

    func testUnparseablePageReturnsNil() async throws {
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data("<html/>".utf8)))
        let source = OllamaHTTPResetSource(http: http)
        let resets = try await source.resets(cookieHeader: "x")
        XCTAssertNil(resets)
    }

    func testSignInPageThrowsNotSignedIn() async {
        let html = #"<html data-dpl-id="hosted-authkit-abc"><body>Sign in</body></html>"#
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data(html.utf8)))
        let source = OllamaHTTPResetSource(http: http)
        do {
            _ = try await source.resets(cookieHeader: "expired")
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? OllamaAuthError, .notSignedIn)
        }
    }

    func testFallsBackToTextWhenNoDataTime() async throws {
        let html = "Session usage 3% used Sessions resume in 2 hours Weekly usage 30% used Resets in 5 days"
        let fixedDate = try XCTUnwrap(OpenUsageISO8601.date(from: "2026-09-19T12:00:00Z"))
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data(html.utf8)))
        let source = OllamaHTTPResetSource(http: http, now: { fixedDate })
        let resets = try await source.resets(cookieHeader: "wos-session=abc")
        XCTAssertEqual(resets?.session, fixedDate.addingTimeInterval(2 * 3600))
        XCTAssertEqual(resets?.weekly, fixedDate.addingTimeInterval(5 * 86400))
    }
}
