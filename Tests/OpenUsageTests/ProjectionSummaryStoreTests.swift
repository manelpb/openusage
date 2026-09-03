import XCTest
@testable import OpenUsage

@MainActor
final class ProjectionSummaryStoreTests: XCTestCase {
    private func makeStore(
        provider: Provider,
        descriptor: WidgetDescriptor,
        lines: [MetricLine]
    ) async -> WidgetDataStore {
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: lines
            )
        )
        let registry = WidgetRegistry(providers: [provider], descriptors: [descriptor])
        let store = WidgetDataStore(registry: registry, providers: [runtime], defaults: makeUserDefaults("projection-summary"))
        await store.refreshAll()
        return store
    }

    func testProjectionSummaryResolvesMostAtRiskMeter() async {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        var descriptor = WidgetDescriptor(
            id: "test.projection",
            providerID: provider.id,
            metricLabel: "Projection",
            sample: WidgetData(title: "Run-out", icon: provider.icon, kind: .percent, used: 0, limit: nil)
        )
        descriptor.isProjectionSummary = true

        let now = Date()
        let week: TimeInterval = 7 * 24 * 60 * 60
        // Two bounded meters: "Session" 30% used (70% left), "Weekly" 80% used (20% left) → Weekly is most at risk.
        let lines: [MetricLine] = [
            .progress(label: "Session", used: 30, limit: 100, format: .percent,
                      resetsAt: now.addingTimeInterval(week), periodDurationMs: Int(week * 1000)),
            .progress(label: "Weekly", used: 80, limit: 100, format: .percent,
                      resetsAt: now.addingTimeInterval(week), periodDurationMs: Int(week * 1000))
        ]
        let store = await makeStore(provider: provider, descriptor: descriptor, lines: lines)

        let data = store.data(for: descriptor)
        XCTAssertTrue(data.isProjection)
        XCTAssertEqual(data.projectionTitle, "Weekly")
        XCTAssertNotNil(data.paceProjection)
    }

    func testProjectionSummaryIsNoDataWithoutBoundedMeters() async {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        var descriptor = WidgetDescriptor(
            id: "test.projection",
            providerID: provider.id,
            metricLabel: "Projection",
            sample: WidgetData(title: "Run-out", icon: provider.icon, kind: .percent, used: 0, limit: nil)
        )
        descriptor.isProjectionSummary = true

        // No qualifying bounded meter (no resetsAt).
        let lines: [MetricLine] = [
            .progress(label: "Session", used: 30, limit: 100, format: .percent)
        ]
        let store = await makeStore(provider: provider, descriptor: descriptor, lines: lines)

        let data = store.data(for: descriptor)
        XCTAssertFalse(data.hasData)
    }

    private func makeUserDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
