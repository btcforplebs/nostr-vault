import SwiftUI

/// The flat view's ground: a dark disc, lighter at the middle, with its zones
/// marked by faint rings at most and a lit rim, under the same stars and
/// faces as the globe. Drawn first, so everything else sits on it.
struct GlobeFlatDisc {
    /// The disc's middle on screen.
    let center: CGPoint
    /// Points per disc unit, zoom included.
    let unit: Double
    /// 0 to 1 while the globe flattens.
    let opacity: Double
    let ringColor: Color
    let hazeColor: Color

    func draw(_ context: inout GraphicsContext) {
        guard opacity > 0.01 else { return }
        let rim = GlobeFlat.rim * unit
        func circle(_ r: Double) -> Path {
            Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        }

        // A soft halo past the rim, then the disc itself, lighter at the middle.
        context.fill(circle(rim * 1.12),
                     with: .radialGradient(Gradient(colors: [hazeColor.opacity(0.10 * opacity), .clear]),
                                           center: center, startRadius: rim * 0.92, endRadius: rim * 1.12))
        context.fill(circle(rim),
                     with: .radialGradient(Gradient(colors: [Color(red: 0.11, green: 0.11, blue: 0.24).opacity(opacity),
                                                             Color(red: 0.05, green: 0.05, blue: 0.12).opacity(opacity)]),
                                           center: center, startRadius: 0, endRadius: rim))

        // Where one zone gives way to the next: a faint dashed ring.
        let zones = GlobeFlat.zones
        for i in 1..<(zones.count - 2) {
            let edge = (zones[i].outer + zones[i + 1].inner) / 2 * rim
            context.stroke(circle(edge), with: .color(hazeColor.opacity(0.12 * opacity)),
                           style: StrokeStyle(lineWidth: 0.6, dash: [2, 5]))
        }

        // The rim: a glow in one blurred layer, and a bright edge.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 6))
            layer.stroke(circle(rim), with: .color(ringColor.opacity(0.45 * opacity)), lineWidth: 5)
        }
        context.stroke(circle(rim), with: .color(.white.opacity(0.55 * opacity)), lineWidth: 1.1)
    }

    /// The web's lines: you to each person you follow, all in one faint
    /// stroke, and a little brighter to the ones drawn as faces. Only real
    /// follows are drawn, so every line is a connection that exists.
    static func links(_ context: inout GraphicsContext, from core: CGPoint, to stars: [CGPoint],
                      faces: [CGPoint], color: Color, opacity: Double) {
        guard opacity > 0.01, !stars.isEmpty || !faces.isEmpty else { return }
        var faint = Path(), strong = Path()
        for p in stars { faint.move(to: core); faint.addLine(to: p) }
        for p in faces { strong.move(to: core); strong.addLine(to: p) }
        context.stroke(faint, with: .color(color.opacity(0.05 * opacity)), lineWidth: 0.5)
        context.stroke(strong, with: .color(color.opacity(0.22 * opacity)), lineWidth: 0.8)
    }
}
