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
