import SwiftUI

/// Draws zaps as lightning bolts: a jagged white core in a warm electric
/// glow, with a short fork, striking from the zapper to the person zapped in
/// an instant, flickering while it flashes, then an afterglow. A bolt round
/// the back dims like the stars (`GlobeEdge`). Reduce Motion: one plain,
/// steady line that fades.
struct GlobeBoltPainter {
    /// Zap gold, so a bolt never reads as a note's white star.
    static let color = Color(red: 1, green: 0.84, blue: 0.32)

    struct Shape {
        var main = Path()
        var fork = Path()
        var end: CGPoint?
        var alpha: Double
        var landing: Double
    }

    /// One bolt's shape this frame. `at` is a point on its arc, 0 at the
    /// zapper and 1 at the person zapped, already on screen.
    static func shape(of line: GlobeArcs.Line, stage: GlobeArcs.Stage, now: TimeInterval, reduceMotion: Bool,
                      at: (Double) -> GlobeScene.Projected?) -> Shape? {
        let n = GlobeBolt.segments
        guard let start = at(0), let whole = at(1), let middle = at(0.5) else { return nil }
        let points = (0...n).map { at(stage.head * Double($0) / Double(n)) }
        guard points.allSatisfy({ $0 != nil }) else { return nil }
        // Jagged across the screen, in proportion to the whole bolt's length.
        let length = hypot(whole.point.x - start.point.x, whole.point.y - start.point.y)
        let seed = GlobeBolt.seed(line.note)
        let frame = GlobeBolt.frame(at: now - line.born, flickers: GlobeArcs.boltFlickers(line, at: now))
        let offsets = GlobeBolt.offsets(seed: seed, frame: frame, reduceMotion: reduceMotion)
        var jagged: [CGPoint] = []
        for i in 0...n {
            let p = points[i]!.point
            let before = points[max(0, i - 1)]!.point, after = points[min(n, i + 1)]!.point
            let dx = after.x - before.x, dy = after.y - before.y, d = max(0.001, hypot(dx, dy))
            jagged.append(CGPoint(x: p.x - dy / d * offsets[i] * length, y: p.y + dx / d * offsets[i] * length))
        }
        var shape = Shape(alpha: stage.alpha * GlobeEdge.arc(depth: middle.depth), landing: stage.landing)
        shape.main.move(to: jagged[0])
        for p in jagged.dropFirst() { shape.main.addLine(to: p) }
        if stage.head >= 1 { shape.end = jagged[n] }
        // A short fork off the middle third, once the bolt has passed it.
        let fork = GlobeBolt.fork(seed: seed)
        if !reduceMotion, fork.from < n, Double(fork.from) / Double(n) < stage.head {
            let a = jagged[fork.from], b = jagged[fork.from + 1]
            let angle = atan2(b.y - a.y, b.x - a.x) + fork.turn
            let reach = fork.length * length
            let kink = offsets[fork.from] * length * 0.8
            shape.fork.move(to: a)
            shape.fork.addLine(to: CGPoint(x: a.x + cos(angle) * reach * 0.5 - sin(angle) * kink,
                                           y: a.y + sin(angle) * reach * 0.5 + cos(angle) * kink))
            shape.fork.addLine(to: CGPoint(x: a.x + cos(angle) * reach, y: a.y + sin(angle) * reach))
        }
        return shape.alpha > 0.01 ? shape : nil
    }

    static func draw(_ shapes: [Shape], in context: inout GraphicsContext, unit: Double) {
        guard !shapes.isEmpty else { return }
        // The glow, all bolts in one blurred layer.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 5))
            for s in shapes {
                layer.stroke(s.main, with: .color(color.opacity(0.7 * s.alpha)),
                             style: StrokeStyle(lineWidth: 5 * unit, lineCap: .round, lineJoin: .round))
                layer.stroke(s.fork, with: .color(color.opacity(0.5 * s.alpha)),
                             style: StrokeStyle(lineWidth: 3 * unit, lineCap: .round, lineJoin: .round))
            }
        }
        for s in shapes {
            context.stroke(s.main, with: .color(.white.opacity(s.alpha)),
                           style: StrokeStyle(lineWidth: 1.6 * unit, lineCap: .round, lineJoin: .round))
            context.stroke(s.fork, with: .color(.white.opacity(0.75 * s.alpha)),
                           style: StrokeStyle(lineWidth: 0.9 * unit, lineCap: .round, lineJoin: .round))
            // Where it strikes: a gold flash that opens and fades.
            if let p = s.end {
                let r = (5 + 12 * s.landing) * unit
                context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                             with: .radialGradient(Gradient(colors: [color.opacity(0.8 * s.alpha * (1 - 0.6 * s.landing)), .clear]),
                                                   center: p, startRadius: 0, endRadius: r))
            }
        }
    }
}
