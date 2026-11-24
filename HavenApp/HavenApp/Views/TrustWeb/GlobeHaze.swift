import SwiftUI

/// Paints a zoomed-out ring's haze (`GlobeHazeField`): the people ranked
/// after its top 300, as faint dots round the frame's middle, the best
/// nearest it. The dots are built once per ring into two unit-space paths
/// (the brighter better half, the fainter rest); each frame only scales
/// them to the ring's radius, so thousands of dots cost two fills.
/// Never tapped: `GlobeScene.hit` only looks at the globe's faces.
/// Android twin (H4): `ui/components/trustweb/GlobeHaze.kt`.
enum GlobeHaze {
    /// A haze dot's radius on screen, at the fitted ring.
    static let dot = 1.0
    /// How strongly the better and the lower half are drawn, at full zoom.
    static let alphas = (best: 0.42, rest: 0.24)

    private struct Built {
        let keys: [String]
        let ref: Double
        let best: Path
        let rest: Path
    }

    /// One per hop; the canvas draws on the main thread only.
    private static var built: [Int: Built] = [:]

    /// Draws `ring`'s haze at `alpha` (0 to 1, the ring's emphasis), round
    /// `mid` at radius `r`. `ref` is the fitted ring's radius, where a dot is
    /// `dot` points across.
    static func draw(_ ring: TrustMapOuter.Ring, alpha: Double, mid: CGPoint, r: Double, ref: Double,
                     in context: inout GraphicsContext, ink: GlobeInk) {
        guard alpha > 0.01, !ring.haze.isEmpty, r > 1, ref > 1 else { return }
        let paths = paths(for: ring, ref: ref)
        var c = context
        c.translateBy(x: mid.x, y: mid.y)
        c.scaleBy(x: r, y: r)
        c.fill(paths.best, with: .color(ink.star.opacity(alphas.best * alpha)))
        c.fill(paths.rest, with: .color(ink.star.opacity(alphas.rest * alpha)))
    }

    private static func paths(for ring: TrustMapOuter.Ring, ref: Double) -> Built {
        // A ring's keys come from one TrustMapOuter, so this is a buffer check.
        if let b = built[ring.hop], b.keys == ring.haze, abs(b.ref - ref) < 0.5 { return b }
        let d = dot / ref
        var best = Path(), rest = Path()
        let half = ring.haze.count / 2
        for (i, p) in GlobeHazeField.positions(ring.haze).enumerated() {
            let rect = CGRect(x: p.x - d, y: p.y - d, width: d * 2, height: d * 2)
            if i < half { best.addEllipse(in: rect) } else { rest.addEllipse(in: rect) }
        }
        let b = Built(keys: ring.haze, ref: ref, best: best, rest: rest)
        built[ring.hop] = b
        return b
    }
}
