// Pure SwiftUI Path-based sparkline that plots output-token growth over time.
// No Apple Charts framework dependency — uses GeometryReader + Path directly.

import SwiftUI
import ClaudeWatchCore

struct TokenRateSparkline: View {
    let samples: [TokenSample]
    var stroke: Color = Claude.orange
    var fill: Color = Claude.orange.opacity(0.18)
    var height: CGFloat = 32

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            sparklineCanvas
            Text("out · 5 min")
                .font(ClaudeFont.label(10))
                .foregroundStyle(Claude.textMuted)
        }
    }

    @ViewBuilder
    private var sparklineCanvas: some View {
        GeometryReader { geo in
            if samples.count < 2 {
                placeholderLine(in: geo.size)
            } else {
                ZStack {
                    fillPath(in: geo.size)
                    strokePath(in: geo.size)
                }
            }
        }
        .frame(height: height)
    }

    // MARK: - Path helpers

    /// Closed polygon tracing the area under the sparkline, for the fill.
    private func fillPath(in size: CGSize) -> some View {
        Path { path in
            let pts = normalizedPoints(in: size)
            guard let first = pts.first, let last = pts.last else { return }
            path.move(to: CGPoint(x: first.x, y: size.height))
            path.addLine(to: first)
            for pt in pts.dropFirst() {
                path.addLine(to: pt)
            }
            path.addLine(to: CGPoint(x: last.x, y: size.height))
            path.closeSubpath()
        }
        .fill(fill)
    }

    /// Open polyline along the data points, for the stroke.
    private func strokePath(in size: CGSize) -> some View {
        Path { path in
            let pts = normalizedPoints(in: size)
            guard let first = pts.first else { return }
            path.move(to: first)
            for pt in pts.dropFirst() {
                path.addLine(to: pt)
            }
        }
        .stroke(stroke, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }

    /// Faint dashed baseline shown when fewer than 2 samples exist.
    private func placeholderLine(in size: CGSize) -> some View {
        Path { path in
            let y = size.height * 0.6
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        .stroke(
            stroke.opacity(0.25),
            style: StrokeStyle(lineWidth: 1, dash: [4, 4])
        )
    }

    // MARK: - Coordinate mapping

    /// Maps each sample into a CGPoint in the view's coordinate space.
    /// x: linear over [first.time, last.time]
    /// y: linear over [0, maxOutputTokens], inverted (y=0 is top in CGContext)
    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard samples.count >= 2 else { return [] }

        let minTime = samples.first!.time.timeIntervalSinceReferenceDate
        let maxTime = samples.last!.time.timeIntervalSinceReferenceDate
        let timeSpan = maxTime - minTime

        let maxOutput = samples.map(\.outputTokens).max() ?? 1
        let yScale = maxOutput > 0 ? Double(maxOutput) : 1.0

        return samples.map { sample in
            let tNorm = timeSpan > 0
                ? (sample.time.timeIntervalSinceReferenceDate - minTime) / timeSpan
                : 0.0
            let vNorm = Double(sample.outputTokens) / yScale

            let x = tNorm * Double(size.width)
            // Invert y: value=1 should be at top (y=0), value=0 at bottom (y=height).
            let y = (1.0 - vNorm) * Double(size.height)
            return CGPoint(x: x, y: y)
        }
    }
}
