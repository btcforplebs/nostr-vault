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
        /// How hard it strikes, 0 to 1, by the zap's amount.
        var strength = 0.0
        /// 1 while it flashes (white-hot), 0 in its afterglow.
        var flash = 0.0
    }

    /// One bolt's shape this frame. `at` is a point on its arc, 0 at the
    /// zapper and 1 at the person zapped, already on screen.
    static func shape(of line: GlobeArcs.Line, stage: GlobeArcs.Stage, now: TimeInterval, reduceMotion: Bool,
                      at: (Double) -> GlobeScene.Projected?) -> Shape? {
        let n = GlobeBolt.segments
        // Points the camera can't see (zoomed in past them) break the bolt,
        // the way a star's trail breaks, rather than hiding all of it.
        let points = (0...n).map { at(stage.head * Double($0) / Double(n)) }
        let seen = points.compactMap { $0 }
        guard seen.count >= 2, let first = seen.first, let last = seen.last else { return nil }
        // Jagged across the screen, in proportion to the whole bolt's length.
        let whole = at(1)?.point ?? last.point, origin = at(0)?.point ?? first.point
        let length = hypot(whole.x - origin.x, whole.y - origin.y)
        let seed = GlobeBolt.seed(line.note)
        let frame = GlobeBolt.frame(at: now - line.born, flickers: GlobeArcs.boltFlickers(line, at: now))
        let offsets = GlobeBolt.offsets(seed: seed, frame: frame, reduceMotion: reduceMotion)
        var jagged: [CGPoint?] = []
        for i in 0...n {
            guard let p = points[i]?.point else { jagged.append(nil); continue }
            let before = points[max(0, i - 1)]?.point ?? p, after = points[min(n, i + 1)]?.point ?? p
            let dx = after.x - before.x, dy = after.y - before.y, d = max(0.001, hypot(dx, dy))
            jagged.append(CGPoint(x: p.x - dy / d * offsets[i] * length, y: p.y + dx / d * offsets[i] * length))
        }
        let depth = (at(0.5) ?? seen[seen.count / 2]).depth
        // While it flashes it flickers (not under Reduce Motion) and burns white-hot.
        let flashing = GlobeArcs.boltFlickers(line, at: now) && !reduceMotion
        let flicker = flashing ? GlobeBolt.flicker(seed: seed, frame: frame) : 1
        var shape = Shape(alpha: stage.alpha * GlobeEdge.arc(depth: depth) * flicker, landing: stage.landing,
                          strength: line.strength, flash: flashing ? 1 : 0)
        var open = false
        for p in jagged {
            guard let p else { open = false; continue }
            if open { shape.main.addLine(to: p) } else { shape.main.move(to: p); open = true }
        }
        if stage.head >= 1 { shape.end = jagged[n] }
        // A short fork off the middle third, two for a strong zap, once the
        // bolt has passed it.
        for fork in GlobeBolt.forks(seed: seed, strength: line.strength)
        where !reduceMotion && fork.from < n && Double(fork.from) / Double(n) < stage.head {
            guard let a = jagged[fork.from], let b = jagged[fork.from + 1] else { continue }
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
        // The glow, all bolts in one blurred layer; a stronger zap glows wider.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 5))
            for s in shapes {
                layer.stroke(s.main, with: .color(color.opacity(0.75 * s.alpha)),
                             style: StrokeStyle(lineWidth: (5 + 5 * s.strength) * unit, lineCap: .round, lineJoin: .round))
                layer.stroke(s.fork, with: .color(color.opacity(0.55 * s.alpha)),
                             style: StrokeStyle(lineWidth: (3 + 2 * s.strength) * unit, lineCap: .round, lineJoin: .round))
            }
        }
        // While it flashes, a white-hot bloom along the core, in one more layer.
        let flashing = shapes.filter { $0.flash > 0 }
        if !flashing.isEmpty {
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 2))
                for s in flashing {
                    layer.stroke(s.main, with: .color(.white.opacity(0.85 * s.alpha)),
                                 style: StrokeStyle(lineWidth: (3 + 3 * s.strength) * unit, lineCap: .round, lineJoin: .round))
                }
            }
        }
        for s in shapes {
            context.stroke(s.main, with: .color(.white.opacity(s.alpha)),
                           style: StrokeStyle(lineWidth: (1.6 + 1.2 * s.strength) * unit, lineCap: .round, lineJoin: .round))
            context.stroke(s.fork, with: .color(.white.opacity(0.8 * s.alpha)),
                           style: StrokeStyle(lineWidth: (0.9 + 0.5 * s.strength) * unit, lineCap: .round, lineJoin: .round))
            // Where it strikes: a gold burst that opens and fades, and a thin
            // ring running out from it. Bigger for a bigger zap.
            if let p = s.end {
                let scale = (1 + 0.8 * s.strength) * unit
                let r = (6 + 16 * s.landing) * scale
                context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                             with: .radialGradient(Gradient(colors: [.white.opacity(0.9 * s.alpha * (1 - s.landing)),
                                                                     color.opacity(0.8 * s.alpha * (1 - 0.6 * s.landing)), .clear]),
                                                   center: p, startRadius: 0, endRadius: r))
                let ring = (8 + 26 * s.landing) * scale
                context.stroke(Path(ellipseIn: CGRect(x: p.x - ring, y: p.y - ring, width: 2 * ring, height: 2 * ring)),
                               with: .color(color.opacity(0.6 * s.alpha * (1 - s.landing))), lineWidth: 1.2 * unit)
            }
        }
    }
}
