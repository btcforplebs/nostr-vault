import SwiftUI

/// Draws a hop sphere person's path in to you (`GlobeChain`, Logen
/// 2026-11-25): from their face through each link's spot on its layer (the
/// nested spheres, then the inner globe) to you at the centre. Points are
/// found again every frame, so the line follows the layers as they spin. A
/// link not on screen is skipped: the line runs straight on to the next.
/// It draws in from them toward you, like the inner globe's threads.
enum GlobeChainPainter {
    /// How long the line takes to draw in, seconds.
    static let drawIn: TimeInterval = 0.6

    /// `points` run from the tapped person to you; `front` is each one's
    /// 0-1 nearness, so a stretch round the back is drawn fainter.
    static func draw(_ points: [(point: CGPoint, front: Double)], progress: Double,
                     in context: inout GraphicsContext, accent: Color, ink: GlobeInk) {
        guard points.count >= 2, progress > 0 else { return }
        let legs = Double(points.count - 1)
        var glow = Path()
        for i in 0..<(points.count - 1) {
            let share = min(1, max(0, progress * legs - Double(i)))
            guard share > 0 else { break }
            let a = points[i].point, b = points[i + 1].point
            let end = CGPoint(x: a.x + (b.x - a.x) * share, y: a.y + (b.y - a.y) * share)
            var leg = Path()
            leg.move(to: a)
            leg.addLine(to: end)
            glow.addPath(leg)
            let front = (points[i].front + points[i + 1].front) / 2
            context.stroke(leg, with: .color(ink.thread.opacity(0.45 + 0.5 * front)),
                           style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        }
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 4))
            layer.stroke(glow, with: .color(accent.opacity(0.55)), lineWidth: 3)
        }
        // A ring round the tapped person, so the line's start is clear even
        // before their face comes round.
        let start = points[0].point, ring = 13.0
        context.stroke(Path(ellipseIn: CGRect(x: start.x - ring, y: start.y - ring, width: 2 * ring, height: 2 * ring)),
                       with: .color(accent.opacity(0.9)), lineWidth: 2)
        // A bead on each link reached, so the layers it passes are clear.
        for (i, p) in points.enumerated().dropFirst().dropLast() where Double(i) <= progress * legs {
            let r = 2.6
            context.fill(Path(ellipseIn: CGRect(x: p.point.x - r, y: p.point.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(accent.opacity(0.6 + 0.4 * p.front)))
        }
    }
}
