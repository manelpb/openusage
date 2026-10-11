import XCTest
@testable import OpenUsage

@MainActor
final class ProviderMarksTests: XCTestCase {
    func testProviderVectorMarksLoadWithoutFallbacks() throws {
        for id in ["claude", "codex", "cursor", "devin", "grok", "litellm"] {
            let mark = try XCTUnwrap(ProviderMarks.mark(for: id), "\(id) should load a vector mark")
            XCTAssertFalse(mark.path.isEmpty, "\(id) mark must carry SVG path data")
            // A corrupt/empty mark (e.g. an `id="…"` attribute captured as path data) parses to
            // zero-area bounds and renders blank — assert real geometry.
            XCTAssertGreaterThan(mark.bounds.width, 0, "\(id) mark must have non-zero width")
            XCTAssertGreaterThan(mark.bounds.height, 0, "\(id) mark must have non-zero height")
        }
    }
}
