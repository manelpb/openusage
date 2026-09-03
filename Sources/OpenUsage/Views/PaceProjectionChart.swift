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
