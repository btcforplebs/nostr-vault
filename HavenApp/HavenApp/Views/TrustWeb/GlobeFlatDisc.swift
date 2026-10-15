import SwiftUI

/// The flat view's ground: a dark disc with its rings and meridians faintly
/// drawn, and a lit rim like an ice wall, under the same stars and faces as
/// the globe. Drawn first, so everything else sits on it.
struct GlobeFlatDisc {
    /// The disc's middle on screen.
    let center: CGPoint
    /// Points per unit of the globe's space, zoom included.
    let unit: Double
    /// How far the disc has turned, so its meridians turn with the stars.
    let yaw: Double
    /// 0 to 1 while the globe flattens.
    let opacity: Double
    let ringColor: Color
    let hazeColor: Color

    /// Lines from the middle to the rim, like a flat map's meridians.
    private static let meridians = 12

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

        // Each shell's band, then a fine line through its middle.
        let shells: [(Double, Color)] = [(TrustMap.ringRadius, ringColor),
                                         (TrustMap.closeRadius, hazeColor),
                                         (TrustMap.outerRadius, hazeColor)]
        for (radius, color) in shells {
            let band = 2 * GlobeFlat.bandSpread * radius * unit
            context.stroke(circle(radius * unit), with: .color(color.opacity(0.045 * opacity)), lineWidth: band)
            context.stroke(circle(radius * unit), with: .color(color.opacity(0.10 * opacity)), lineWidth: 0.6)
        }

        // Meridians, faint, from just outside the middle to the rim.
        var spokes = Path()
        for i in 0..<Self.meridians {
            let angle = yaw + Double(i) * 2 * .pi / Double(Self.meridians)
            let dir = CGPoint(x: cos(angle), y: -sin(angle))
            spokes.move(to: CGPoint(x: center.x + dir.x * 0.32 * unit, y: center.y + dir.y * 0.32 * unit))
            spokes.addLine(to: CGPoint(x: center.x + dir.x * rim, y: center.y + dir.y * rim))
        }
        context.stroke(spokes, with: .color(.white.opacity(0.05 * opacity)), lineWidth: 0.5)

        // The rim: a glow in one blurred layer, and a bright edge.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 6))
            layer.stroke(circle(rim), with: .color(ringColor.opacity(0.45 * opacity)), lineWidth: 5)
        }
        context.stroke(circle(rim), with: .color(.white.opacity(0.55 * opacity)), lineWidth: 1.1)
    }
}
