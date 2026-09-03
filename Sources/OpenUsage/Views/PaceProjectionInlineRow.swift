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
