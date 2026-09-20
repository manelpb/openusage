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
            // Right-anchor the reset date at the edge so it never clips, and drop the redundant "now"
            // marker when the two would overlap (the reset is imminent).
            let resetX = size.width - 2
            let nowX = min(max(point(x: projection.elapsedFraction, in: size).x, edgeInset), size.width - edgeInset)
            let showsNow = resetX - nowX >= 34
            var lastDayLabelX: CGFloat = -.infinity
            if let trajectory {
                for p in trajectory {
                    if let label = p.label {
                        let px = min(max(point(x: p.x, in: size).x, edgeInset), size.width - edgeInset)
                        if px - lastDayLabelX >= 24,
                           !showsNow || abs(px - nowX) >= 20,
                           resetX - px >= 34 {
                            context.draw(Text(label).font(.system(size: 8)).foregroundStyle(.secondary),
                                         at: CGPoint(x: px, y: labelY))
                            lastDayLabelX = px
                        }
                    }
                }
            }
            if showsNow {
                context.draw(Text("now").font(.system(size: 8)).foregroundStyle(.secondary),
                             at: CGPoint(x: nowX, y: labelY))
            }
            context.draw(Text(Formatters.monthDayLabel(projection.resetsAt)).font(.system(size: 8)).foregroundStyle(.secondary),
                         at: CGPoint(x: resetX, y: labelY), anchor: .trailing)
        }
        .frame(height: 12)
    }

    private func point(x: Double, in size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: size.height)
    }
}
