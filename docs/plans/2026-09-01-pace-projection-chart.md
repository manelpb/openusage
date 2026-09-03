# Pace Projection Chart — Design & Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

This is the single consolidated plan for the pace projection chart feature. It supersedes the six
incremental plan docs that preceded it (design, hover popover, inline summary, line-graph
improvements, x-axis + click detail, x-axis fix + hover). The code below is the **final** state of the
feature, taken from the actual source files — not the evolving intermediate versions.

**Goal:** Give a bounded meter row (one with a limit + reset window) a hover popover that visualizes
the run-out prediction, and add an always-visible per-provider **Run-out** row that draws the same
chart inline. Both render a burn-down chart of the current reset window with the projection line drawn
to the limit, so the user can see when they'd run out.

**Architecture:** A pure, unit-testable `PaceProjection` geometry type (normalized 0...1 coordinates)
computed from the existing `WidgetData` pace inputs (`used`, `limit`, `resetsAt`, `periodDurationMs`,
`now`). A pure `PaceProjectionSummary` selection picks the most at-risk bounded meter for the inline
row. A pure `PaceProjectionTrajectory` builds the real cumulative-usage line from the provider's
per-day token series. A shared hand-drawn SwiftUI `Canvas` view (`PaceProjectionChart`) renders the
graph, with a dedicated `PaceProjectionXAxis` row for labels. The hover popover (`PaceProjectionDetail`)
is revealed via the existing `HoverPopoverState` + `motionAwareHoverPopover` pattern on the whole row;
the inline row is a normal toggleable metric that opens the larger chart on click. **No new dependency.**

**Tech Stack:** Swift 6, SwiftUI, SwiftPM (`swift build` / `swift test`).

---

## Design

### Goal

Give a bounded meter row (one with a limit + reset window) a hover popover that visualizes the
run-out prediction: a burn-down chart of the current reset window with the projection line drawn to
the limit, so the user can see when they'd run out. Additionally, each provider with bounded meters
gets an always-visible **Run-out** row that draws the same chart inline for its most at-risk meter.

### What already exists

- **Daily usage** — the Usage Trend row (`UsageSparkline` + `UsageTrendDetail`) already charts the
  last 30 days of token usage as bars.
- **Run-out prediction (text)** — the `Pace` engine (`Support/Pace.swift`) already projects usage at
  the current burn rate to the end of the reset window and drives the meter's severity color and the
  "Limit in 3h 5m" / "~35% left at reset" copy. It is text only, not a graph.

The gap is a **graph** that draws that projection.

### Scope

The prediction projects within the **current reset window** using the existing `Pace` math — not the
30-day history. The chart is a burn-down + projection line, revealed as a **hover popover on the whole
bounded row** (mirroring the Usage Trend detail popover), plus an **inline per-provider Run-out row**
that is on by default and toggleable/reorderable like any metric.

### Data & math

No new data collection. Everything comes from fields already on `WidgetData`: `used`, `limit`,
`resetsAt`, `periodDurationMs`, plus `now`. The existing `Pace` engine already computes the burn rate
and run-out time.

Three small pure functions (unit-testable, like `Pace`) turn those inputs into the chart:

- **`PaceProjection`** — the chart geometry in normalized 0...1 coordinates (x = time through the
  reset window, y = share of the limit used): the even-pace line, the current usage point, and the
  projection line to the limit.
- **`PaceProjectionSummary.select`** — picks the provider's most at-risk bounded meter for the inline
  row: prefer the overall weekly quota (titled "Weekly") over per-model weekly windows, then the
  longest reset period, then the most at-risk among those with the same period (smallest remaining
  fraction), tie-broken to the most severe meter state.
- **`PaceProjectionTrajectory.points`** — builds the real cumulative-usage trajectory from the
  provider's per-day token series within the meter's window, scaled so the final point lands at the
  meter's current used fraction. `nil` when there's no per-day data inside the window (e.g. a 5-hour
  session), so the chart falls back to a straight line.

### Chart rendering

Hand-drawn SwiftUI `Path`/`Canvas`, matching the existing `UsageTrendDetail` bar chart. **No new
dependency** (AGENTS.md forbids deps without justification; the app deliberately hand-draws its
charts). A shared `PaceProjectionChart` view draws: the limit line, a dashed even-pace reference, the
real usage trajectory (or a straight-line fallback), the projection line with a gradient fill beneath
it, a marker at the run-out point, the current usage point, and a hover highlight + value label on
trajectory points. A dedicated `PaceProjectionXAxis` row below the graph draws the day-of-week labels
plus "now" and the reset date, so the small labels never clip inside the chart's tight canvas.

### Popover / wiring

Reuse the existing `HoverPopoverState` + `motionAwareHoverPopover` pattern (exactly how
`UsageSparkline` reveals `UsageTrendDetail`). The trigger is the **whole bounded row** (not just the
bar), which currently shows a text `hoverTooltip(state.tooltip)`. The popover replaces that tooltip on
rows with a reset window; the tooltip copy moves into the popover's header. Rows without a window
keep the plain tooltip. The inline Run-out row is a normal metric rendered by `WidgetRowView`; clicking
it opens the larger `PaceProjectionDetail` chart.

### Testing

- Unit tests for the projection geometry (`PaceProjectionTests`), the summary selection
  (`PaceProjectionSummaryTests`), the trajectory computation (`PaceProjectionTrajectoryTests`), the
  hover hit test (`PaceProjectionChartTests`), and the store's projection-summary resolution
  (`ProjectionSummaryStoreTests`).
- The chart only appears for bounded rows with a reset window; rows without one (credit balances,
  no-data) keep the current tooltip.

---

## Implementation Plan

> **Build order note:** the final views compose across phases — `PaceProjectionDetail` (phase 1) uses
> `PaceProjectionChart` (phase 2) and `PaceProjectionXAxis` (phase 4), and `PaceProjectionChart`'s
> final form includes the trajectory/gradient/marker (phase 3) and point hover (phase 5). Each task
> shows the **final** code for its file; `swift build` is only fully green after all phases. Run the
> per-task `swift test --filter` checks as you go and the full suite at the end.

---

## Phase 1 — Hover popover

### Task 1.1: `PaceProjection` geometry (pure, TDD)

**Files:**
- Create: `Sources/OpenUsage/Support/PaceProjection.swift`
- Test: `Tests/OpenUsageTests/PaceProjectionTests.swift`

**Step 1: Write the failing test**

```swift
import XCTest
@testable import OpenUsage

/// Locks the pace projection chart geometry: the even-pace line, the current usage point, and the
/// projection line to the limit, all in normalized 0...1 coordinates. Pins `now` and derives
/// `resetsAt` from a target elapsed fraction so the math is deterministic (same pattern as PaceTests).
final class PaceProjectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let week: TimeInterval = 7 * 24 * 60 * 60

    private func resetsAt(elapsed: Double, period: TimeInterval) -> Date {
        now.addingTimeInterval(period * (1 - elapsed))
    }

    private func projection(used: Double, elapsed: Double, limit: Double = 100) -> PaceProjection {
        PaceProjection(
            used: used, limit: limit,
            resetsAt: resetsAt(elapsed: elapsed, period: week),
            periodDuration: week, now: now
        )
    }

    func testElapsedFractionIsShareOfWindowGone() {
        XCTAssertEqual(projection(used: 0, elapsed: 0.5).elapsedFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(projection(used: 0, elapsed: 0.25).elapsedFraction, 0.25, accuracy: 0.001)
    }

    func testUsedFractionIsShareOfLimitUsed() {
        XCTAssertEqual(projection(used: 50, elapsed: 0.5).usedFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(projection(used: 130, elapsed: 0.5).usedFraction, 1.0, accuracy: 0.001)
    }

    func testEvenPaceLineIsDiagonal() {
        let p = projection(used: 0, elapsed: 0.5)
        XCTAssertEqual(p.evenPaceY(atX: 0), 0, accuracy: 0.001)
        XCTAssertEqual(p.evenPaceY(atX: 0.5), 0.5, accuracy: 0.001)
        XCTAssertEqual(p.evenPaceY(atX: 1), 1, accuracy: 0.001)
    }

    func testRunOutFractionWhenBurningFast() {
        // Half the window gone, 60% used → rate = 120/week → hits 100% at 0.5 + 1/3 ≈ 0.833.
        let p = projection(used: 60, elapsed: 0.5)
        XCTAssertEqual(p.runOutFraction ?? 0, 0.8333, accuracy: 0.01)
        XCTAssertTrue(p.runsOutBeforeReset)
    }

    func testNoRunOutWhenProjectionLandsAfterReset() {
        // Half gone, 30% used → rate = 60/week → would hit 100% at 1.667 > 1.
        let p = projection(used: 30, elapsed: 0.5)
        XCTAssertNil(p.runOutFraction)
        XCTAssertFalse(p.runsOutBeforeReset)
        // Endpoint is the projected usage at reset: 60% used.
        XCTAssertEqual(p.projectionEndpoint.x, 1, accuracy: 0.001)
        XCTAssertEqual(p.projectionEndpoint.y, 0.6, accuracy: 0.001)
    }

    func testRunOutEndpointIsTheLimitCrossing() {
        let p = projection(used: 60, elapsed: 0.5)
        XCTAssertEqual(p.projectionEndpoint.x, 0.8333, accuracy: 0.01)
        XCTAssertEqual(p.projectionEndpoint.y, 1, accuracy: 0.001)
    }

    func testSpentHasNoRunOutCrossing() {
        let p = projection(used: 100, elapsed: 0.5)
        XCTAssertNil(p.runOutFraction)
        XCTAssertFalse(p.runsOutBeforeReset)
    }

    func testCrossingExactlyAtResetIsNotBeforeReset() {
        // Half gone, 50% used → rate = 100/week → hits 100% at exactly the reset (fraction = 1.0).
        let p = projection(used: 50, elapsed: 0.5)
        XCTAssertEqual(p.runOutFraction ?? 0, 1.0, accuracy: 0.001)
        XCTAssertFalse(p.runsOutBeforeReset)
        XCTAssertEqual(p.projectionEndpoint.x, 1, accuracy: 0.001)
        XCTAssertEqual(p.projectionEndpoint.y, 1, accuracy: 0.001)
    }

    func testZeroUsageHasFlatProjection() {
        let p = projection(used: 0, elapsed: 0.5)
        XCTAssertNil(p.runOutFraction)
        XCTAssertEqual(p.projectionEndpoint.x, 1, accuracy: 0.001)
        XCTAssertEqual(p.projectionEndpoint.y, 0, accuracy: 0.001)
    }

    func testWidgetDataPaceProjectionRequiresResetWindow() {
        var data = WidgetData(title: "Credits", icon: .providerMark("codex"), kind: .dollars,
                              used: 12, limit: 20)
        XCTAssertNil(data.paceProjection)                       // no reset window at all
        data.resetsAt = now.addingTimeInterval(week)
        XCTAssertNil(data.paceProjection)                       // reset date but unknown period
        data.periodDurationMs = Int(week * 1000)
        XCTAssertNotNil(data.paceProjection)                    // both present → geometry
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter PaceProjectionTests`
Expected: FAIL — "cannot find 'PaceProjection' in scope"

**Step 3: Write the final implementation**

```swift
import Foundation

/// The geometry for the pace projection chart: the even-pace line, the current usage point, and the
/// projection line to the limit, all in normalized 0...1 coordinates (x = time through the reset
/// window, y = share of the limit used). Pure logic so it's unit-testable like `Pace`.
struct PaceProjection: Hashable, Sendable {
    let used: Double
    let limit: Double
    let resetsAt: Date
    let periodDuration: TimeInterval
    let now: Date

    var windowStart: Date { resetsAt.addingTimeInterval(-periodDuration) }

    var elapsed: TimeInterval { now.timeIntervalSince(windowStart) }

    var elapsedFraction: Double {
        guard periodDuration > 0 else { return 0 }
        return min(max(elapsed / periodDuration, 0), 1)
    }

    var usedFraction: Double {
        guard limit > 0 else { return 0 }
        return min(max(used / limit, 0), 1)
    }

    func evenPaceY(atX x: Double) -> Double { min(max(x, 0), 1) }

    var rate: Double {
        guard elapsed > 0 else { return 0 }
        return used / elapsed
    }

    var runOutFraction: Double? {
        guard rate > 0, used < limit else { return nil }
        let secondsToLimit = (limit - used) / rate
        let t = now.addingTimeInterval(secondsToLimit)
        let fraction = t.timeIntervalSince(windowStart) / periodDuration
        return fraction <= 1 ? fraction : nil
    }

    var runsOutBeforeReset: Bool {
        guard let runOutFraction else { return false }
        return runOutFraction < 1
    }

    var projectionEndpoint: (x: Double, y: Double) {
        if let runOutFraction, runOutFraction < 1 {
            return (runOutFraction, 1)
        }
        let projected = rate * periodDuration
        let y = limit > 0 ? min(max(projected / limit, 0), 1) : 0
        return (1, y)
    }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter PaceProjectionTests`
Expected: PASS (all 10 tests)

**Step 5: Commit**

```bash
git add Sources/OpenUsage/Support/PaceProjection.swift Tests/OpenUsageTests/PaceProjectionTests.swift
git commit -m "feat: add pace projection chart geometry"
```

---

### Task 1.2: `WidgetData.paceProjection` gating (TDD)

**Files:**
- Modify: `Sources/OpenUsage/Models/WidgetData.swift` (append to the `Pace` extension)
- Test: `Tests/OpenUsageTests/PaceProjectionTests.swift` (already covers it — `testWidgetDataPaceProjectionRequiresResetWindow`)

**Step 1: Write the final implementation**

Append to the `extension WidgetData` block that holds `meterState`/`paceTick`:

```swift
    /// The pace projection chart geometry for this row, or `nil` when there's no reset window to
    /// project against (unbounded rows, no-data rows, rows whose reset/period cadence is unknown).
    /// The chart only appears for bounded meters with a known window; everything else keeps the
    /// plain hover tooltip.
    var paceProjection: PaceProjection? {
        guard hasData, let limit, limit > 0, let resetsAt,
              let periodDurationMs, periodDurationMs > 0 else { return nil }
        return PaceProjection(
            used: used, limit: limit, resetsAt: resetsAt,
            periodDuration: TimeInterval(periodDurationMs) / 1000, now: Date()
        )
    }
```

**Step 2: Run test to verify it passes**

Run: `swift test --filter PaceProjectionTests`
Expected: PASS (all 10 tests)

**Step 3: Commit**

```bash
git add Sources/OpenUsage/Models/WidgetData.swift
git commit -m "feat: expose pace projection geometry on WidgetData"
```

---

### Task 1.3: `PaceProjectionDetail` view

**Files:**
- Create: `Sources/OpenUsage/Views/PaceProjectionDetail.swift`

**Step 1: Write the final view**

> This is the final `PaceProjectionDetail`. It composes `PaceProjectionChart` (created in phase 2) and
> `PaceProjectionXAxis` (created in phase 4), so it won't compile until those exist — the full build is
> verified at the end of the plan.

```swift
import SwiftUI

/// The detail-on-demand popover for a bounded meter row: a burn-down chart of the current reset
/// window with the run-out projection drawn as a line to the limit. Shows the even-pace reference
/// line (dashed), the current usage point, and the projection line to where it crosses the limit —
/// or to the projected usage at reset when it won't run out before then. The projection line carries
/// the meter's verdict color so the chart and the bar never disagree.
struct PaceProjectionDetail: View {
    let title: String
    let projection: PaceProjection
    let readout: String?
    let severity: WidgetData.MeterSeverity?
    var trajectory: [TrajectoryPoint]? = nil
    var onHoverChange: (Bool) -> Void = { _ in }

    private static let chartHeight: CGFloat = 76
    private static let width: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            chart
            PaceProjectionXAxis(projection: projection, trajectory: trajectory)
        }
        .padding(12)
        .frame(width: Self.width)
        .onContinuousHover { phase in
            switch phase {
            case .active: onHoverChange(true)
            case .ended: onHoverChange(false)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            if let readout {
                Text(readout)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var chart: some View {
        PaceProjectionChart(projection: projection, severity: severity, trajectory: trajectory)
            .frame(height: Self.chartHeight)
    }

}
```

**Step 2: Build to verify it compiles**

Run: `swift build`
Expected: PASS (after phase 2's `PaceProjectionChart` and phase 4's `PaceProjectionXAxis` exist).

**Step 3: Commit**

```bash
git add Sources/OpenUsage/Views/PaceProjectionDetail.swift
git commit -m "feat: add pace projection chart detail view"
```

---

### Task 1.4: Wire the row-level hover popover into `WidgetRowView`

**Files:**
- Modify: `Sources/OpenUsage/Views/WidgetRowView.swift`

**Step 1: Add a hover coordinator**

Next to the existing `@State private var modelHover = HoverPopoverState()`:

```swift
    /// Drives the pace projection popover on the meter bar (bounded rows with a reset window).
    @State private var paceHover = HoverPopoverState()
```

**Step 2: Attach the popover to the whole bounded row**

The final `boundedRow` attaches the popover to the whole row (not the bar), and dismisses it on
teardown:

```swift
    private var boundedRow: some View {
        let state = data.meterState()
        let row = VStack(alignment: .leading, spacing: density.rowInnerSpacing) {
            boundedLabelRow(state)
            meter(state)
            primaryTextRow
        }
        .onDisappear { paceHover.dismiss() }

        if let projection = data.paceProjection, state.tooltip != nil {
            return AnyView(row
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active = phase { paceHover.inlineHover(true) } else { paceHover.inlineHover(false) }
                }
                .motionAwareHoverPopover(
                    isPresented: Binding(get: { paceHover.isPresented }, set: { if !$0 { paceHover.dismiss() } }),
                    reduceAnimations: reduceAnimations
                ) {
                    PaceProjectionDetail(
                        title: data.title,
                        projection: projection,
                        readout: state.tooltip,
                        severity: state.severity
                    ) { inside in
                        paceHover.detailHover(inside)
                    }
                })
        }
        return AnyView(row)
    }
```

**Step 3: The bar keeps the tooltip only when there's no projection**

The final `meter(_:)` no longer attaches the popover (it moved to the row). It shows the tooltip only
for rows without a reset window:

```swift
    private func meter(_ state: WidgetData.MeterState) -> some View {
        let tick = data.paceTick(for: state)
        let bar = GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(partyMode ? PartyMode.meterFill : severityColor(state.severity))
                    .frame(width: fillWidth(track: proxy.size.width))
            }
            .overlay(alignment: .leading) {
                if let tick {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: Self.paceTickWidth, height: density.meterHeight + Self.paceTickOverhang)
                        .offset(x: paceTickOffset(track: proxy.size.width, fraction: tick))
                }
            }
        }
        .frame(height: density.meterHeight)
        .animation(Motion.spring, value: data.fraction)
        .accessibilityHidden(true)
        // The row-level hover popover (when a projection exists) replaces the tooltip; rows without a
        // window keep the tooltip.
        if data.paceProjection == nil {
            return AnyView(bar.hoverTooltip(state.tooltip))
        }
        return AnyView(bar)
    }
```

**Step 4: Build to verify it compiles**

Run: `swift build`
Expected: PASS (after phase 2's `PaceProjectionChart` exists).

**Step 5: Commit**

```bash
git add Sources/OpenUsage/Views/WidgetRowView.swift
git commit -m "feat: reveal pace projection chart on bounded row hover"
```

---

## Phase 2 — Inline summary

### Task 2.1: `BoundedMeter` + `PaceProjectionSummary.select` (pure, TDD)

**Files:**
- Create: `Sources/OpenUsage/Support/PaceProjectionSummary.swift`
- Test: `Tests/OpenUsageTests/PaceProjectionSummaryTests.swift`

**Step 1: Write the failing test**

```swift
import XCTest
@testable import OpenUsage

/// Locks the per-provider summary selection: among a provider's bounded meters with a valid reset
/// window, prefer the overall weekly quota (titled "Weekly") over per-model weekly windows (e.g.
/// Fable) that share the same 7-day period, then the one with the longest reset period (the
/// weekly/monthly monitoring horizon), then the most at-risk among those with the same period
/// (smallest remaining fraction; tie-break to the most severe meter state). Pins `now` and derives
/// `resetsAt` from an elapsed fraction (same pattern as PaceTests).
final class PaceProjectionSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let week: TimeInterval = 7 * 24 * 60 * 60

    private func resetsAt(elapsed: Double, period: TimeInterval) -> Date {
        now.addingTimeInterval(period * (1 - elapsed))
    }

    private func meter(_ title: String, used: Double, limit: Double = 100,
                       elapsed: Double = 0.5, period: TimeInterval? = nil) -> BoundedMeter {
        let period = period ?? week
        return BoundedMeter(
            title: title, used: used, limit: limit,
            resetsAt: resetsAt(elapsed: elapsed, period: period),
            periodDurationMs: Int(period * 1000)
        )
    }

    func testPicksSmallestRemainingFraction() {
        // 30% used → 70% left; 60% used → 40% left; 80% used → 20% left. Picks the 80% one.
        let meters = [meter("A", used: 30), meter("B", used: 60), meter("C", used: 80)]
        XCTAssertEqual(PaceProjectionSummary.select(from: meters, now: now)?.title, "C")
    }

    func testPrefersWeeklyMeterOverMoreAtRiskPerModelWindow() {
        // "Weekly" (30% used) and "Fable" (80% used) share the same 7-day period, so the old
        // longest-period-then-most-at-risk logic would pick Fable. The overall weekly quota wins.
        let meters = [
            meter("Fable", used: 80),
            meter("Weekly", used: 30),
        ]
        XCTAssertEqual(PaceProjectionSummary.select(from: meters, now: now)?.title, "Weekly")
    }

    func testPrefersLongestPeriod() {
        // A 5-hour session meter is more at-risk (80% used) than the weekly meter (30% used), but
        // the weekly monitoring horizon wins.
        let meters = [
            meter("Session", used: 80, period: 5 * 3600),
            meter("Weekly", used: 30),
        ]
        XCTAssertEqual(PaceProjectionSummary.select(from: meters, now: now)?.title, "Weekly")
    }

    func testPicksMostAtRiskAmongSamePeriod() {
        // Same weekly period; 80% used is more at-risk than 30% used.
        let meters = [meter("A", used: 30), meter("B", used: 80)]
        XCTAssertEqual(PaceProjectionSummary.select(from: meters, now: now)?.title, "B")
    }

    func testTieBreakByMostSevereState() {
        // Equal remaining fraction (50% left) but different elapsed, so the tie-break decides.
        // A: 50 used / 0.5 elapsed → projected 100 = limit → onTrack (rank 1).
        // B: 50 used / 0.1 elapsed → projected 500 > limit → runningOut (rank 2).
        let meters = [
            meter("A", used: 50, elapsed: 0.5),
            meter("B", used: 50, elapsed: 0.1),
        ]
        XCTAssertEqual(PaceProjectionSummary.select(from: meters, now: now)?.title, "B")
    }

    func testIgnoresMetersWithoutAResetWindow() {
        var noWindow = meter("A", used: 50)
        noWindow.resetsAt = nil
        let meters = [noWindow, meter("B", used: 80)]
        XCTAssertEqual(PaceProjectionSummary.select(from: meters, now: now)?.title, "B")
    }

    func testIgnoresMetersWithoutAPeriod() {
        var noPeriod = meter("A", used: 50)
        noPeriod.periodDurationMs = nil
        let meters = [noPeriod, meter("B", used: 80)]
        XCTAssertEqual(PaceProjectionSummary.select(from: meters, now: now)?.title, "B")
    }

    func testNilWhenNoQualifyingMeters() {
        XCTAssertNil(PaceProjectionSummary.select(from: [], now: now))
        var noWindow = meter("A", used: 50)
        noWindow.resetsAt = nil
        XCTAssertNil(PaceProjectionSummary.select(from: [noWindow], now: now))
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter PaceProjectionSummaryTests`
Expected: FAIL — "cannot find 'BoundedMeter' in scope"

**Step 3: Write the final implementation**

```swift
import Foundation

/// One bounded meter's projection inputs, extracted from a provider's `.progress` line. The summary
/// row scans a provider's meters and picks the most at-risk one to draw.
struct BoundedMeter: Hashable, Sendable {
    var title: String
    var used: Double
    var limit: Double
    var resetsAt: Date?
    var periodDurationMs: Int?
}

/// Picks the provider's bounded meter for the inline run-out summary graph: prefer the overall weekly
/// quota (titled "Weekly") over per-model weekly windows (e.g. Fable) that share the same 7-day period,
/// then the longest reset period (the weekly/monthly monitoring horizon over short session windows and
/// per-model quotas), then the most at-risk among those with the same period (smallest remaining
/// fraction), tie-broken to the most severe meter state (running-out > cutting-it-close > healthy).
/// Only meters with a valid reset window qualify; `nil` when none do. Pure logic so it's
/// unit-testable like `Pace`.
enum PaceProjectionSummary {
    static func select(from meters: [BoundedMeter], now: Date = Date()) -> BoundedMeter? {
        let valid = meters.filter { $0.limit > 0 && $0.resetsAt != nil && ($0.periodDurationMs ?? 0) > 0 }
        // Prefer the overall weekly quota (titled "Weekly") over per-model weekly windows (e.g. Fable),
        // which share the same 7-day period and would otherwise win by being more at-risk.
        if let weekly = valid.first(where: { $0.title == "Weekly" }) {
            return weekly
        }
        return valid.max { lhs, rhs in
                let lhsPeriod = TimeInterval(lhs.periodDurationMs ?? 0)
                let rhsPeriod = TimeInterval(rhs.periodDurationMs ?? 0)
                // Prefer the longer reset period (the weekly/monthly monitoring horizon) over short
                // session windows and per-model quotas.
                if lhsPeriod != rhsPeriod { return lhsPeriod < rhsPeriod }
                let lhsRemaining = (lhs.limit - lhs.used) / lhs.limit
                let rhsRemaining = (rhs.limit - rhs.used) / rhs.limit
                if lhsRemaining != rhsRemaining { return lhsRemaining > rhsRemaining }
                return severityRank(lhs, now: now) < severityRank(rhs, now: now)
            }
    }

    /// 0 = healthy, 1 = closeToLimit, 2 = runningOut/spent — higher is more at risk.
    private static func severityRank(_ meter: BoundedMeter, now: Date) -> Int {
        guard let resetsAt = meter.resetsAt, let periodDurationMs = meter.periodDurationMs,
              periodDurationMs > 0, meter.limit > 0 else { return 0 }
        let period = TimeInterval(periodDurationMs) / 1000
        let elapsed = now.timeIntervalSince(resetsAt.addingTimeInterval(-period))
        guard elapsed > 0 else { return 0 }
        let projected = meter.used / elapsed * period
        if meter.used >= meter.limit { return 2 }
        if projected > meter.limit { return 2 }
        if projected > meter.limit * 0.9 { return 1 }
        return 0
    }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter PaceProjectionSummaryTests`
Expected: PASS (all 8 tests)

**Step 5: Commit**

```bash
git add Sources/OpenUsage/Support/PaceProjectionSummary.swift Tests/OpenUsageTests/PaceProjectionSummaryTests.swift
git commit -m "feat: add most-at-risk bounded meter selection"
```

---

### Task 2.2: `WidgetDescriptor.isProjectionSummary` + factory

**Files:**
- Modify: `Sources/OpenUsage/Models/WidgetDescriptor.swift`
- Modify: `Sources/OpenUsage/Models/WidgetDescriptor+Factories.swift`

**Step 1: Add the flag**

In `Sources/OpenUsage/Models/WidgetDescriptor.swift`, add a stored property near the other descriptor
flags:

```swift
    /// True for the per-provider run-out summary row, which is derived from the provider's other bounded
    /// meters rather than a provider-emitted line. `WidgetDataStore` will special-case it to build the row's data.
    var isProjectionSummary: Bool = false
```

**Step 2: Add the factory**

In `Sources/OpenUsage/Models/WidgetDescriptor+Factories.swift`:

```swift
    /// The per-provider run-out summary row: an inline line graph of the most at-risk bounded meter's
    /// projection. Derived (not provider-emitted), so `WidgetDataStore` builds its data from the
    /// provider's other bounded meters. On by default; toggleable/reorderable like any metric. Not
    /// pinnable — the tray can't draw a chart.
    static func projectionSummary(provider: Provider) -> WidgetDescriptor {
        var sample = WidgetData(title: "Run-out", icon: provider.icon, kind: .percent, used: 0, limit: nil)
        sample.isProjection = true
        var descriptor = make(id: "\(provider.id).projection", provider: provider,
                              metricLabel: "Projection", sample: sample, pinnable: false)
        descriptor.isProjectionSummary = true
        return descriptor
    }
```

**Step 3: Build to verify it compiles**

Run: `swift build`
Expected: PASS.

**Step 4: Commit**

```bash
git add Sources/OpenUsage/Models/WidgetDescriptor.swift Sources/OpenUsage/Models/WidgetDescriptor+Factories.swift
git commit -m "feat: add projection summary widget descriptor"
```

---

### Task 2.3: `WidgetData` projection fields

**Files:**
- Modify: `Sources/OpenUsage/Models/WidgetData.swift`

**Step 1: Add fields**

In `WidgetData`, near the chart fields (`isChart`/`chartPoints`/`chartNote`):

```swift
    /// True for the per-provider run-out summary row. The row draws an inline line graph of the most
    /// at-risk bounded meter's projection instead of the value layout; `WidgetDataStore` will populate it.
    var isProjection: Bool = false
    /// The most at-risk bounded meter's name, shown in the run-out summary row's header. The row
    /// recomputes the projection and verdict at render time from the stored `used`/`limit`/`resetsAt`/
    /// `periodDurationMs` (via `paceProjection` and `meterState`), so it stays live on the row's 30s
    /// tick rather than freezing between refreshes. `WidgetDataStore` will populate this.
    var projectionTitle: String?
    /// The real cumulative-usage trajectory for the run-out summary row, in normalized 0...1 points
    /// (x = time through the window, y = share of the limit). `nil` when the provider has no per-day
    /// data inside the window, so the chart falls back to a straight line.
    var trajectoryPoints: [TrajectoryPoint]? = nil
```

**Step 2: Build to verify it compiles**

Run: `swift build`
Expected: PASS.

**Step 3: Commit**

```bash
git add Sources/OpenUsage/Models/WidgetData.swift
git commit -m "feat: add projection fields to WidgetData"
```

---

### Task 2.4: `WidgetDataStore.projectionSummaryData` (TDD)

**Files:**
- Modify: `Sources/OpenUsage/Stores/WidgetDataStore.swift`
- Test: `Tests/OpenUsageTests/ProjectionSummaryStoreTests.swift`

**Step 1: Write the failing test**

```swift
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
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter ProjectionSummaryStoreTests`
Expected: FAIL — the projection-summary descriptor resolves to no-data (the special-case isn't implemented yet).

**Step 3: Write the final implementation**

In `WidgetDataStore.data(for:)`, special-case the projection-summary descriptor before the line lookup:

```swift
    func data(for descriptor: WidgetDescriptor) -> WidgetData {
        var result: WidgetData
        if descriptor.isProjectionSummary {
            result = projectionSummaryData(for: descriptor) ?? {
                var noData = descriptor.sample
                noData.hasData = false
                return noData
            }()
        } else if let snapshot = snapshots[descriptor.providerID],
                  let line = snapshot.line(label: descriptor.metricLabel),
                  let data = resolve(line, descriptor: descriptor) {
            // ... existing body ...
        } else {
            result = descriptor.sample
            result.hasData = false
        }
        // ... existing mode stamping ...
        return result
    }
```

Add the helper (near `resolve`):

```swift
    /// Builds the per-provider run-out summary row: scans the provider's `.progress` lines for bounded
    /// meters with a reset window, picks the most at-risk one, and returns a projection `WidgetData`.
    /// `nil` when the provider has no qualifying meter (the row then renders "No data").
    private func projectionSummaryData(for descriptor: WidgetDescriptor) -> WidgetData? {
        guard let snapshot = snapshots[descriptor.providerID] else { return nil }
        let now = now()
        let meters = snapshot.lines.compactMap { line -> BoundedMeter? in
            guard case .progress(let label, let used, let limit, _, let resetsAt, let periodDurationMs, _) = line else { return nil }
            return BoundedMeter(title: label, used: used, limit: limit,
                                resetsAt: resetsAt, periodDurationMs: periodDurationMs)
        }
        guard let selected = PaceProjectionSummary.select(from: meters, now: now) else { return nil }
        var data = WidgetData(
            title: selected.title, icon: descriptor.sample.icon, kind: .percent,
            used: selected.used, limit: selected.limit
        )
        data.resetsAt = selected.resetsAt
        data.periodDurationMs = selected.periodDurationMs
        data.isProjection = true
        data.projectionTitle = selected.title
        data.trajectoryPoints = PaceProjectionTrajectory.points(
            used: selected.used, limit: selected.limit,
            resetsAt: selected.resetsAt ?? now, periodDuration: TimeInterval(selected.periodDurationMs ?? 0) / 1000,
            now: now,
            daily: snapshot.usageHistory?.series.daily ?? []
        )
        return data
    }
```

> The `trajectoryPoints` line references `PaceProjectionTrajectory`, created in phase 3. Until then,
> omit that line (or stub it) so the store compiles; the full build is verified at the end.

**Step 4: Run test to verify it passes**

Run: `swift test --filter ProjectionSummaryStoreTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add Sources/OpenUsage/Stores/WidgetDataStore.swift Tests/OpenUsageTests/ProjectionSummaryStoreTests.swift
git commit -m "feat: resolve projection summary row from provider bounded meters"
```

---

### Task 2.5: Shared `PaceProjectionChart` + `PaceProjectionInlineRow`

**Files:**
- Create: `Sources/OpenUsage/Views/PaceProjectionChart.swift`
- Create: `Sources/OpenUsage/Views/PaceProjectionInlineRow.swift`
- Modify: `Sources/OpenUsage/Views/WidgetRowView.swift`

**Step 1: Create the shared chart view**

> This is the **final** `PaceProjectionChart`, including the trajectory/gradient/marker (phase 3) and
> the point hover (phase 5). It is shown here in full so the file is written once; the later phases
> reference the specific blocks.

```swift
import SwiftUI

/// The shared line-graph drawing for the pace projection: limit line, dashed even-pace reference, the
/// real usage trajectory (or a straight-line fallback), the projection line with a gradient fill
/// beneath it, and a marker at the run-out point. Used by the hover popover (`PaceProjectionDetail`)
/// and the inline per-provider summary row. The `severity ?? .normal` fallback (blue) is the
/// deliberate default for a row with no verdict.
struct PaceProjectionChart: View {
    let projection: PaceProjection
    let severity: WidgetData.MeterSeverity?
    var trajectory: [TrajectoryPoint]? = nil

    @State private var hoveredIndex: Int?

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let color = Theme.meterColor(severity ?? .normal)
                let limitY = point(x: 0, y: 1, in: size).y

            // Limit line at the top.
            var limitPath = Path()
            limitPath.move(to: CGPoint(x: 0, y: limitY))
            limitPath.addLine(to: CGPoint(x: size.width, y: limitY))
            context.stroke(limitPath, with: .color(.secondary.opacity(0.4)), lineWidth: 1)

            // Even-pace reference line: (0,0) → (1,1).
            var pacePath = Path()
            pacePath.move(to: point(x: 0, y: 0, in: size))
            pacePath.addLine(to: point(x: 1, y: 1, in: size))
            context.stroke(pacePath, with: .color(.secondary.opacity(0.5)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            // Real usage trajectory (or a straight line from start to the current point).
            let current = point(x: projection.elapsedFraction, y: projection.usedFraction, in: size)
            var trajectoryPath = Path()
            if let trajectory, !trajectory.isEmpty {
                trajectoryPath.move(to: point(x: trajectory[0].x, y: trajectory[0].y, in: size))
                for p in trajectory.dropFirst() {
                    trajectoryPath.addLine(to: point(x: p.x, y: p.y, in: size))
                }
                trajectoryPath.addLine(to: current)
            } else {
                trajectoryPath.move(to: point(x: 0, y: 0, in: size))
                trajectoryPath.addLine(to: current)
            }
            // Projection line: current point → endpoint.
            let end = projection.projectionEndpoint
            let endPoint = point(x: end.x, y: end.y, in: size)
            var projectionPath = Path()
            projectionPath.move(to: current)
            projectionPath.addLine(to: endPoint)

            // Gradient fill under the projection line.
            var fillPath = projectionPath
            fillPath.addLine(to: CGPoint(x: endPoint.x, y: size.height))
            fillPath.addLine(to: CGPoint(x: current.x, y: size.height))
            fillPath.closeSubpath()
            context.fill(fillPath, with: .linearGradient(
                Gradient(colors: [color.opacity(0.25), color.opacity(0.0)]),
                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)
            ))

            // Real usage trajectory (or a straight line from start to the current point).
            context.stroke(trajectoryPath, with: .color(color.opacity(0.6)), lineWidth: 1.5)

            // Visible dots at each trajectory point so they read as hover targets.
            if let trajectory {
                for p in trajectory {
                    let dp = point(x: p.x, y: p.y, in: size)
                    context.fill(Path(ellipseIn: CGRect(x: dp.x - 3, y: dp.y - 3, width: 6, height: 6)),
                                 with: .color(color.opacity(0.5)))
                }
            }

            context.stroke(projectionPath, with: .color(color), lineWidth: 2)

            // Current usage point.
            let dot = CGRect(x: current.x - 3, y: current.y - 3, width: 6, height: 6)
            context.fill(Path(ellipseIn: dot), with: .color(color))

            // Run-out marker at the projection endpoint, inset so it stays fully on-canvas.
            let markerX = min(max(endPoint.x, 3), size.width - 3)
            let markerY = min(max(endPoint.y, 3), size.height - 3)
            let runOutDot = CGRect(x: markerX - 3, y: markerY - 3, width: 6, height: 6)
            context.fill(Path(ellipseIn: runOutDot), with: .color(color))

                // Hovered trajectory point: highlight + value label.
                if let hoveredIndex, trajectory?.indices.contains(hoveredIndex) == true, let p = trajectory?[hoveredIndex] {
                    let hp = point(x: p.x, y: p.y, in: size)
                    context.fill(Path(ellipseIn: CGRect(x: hp.x - 4, y: hp.y - 4, width: 8, height: 8)),
                                 with: .color(color))
                    // The % is the meter-normalized used fraction (p.y lands at used/limit), while the token
                    // count is the raw daily-series cumulative — the two are on different scales and don't
                    // necessarily imply each other (intentional).
                    let value = "\(Int((p.y * 100).rounded()))% · \(MetricFormatter.number(Double(p.cumulativeTokens ?? 0), kind: .count, style: .row)) tokens"
                    let label = Text(value).font(.system(size: 8)).monospacedDigit()
                    let halfWidth = context.resolve(label).measure(in: size).width / 2
                    let textX = min(max(hp.x, halfWidth), max(halfWidth, size.width - halfWidth))
                    let textY = max(hp.y - 12, 10)
                    context.draw(label.foregroundStyle(.secondary), at: CGPoint(x: textX, y: textY))
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoveredIndex = nearestTrajectoryPointIndex(to: location, size: geo.size, trajectory: trajectory)
                case .ended:
                    hoveredIndex = nil
                }
            }
        }
    }

    private func point(x: Double, y: Double, in size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: (1 - y) * size.height)
    }
}

/// The index of the trajectory point nearest the cursor by x within a ~`reach` x reach, or `nil` when
/// none is close enough. The hit test is x-dominant: hovering a day's x-region highlights that day's
/// point regardless of y. `size` is the chart canvas size; the point and cursor are compared in view
/// points.
func nearestTrajectoryPointIndex(to location: CGPoint, size: CGSize,
                                 trajectory: [TrajectoryPoint]?, reach: CGFloat = 24) -> Int? {
    guard let trajectory, !trajectory.isEmpty else { return nil }
    var best: (index: Int, distance: CGFloat)? = nil
    for (i, p) in trajectory.enumerated() {
        let px = CGFloat(p.x) * size.width
        let dx = abs(px - location.x)
        guard dx <= reach else { continue }
        if best == nil || dx < best!.distance {
            best = (i, dx)
        }
    }
    return best?.index
}
```

> The `trajectory` parameter and the trajectory/gradient/marker drawing are phase 3; the hover block and
> `nearestTrajectoryPointIndex` are phase 5. For a phase-2-only build, you can start with the limit
> line, even-pace line, projection line, and current dot, then add the rest in later phases.

**Step 2: Create the inline row**

> This is the **final** `PaceProjectionInlineRow`, including the trajectory (phase 3), the x-axis row
> (phase 4), and the click-to-open detail (phase 4).

```swift
import SwiftUI

/// The per-provider run-out summary row: a compact, full-width line graph of the most at-risk bounded
/// meter's projection, with the meter name and run-out readout in a header. Always visible on the card
/// (on by default; toggleable/reorderable like any metric).
struct PaceProjectionInlineRow: View {
    let data: WidgetData

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @Environment(\.reduceAnimations) private var reduceAnimations
    @State private var showDetail = false

    var body: some View {
        let projection = data.paceProjection
        let state = data.meterState()
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(data.projectionTitle ?? data.title)
                    .font(.system(size: density.supportingPointSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let readout = state.tooltip {
                    Text(readout)
                        .font(.system(size: density.supportingPointSize))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let projection {
                VStack(alignment: .leading, spacing: 2) {
                    PaceProjectionChart(projection: projection, severity: state.severity, trajectory: data.trajectoryPoints)
                        .frame(height: density.projectionChartHeight)
                    PaceProjectionXAxis(projection: projection, trajectory: data.trajectoryPoints)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if projection != nil { showDetail = true } }
        .motionAwareHoverPopover(isPresented: $showDetail, reduceAnimations: reduceAnimations) {
            if let projection {
                PaceProjectionDetail(
                    title: data.projectionTitle ?? data.title,
                    projection: projection,
                    readout: state.tooltip,
                    severity: state.severity,
                    trajectory: data.trajectoryPoints
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { showDetail = true }
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let title = data.projectionTitle ?? data.title
        return "\(title) run-out projection\(data.meterState().tooltip.map { ", \($0)" } ?? ""), tap for details"
    }
}
```

> The `PaceProjectionXAxis` reference is phase 4; the click-to-open popover is phase 4. For a
> phase-2-only build, drop the x-axis row and the tap/popover wiring.

**Step 3: Wire into `WidgetRowView`**

In `WidgetRowView.rowContent`, add a projection branch before the chart branch:

```swift
    @ViewBuilder
    private var rowContent: some View {
        if data.isProjection, data.hasData {
            PaceProjectionInlineRow(data: data)
        } else if data.isChart, data.hasData {
            // The sparkline owns its own label + bars; a chart with no real points falls through to the
            // unbounded "No data" row below (and so descriptor template data never leaks here).
            UsageSparkline(data: data)
        } else if data.isBounded {
            boundedRow
        } else {
            unboundedRow
        }
    }
```

**Step 4: Build to verify it compiles**

Run: `swift build`
Expected: PASS (after phase 4's `PaceProjectionXAxis` exists; otherwise build the phase-2 subset).

**Step 5: Commit**

```bash
git add Sources/OpenUsage/Views/PaceProjectionChart.swift Sources/OpenUsage/Views/PaceProjectionInlineRow.swift Sources/OpenUsage/Views/WidgetRowView.swift
git commit -m "feat: render inline run-out summary line graph"
```

---

### Task 2.6: Per-provider descriptors + default layout

**Files:**
- Modify: `Sources/OpenUsage/Providers/Claude/ClaudeProvider.swift`
- Modify: `Sources/OpenUsage/Providers/Codex/CodexProvider.swift`
- Modify: `Sources/OpenUsage/Providers/Cursor/CursorProvider.swift`
- Modify: `Sources/OpenUsage/Providers/Antigravity/AntigravityProvider.swift`
- Modify: `Sources/OpenUsage/Providers/OpenCode/OpenCodeProvider.swift`
- Modify: `Sources/OpenUsage/Stores/DefaultLayout.swift`

**Step 1: Add the descriptor to each provider**

In each provider's `widgetDescriptors` array, add `.projectionSummary(provider: provider)` right after
the Usage Trend descriptor, before the spend tiles:

```swift
            .usageTrend(provider: provider)
                .exportingHistory(...),
            .projectionSummary(provider: provider)
        ] + WidgetDescriptor.spendTiles(provider: provider)
```

**Step 2: Add the IDs to the default layout**

In `DefaultLayout.metricIDs`, add `"<provider>.projection"` for each of the five providers (Claude,
Codex, Cursor, Antigravity, OpenCode), placed right after that provider's `trend` ID so the summary
row sits near the trend:

```swift
        "antigravity.trend", "antigravity.projection", "antigravity.today", ...
        "claude.trend", "claude.projection", "claude.extra", ...
        "codex.trend", "codex.projection", "codex.credits", ...
        "cursor.trend", "cursor.projection", "cursor.onDemand", ...
        "opencode.trend", "opencode.projection", "opencode.today", ...
```

Do NOT add to `migrationBaselineMetricIDs` (that's a frozen snapshot of a past release). Do NOT add to
`pinnedMetricIDs` (a chart can't be pinned). Do NOT add to `expandedMetricIDs` (it's on by default,
always visible).

**Step 3: Build to verify it compiles**

Run: `swift build`
Expected: PASS.

**Step 4: Commit**

```bash
git add Sources/OpenUsage/Providers/Claude/ClaudeProvider.swift Sources/OpenUsage/Providers/Codex/CodexProvider.swift Sources/OpenUsage/Providers/Cursor/CursorProvider.swift Sources/OpenUsage/Providers/Antigravity/AntigravityProvider.swift Sources/OpenUsage/Providers/OpenCode/OpenCodeProvider.swift Sources/OpenUsage/Stores/DefaultLayout.swift
git commit -m "feat: enable run-out summary row for bounded-meter providers"
```

---

## Phase 3 — Line graph improvements

### Task 3.1: `TrajectoryPoint` + `PaceProjectionTrajectory.points` (pure, TDD)

**Files:**
- Create: `Sources/OpenUsage/Support/PaceProjectionTrajectory.swift`
- Test: `Tests/OpenUsageTests/PaceProjectionTrajectoryTests.swift`

**Step 1: Write the failing test**

```swift
import XCTest
@testable import OpenUsage

/// Locks the trajectory computation: normalized cumulative-usage points (x = time through the window,
/// y = share of the limit) built from the provider's per-day token series within the window, scaled so
/// the final point lands at the meter's current used fraction. Pins `now` and derives `resetsAt` from
/// an elapsed fraction (same pattern as PaceTests).
final class PaceProjectionTrajectoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let week: TimeInterval = 7 * 24 * 60 * 60
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }

    private func resetsAt(elapsed: Double, period: TimeInterval) -> Date {
        now.addingTimeInterval(period * (1 - elapsed))
    }

    private func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        return f.string(from: date)
    }

    private func entry(_ date: Date, tokens: Int) -> DailyUsageEntry {
        DailyUsageEntry(date: dayKey(date), totalTokens: tokens, costUSD: nil)
    }

    func testBuildsCumulativePointsScaledToUsedFraction() {
        // windowStart at a known midnight; now = windowStart + 3.5 days (half a week gone).
        let windowStart = calendar.date(from: DateComponents(year: 2023, month: 11, day: 13))!
        let now = windowStart.addingTimeInterval(0.5 * week)
        let resetsAt = windowStart.addingTimeInterval(week)
        let daily = [
            entry(windowStart.addingTimeInterval(1 * 24 * 3600), tokens: 100),
            entry(windowStart.addingTimeInterval(2 * 24 * 3600), tokens: 200),
            entry(windowStart.addingTimeInterval(3 * 24 * 3600), tokens: 300)
        ]
        let points = PaceProjectionTrajectory.points(
            used: 50, limit: 100, resetsAt: resetsAt, periodDuration: week, now: now,
            daily: daily, calendar: calendar
        )
        XCTAssertEqual(points?.count, 3)
        // Total 600 tokens → scale = 0.5/600. Cumulative 100 → 0.0833, 300 → 0.25, 600 → 0.5.
        XCTAssertEqual(points?[0].y ?? 0, 0.0833, accuracy: 0.001)
        XCTAssertEqual(points?[1].y ?? 0, 0.25, accuracy: 0.001)
        XCTAssertEqual(points?[2].y ?? 0, 0.5, accuracy: 0.001)
        // windowStart is midnight, so each day's x = N/7.
        XCTAssertEqual(points?[0].x ?? 0, 1.0 / 7.0, accuracy: 0.001)
        XCTAssertEqual(points?[2].x ?? 0, 3.0 / 7.0, accuracy: 0.001)
    }

    func testNilWhenNoDailyDataInWindow() {
        let reset = resetsAt(elapsed: 0.5, period: week)
        let windowStart = reset.addingTimeInterval(-week)
        // A 5-hour session window has no daily entries inside it.
        let session: TimeInterval = 5 * 3600
        let sessionReset = now.addingTimeInterval(session * 0.5)
        let daily = [entry(windowStart, tokens: 100)] // outside the session window
        XCTAssertNil(PaceProjectionTrajectory.points(
            used: 10, limit: 100, resetsAt: sessionReset, periodDuration: session, now: now,
            daily: daily, calendar: calendar
        ))
    }

    func testNilWhenNoTokens() {
        let reset = resetsAt(elapsed: 0.5, period: week)
        let windowStart = reset.addingTimeInterval(-week)
        let daily = [entry(windowStart.addingTimeInterval(3600), tokens: 0)]
        XCTAssertNil(PaceProjectionTrajectory.points(
            used: 10, limit: 100, resetsAt: reset, periodDuration: week, now: now,
            daily: daily, calendar: calendar
        ))
    }

    func testPointsCarryDayOfWeekLabels() {
        let windowStart = calendar.date(from: DateComponents(year: 2023, month: 11, day: 13))! // a Monday
        let now = windowStart.addingTimeInterval(0.5 * week)
        let resetsAt = windowStart.addingTimeInterval(week)
        let daily = [
            entry(windowStart.addingTimeInterval(1 * 24 * 3600), tokens: 100), // Tuesday
            entry(windowStart.addingTimeInterval(2 * 24 * 3600), tokens: 200)  // Wednesday
        ]
        let points = PaceProjectionTrajectory.points(
            used: 50, limit: 100, resetsAt: resetsAt, periodDuration: week, now: now,
            daily: daily, calendar: calendar
        )
        XCTAssertEqual(points?[0].label, "Tue")
        XCTAssertEqual(points?[1].label, "Wed")
    }

    func testPointsCarryCumulativeTokenCounts() {
        let windowStart = calendar.date(from: DateComponents(year: 2023, month: 11, day: 13))!
        let now = windowStart.addingTimeInterval(0.5 * week)
        let resetsAt = windowStart.addingTimeInterval(week)
        let daily = [
            entry(windowStart.addingTimeInterval(1 * 24 * 3600), tokens: 100),
            entry(windowStart.addingTimeInterval(2 * 24 * 3600), tokens: 300)
        ]
        let points = PaceProjectionTrajectory.points(
            used: 50, limit: 100, resetsAt: resetsAt, periodDuration: week, now: now,
            daily: daily, calendar: calendar
        )
        XCTAssertEqual(points?[0].cumulativeTokens, 100)
        XCTAssertEqual(points?[1].cumulativeTokens, 400)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter PaceProjectionTrajectoryTests`
Expected: FAIL — "cannot find 'PaceProjectionTrajectory' in scope"

**Step 3: Write the final implementation**

```swift
import Foundation

/// One normalized point on the run-out chart's usage trajectory: `x` = time through the window
/// (0...1), `y` = share of the limit used (0...1).
struct TrajectoryPoint: Hashable, Sendable {
    var x: Double
    var y: Double
    var label: String? = nil
    var cumulativeTokens: Int? = nil
}

/// Builds the real cumulative-usage trajectory for the run-out chart from the provider's per-day token
/// series within the meter's window, scaled so the final point lands at the meter's current used
/// fraction. The trajectory's *shape* is real (from actual daily usage); the absolute scale is
/// normalized to the meter because the daily series is in tokens while the meter is a fraction.
/// `nil` when there's no per-day data inside the window (e.g. a 5-hour session), so the chart falls
/// back to a straight line. Pure logic so it's unit-testable like `Pace`.
enum PaceProjectionTrajectory {
    static func points(
        used: Double, limit: Double,
        resetsAt: Date, periodDuration: TimeInterval,
        now: Date,
        daily: [DailyUsageEntry],
        calendar: Calendar = .current
    ) -> [TrajectoryPoint]? {
        guard limit > 0, periodDuration > 0 else { return nil }
        let windowStart = resetsAt.addingTimeInterval(-periodDuration)
        let entries = daily.compactMap { entry -> (Date, Int)? in
            guard let date = Self.parseDayKey(entry.date, calendar: calendar) else { return nil }
            return (date, entry.totalTokens)
        }
        .filter { $0.0 >= windowStart && $0.0 <= now }
        .sorted { $0.0 < $1.0 }
        let total = entries.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return nil }
        let scale = (used / limit) / Double(total)
        var cumulative = 0.0
        var points: [TrajectoryPoint] = []
        var labelStyle = Date.FormatStyle()
        labelStyle.locale = Locale(identifier: "en_US_POSIX")
        labelStyle.timeZone = calendar.timeZone
        labelStyle.calendar = calendar
        for (date, tokens) in entries {
            cumulative += Double(tokens)
            let x = min(max(date.timeIntervalSince(windowStart) / periodDuration, 0), 1)
            let y = min(max(cumulative * scale, 0), 1)
            points.append(TrajectoryPoint(
                x: x, y: y,
                label: date.formatted(labelStyle.weekday(.abbreviated)),
                cumulativeTokens: Int(cumulative)
            ))
        }
        return points
    }

    private static func parseDayKey(_ key: String, calendar: Calendar) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        return formatter.date(from: key)
    }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter PaceProjectionTrajectoryTests`
Expected: PASS (all 5 tests)

**Step 5: Commit**

```bash
git add Sources/OpenUsage/Support/PaceProjectionTrajectory.swift Tests/OpenUsageTests/PaceProjectionTrajectoryTests.swift
git commit -m "feat: add pace projection usage trajectory computation"
```

---

### Task 3.2: `WidgetData.trajectoryPoints` + store computation

**Files:**
- Modify: `Sources/OpenUsage/Models/WidgetData.swift`
- Modify: `Sources/OpenUsage/Stores/WidgetDataStore.swift`

**Step 1: Add the field**

In `Sources/OpenUsage/Models/WidgetData.swift`, near the projection fields:

```swift
    /// The real cumulative-usage trajectory for the run-out summary row, in normalized 0...1 points
    /// (x = time through the window, y = share of the limit). `nil` when the provider has no per-day
    /// data inside the window, so the chart falls back to a straight line.
    var trajectoryPoints: [TrajectoryPoint]? = nil
```

**Step 2: Compute it in the store**

In `Sources/OpenUsage/Stores/WidgetDataStore.swift`, in `projectionSummaryData`, after setting
`data.projectionTitle` (and before returning), compute the trajectory from the snapshot's daily series
(using the already-captured `let now = now()`):

```swift
        data.trajectoryPoints = PaceProjectionTrajectory.points(
            used: selected.used, limit: selected.limit,
            resetsAt: selected.resetsAt ?? now, periodDuration: TimeInterval(selected.periodDurationMs ?? 0) / 1000,
            now: now,
            daily: snapshot.usageHistory?.series.daily ?? []
        )
```

**Step 3: Build to verify it compiles**

Run: `swift build`
Expected: PASS.

**Step 4: Commit**

```bash
git add Sources/OpenUsage/Models/WidgetData.swift Sources/OpenUsage/Stores/WidgetDataStore.swift
git commit -m "feat: carry usage trajectory on the run-out summary row"
```

---

### Task 3.3: `PaceProjectionChart` trajectory + gradient + run-out marker

**Files:**
- Modify: `Sources/OpenUsage/Views/PaceProjectionChart.swift`

**Step 1: Add the trajectory, gradient fill, and run-out marker**

The final `PaceProjectionChart` (shown in full in Task 2.5) draws, in order: the limit line, the dashed
even-pace reference, the real usage trajectory (or a straight line from start to the current point),
the projection line, a gradient fill under the projection line, visible dots at each trajectory point,
the projection line stroke, the current usage point, and the run-out marker at the projection
endpoint (inset so it stays fully on-canvas). The trajectory is drawn thinner (`lineWidth: 1.5`,
`color.opacity(0.6)`) than the projection (`lineWidth: 2`, full color). The gradient is a vertical
linear gradient from `color.opacity(0.25)` at the top to `color.opacity(0.0)` at the bottom.

**Step 2: Build to verify it compiles**

Run: `swift build`
Expected: PASS.

**Step 3: Commit**

```bash
git add Sources/OpenUsage/Views/PaceProjectionChart.swift
git commit -m "feat: add gradient fill, trajectory, and run-out marker to the projection chart"
```

---

### Task 3.4: Wire the trajectory into the inline row

**Files:**
- Modify: `Sources/OpenUsage/Views/PaceProjectionInlineRow.swift`

**Step 1: Pass the trajectory**

In `PaceProjectionInlineRow`, pass `data.trajectoryPoints` to the chart:

```swift
            if let projection {
                VStack(alignment: .leading, spacing: 2) {
                    PaceProjectionChart(projection: projection, severity: state.severity, trajectory: data.trajectoryPoints)
                        .frame(height: density.projectionChartHeight)
                    PaceProjectionXAxis(projection: projection, trajectory: data.trajectoryPoints)
                }
            }
```

The hover popover (`PaceProjectionDetail`) also passes `data.trajectoryPoints` (via the inline row's
click popover), so it draws the real trajectory too.

**Step 2: Build to verify it compiles**

Run: `swift build`
Expected: PASS.

**Step 3: Commit**

```bash
git add Sources/OpenUsage/Views/PaceProjectionInlineRow.swift
git commit -m "feat: draw the real usage trajectory in the run-out summary row"
```

---

## Phase 4 — X-axis + click detail

### Task 4.1: `PaceProjectionXAxis` view

**Files:**
- Create: `Sources/OpenUsage/Views/PaceProjectionXAxis.swift`

**Step 1: Create the x-axis view**

The x-axis labels live in their own row below the graph so the small labels never clip inside the
chart's tight canvas:

```swift
import SwiftUI

/// The x-axis labels for the pace projection chart, drawn in their own row below the graph so the
/// small labels never clip inside the chart's tight canvas. Shows the day-of-week labels at each
/// trajectory point, plus "now" and the reset date. Same width as the chart, so labels align with
/// the graph above.
struct PaceProjectionXAxis: View {
    let projection: PaceProjection
    let trajectory: [TrajectoryPoint]?

    var body: some View {
        Canvas { context, size in
            let edgeInset: CGFloat = 12
            let labelY = size.height / 2
            let nowX = min(max(point(x: projection.elapsedFraction, in: size).x, edgeInset), size.width - edgeInset)
            let resetX = min(max(point(x: 1, in: size).x, edgeInset), size.width - 30)
            var lastDayLabelX: CGFloat = -.infinity
            if let trajectory {
                for p in trajectory {
                    if let label = p.label {
                        let px = min(max(point(x: p.x, in: size).x, edgeInset), size.width - edgeInset)
                        if px - lastDayLabelX >= 24, abs(px - nowX) >= 20, abs(px - resetX) >= 20 {
                            context.draw(Text(label).font(.system(size: 8)).foregroundStyle(.secondary),
                                         at: CGPoint(x: px, y: labelY))
                            lastDayLabelX = px
                        }
                    }
                }
            }
            context.draw(Text("now").font(.system(size: 8)).foregroundStyle(.secondary),
                         at: CGPoint(x: nowX, y: labelY))
            context.draw(Text(Formatters.monthDayLabel(projection.resetsAt)).font(.system(size: 8)).foregroundStyle(.secondary),
                         at: CGPoint(x: resetX, y: labelY))
        }
        .frame(height: 12)
    }

    private func point(x: Double, in size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: size.height)
    }
}
```

**Step 2: Build to verify it compiles**

Run: `swift build`
Expected: PASS.

**Step 3: Commit**

```bash
git add Sources/OpenUsage/Views/PaceProjectionXAxis.swift
git commit -m "feat: draw the projection chart x-axis in its own row"
```

---

### Task 4.2: Wire the x-axis into the inline row and popover

**Files:**
- Modify: `Sources/OpenUsage/Views/PaceProjectionInlineRow.swift`
- Modify: `Sources/OpenUsage/Views/PaceProjectionDetail.swift`

**Step 1: Inline row**

In `PaceProjectionInlineRow`, stack the chart with the new x-axis below it (already shown in the final
row in Task 2.5):

```swift
            if let projection {
                VStack(alignment: .leading, spacing: 2) {
                    PaceProjectionChart(projection: projection, severity: state.severity, trajectory: data.trajectoryPoints)
                        .frame(height: density.projectionChartHeight)
                    PaceProjectionXAxis(projection: projection, trajectory: data.trajectoryPoints)
                }
            }
```

**Step 2: Popover**

In `PaceProjectionDetail`, the body already stacks the chart with `PaceProjectionXAxis` (see the final
view in Task 1.3):

```swift
        VStack(alignment: .leading, spacing: 8) {
            header
            chart
            PaceProjectionXAxis(projection: projection, trajectory: trajectory)
        }
```

**Step 3: Build to verify it compiles**

Run: `swift build`
Expected: PASS.

**Step 4: Commit**

```bash
git add Sources/OpenUsage/Views/PaceProjectionInlineRow.swift Sources/OpenUsage/Views/PaceProjectionDetail.swift
git commit -m "feat: show the projection x-axis below the inline and popover charts"
```

---

### Task 4.3: Click-to-open larger chart

**Files:**
- Modify: `Sources/OpenUsage/Views/PaceProjectionInlineRow.swift`

**Step 1: Make the row clickable and present the larger chart**

The final `PaceProjectionInlineRow` (shown in full in Task 2.5) makes the whole row a click target that
presents `PaceProjectionDetail` (the larger chart) via a click-triggered popover:

```swift
        .contentShape(Rectangle())
        .onTapGesture { if projection != nil { showDetail = true } }
        .motionAwareHoverPopover(isPresented: $showDetail, reduceAnimations: reduceAnimations) {
            if let projection {
                PaceProjectionDetail(
                    title: data.projectionTitle ?? data.title,
                    projection: projection,
                    readout: state.tooltip,
                    severity: state.severity,
                    trajectory: data.trajectoryPoints
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { showDetail = true }
        .accessibilityLabel(accessibilityLabel)
```

The `accessibilityLabel` mentions it's clickable:

```swift
    private var accessibilityLabel: String {
        let title = data.projectionTitle ?? data.title
        return "\(title) run-out projection\(data.meterState().tooltip.map { ", \($0)" } ?? ""), tap for details"
    }
```

**Step 2: Build to verify it compiles**

Run: `swift build`
Expected: PASS.

**Step 3: Commit**

```bash
git add Sources/OpenUsage/Views/PaceProjectionInlineRow.swift
git commit -m "feat: open a larger chart on clicking the run-out summary row"
```

---

## Phase 5 — X-axis fix + point hover

### Task 5.1: `PaceProjectionChart` point hover

**Files:**
- Modify: `Sources/OpenUsage/Views/PaceProjectionChart.swift`
- Test: `Tests/OpenUsageTests/PaceProjectionChartTests.swift`

**Step 1: Write the failing test**

```swift
import XCTest
@testable import OpenUsage

/// Locks the hover hit test: finds the trajectory point whose view-space x (scaled by canvas width) is
/// nearest the cursor within a fixed x reach. The hit test is x-dominant — y is ignored.
final class PaceProjectionChartTests: XCTestCase {
    private let size = CGSize(width: 200, height: 100)

    private func point(_ x: Double, _ y: Double, tokens: Int = 0) -> TrajectoryPoint {
        TrajectoryPoint(x: x, y: y, cumulativeTokens: tokens)
    }

    func testReturnsNearestIndexWhenPointWithinReach() {
        let trajectory = [point(0.25, 0.5), point(0.5, 0.5), point(0.75, 0.5)]
        // Point 1 maps to (100, 50); cursor 2pt off in x is within the 24pt reach.
        let location = CGPoint(x: 102, y: 52)
        XCTAssertEqual(nearestTrajectoryPointIndex(to: location, size: size, trajectory: trajectory), 1)
    }

    func testReturnsIndexWhenFarInYButNearInX() {
        let trajectory = [point(0.5, 0.5)]
        // Cursor shares point 1's x (100) but is 40pt off in y — y is ignored, so it still hits.
        let location = CGPoint(x: 100, y: 90)
        XCTAssertEqual(nearestTrajectoryPointIndex(to: location, size: size, trajectory: trajectory), 0)
    }

    func testReturnsNilWhenFarInX() {
        let trajectory = [point(0.5, 0.5)]
        // Cursor is 50pt off in x — past the 24pt reach.
        let location = CGPoint(x: 150, y: 50)
        XCTAssertNil(nearestTrajectoryPointIndex(to: location, size: size, trajectory: trajectory))
    }

    func testReturnsNilForEmptyTrajectory() {
        XCTAssertNil(nearestTrajectoryPointIndex(to: CGPoint(x: 100, y: 50), size: size, trajectory: []))
        XCTAssertNil(nearestTrajectoryPointIndex(to: CGPoint(x: 100, y: 50), size: size, trajectory: nil))
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter PaceProjectionChartTests`
Expected: FAIL — "cannot find 'nearestTrajectoryPointIndex' in scope"

**Step 3: Add the hover tracking**

The final `PaceProjectionChart` (shown in full in Task 2.5) wraps the Canvas in a `GeometryReader`,
holds `@State private var hoveredIndex: Int?`, and attaches `.onContinuousHover` to highlight the
nearest trajectory point and draw a value label. The hit test is a free function:

```swift
/// The index of the trajectory point nearest the cursor by x within a ~`reach` x reach, or `nil` when
/// none is close enough. The hit test is x-dominant: hovering a day's x-region highlights that day's
/// point regardless of y. `size` is the chart canvas size; the point and cursor are compared in view
/// points.
func nearestTrajectoryPointIndex(to location: CGPoint, size: CGSize,
                                 trajectory: [TrajectoryPoint]?, reach: CGFloat = 24) -> Int? {
    guard let trajectory, !trajectory.isEmpty else { return nil }
    var best: (index: Int, distance: CGFloat)? = nil
    for (i, p) in trajectory.enumerated() {
        let px = CGFloat(p.x) * size.width
        let dx = abs(px - location.x)
        guard dx <= reach else { continue }
        if best == nil || dx < best!.distance {
            best = (i, dx)
        }
    }
    return best?.index
}
```

The hovered-point label reads `"\(Int((p.y * 100).rounded()))% · \(MetricFormatter.number(Double(p.cumulativeTokens ?? 0), kind: .count, style: .row)) tokens"` — the percent is the meter-normalized used
fraction, while the token count is the raw daily-series cumulative (the two are on different scales and
don't necessarily imply each other, intentionally).

**Step 4: Run test to verify it passes**

Run: `swift test --filter PaceProjectionChartTests`
Expected: PASS (all 4 tests)

**Step 5: Commit**

```bash
git add Sources/OpenUsage/Views/PaceProjectionChart.swift Tests/OpenUsageTests/PaceProjectionChartTests.swift
git commit -m "feat: highlight trajectory points on hover with usage values"
```

---

## Phase 6 — Full verification + docs

**Files:**
- Modify: `docs/dashboard.md`

**Step 1: Run the full test suite**

Run: `swift test`
Expected: PASS (all existing tests + the new `PaceProjectionTests`, `PaceProjectionSummaryTests`,
`PaceProjectionTrajectoryTests`, `PaceProjectionChartTests`, and `ProjectionSummaryStoreTests`).

**Step 2: Update the dashboard doc**

In `docs/dashboard.md`, in the **Rows** section, document the hover popover and the Run-out row:

```markdown
- **Hover a bounded meter row** with a reset window to reveal a burn-down chart of the current window:
  the even-pace reference line, your usage so far, and the projection line to the limit — the run-out
  point, labeled with the same "Limit in 3h 5m" / "~35% left at reset" readout as the row. Rows without
  a reset window (credit balances) keep the plain hover tooltip instead.
- Providers with bounded meters (Claude, Codex, Cursor, Antigravity, OpenCode) show a **Run-out** row:
  a compact line graph of the most at-risk meter's projection — the even-pace reference line, your real
  usage trajectory, and the projection line to the limit with a marker at the run-out point. The header
  names the meter and its run-out figure ("Limit in 3h 5m" / "~35% left at reset"). The chart labels its
  days and the reset time, and clicking it opens a larger, more readable version. Hover a point on the
  chart to see its percent of the limit used and cumulative tokens. On by default; hide or reorder it
  from Customize like any metric. It shows nothing when no bounded meter has a projection to draw.
```

**Step 3: Commit**

```bash
git add docs/dashboard.md
git commit -m "docs: document the pace projection chart and run-out row"
```

---

## Verification checklist

- [ ] `swift test --filter PaceProjectionTests` passes (10 tests)
- [ ] `swift test --filter PaceProjectionSummaryTests` passes (8 tests)
- [ ] `swift test --filter PaceProjectionTrajectoryTests` passes (5 tests)
- [ ] `swift test --filter PaceProjectionChartTests` passes (4 tests)
- [ ] `swift test --filter ProjectionSummaryStoreTests` passes (2 tests)
- [ ] `swift build` passes
- [ ] `swift test` passes (full suite)
- [ ] Manual: hover a bounded meter with a reset window (e.g. Claude 5h, weekly quota) → chart popover appears; hover a credit-balance row → plain tooltip stays
- [ ] Manual: a provider with bounded meters shows the Run-out row inline (trajectory, gradient fill, run-out marker, x-axis labels); a provider without shows nothing; the per-meter hover popover still works
- [ ] Manual: clicking the Run-out row opens a larger chart; hovering a trajectory point highlights it and shows "% · tokens"
