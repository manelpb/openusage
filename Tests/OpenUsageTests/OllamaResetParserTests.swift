import XCTest
@testable import OpenUsage

final class OllamaResetParserTests: XCTestCase {
    func testParsesDataTimeAttributesInOrder() {
        let html = """
        <span data-time="2026-09-19T19:55:00Z">Resets in 3h</span>
        <span data-time="2026-09-24T11:55:00Z">Resets in 5d</span>
        """
        let resets = OllamaResetParser.resets(fromHTML: html)
        XCTAssertEqual(resets?.session, OpenUsageISO8601.date(from: "2026-09-19T19:55:00Z"))
        XCTAssertEqual(resets?.weekly, OpenUsageISO8601.date(from: "2026-09-24T11:55:00Z"))
    }

    func testSingleDataTimeYieldsSessionOnly() {
        let html = #"<span data-time="2026-09-19T19:55:00Z">Resets in 3h</span>"#
        let resets = OllamaResetParser.resets(fromHTML: html)
        XCTAssertEqual(resets?.session, OpenUsageISO8601.date(from: "2026-09-19T19:55:00Z"))
        XCTAssertNil(resets?.weekly)
    }

    func testMalformedFirstDataTimeKeepsWeeklyPosition() {
        let html = """
        <span data-time="not-a-date">Resets soon</span>
        <span data-time="2026-09-24T11:55:00Z">Resets in 5d</span>
        """
        let resets = OllamaResetParser.resets(fromHTML: html)
        XCTAssertNil(resets?.session)
        XCTAssertEqual(resets?.weekly, OpenUsageISO8601.date(from: "2026-09-24T11:55:00Z"))
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

    func testTextFallbackParsesSingleWindowWhenWeeklyAnchorMissing() {
        let text = "Session usage 3.2% used Sessions resume in 2 hours"
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let resets = OllamaResetParser.resets(fromText: text, now: now)
        XCTAssertEqual(resets?.session, now.addingTimeInterval(2 * 3600))
        XCTAssertNil(resets?.weekly)
    }

    func testReturnsNilWhenNothingParseable() {
        XCTAssertNil(OllamaResetParser.resets(fromHTML: "<html>no resets here</html>"))
        XCTAssertNil(OllamaResetParser.resets(fromText: "nothing", now: Date()))
    }
}
