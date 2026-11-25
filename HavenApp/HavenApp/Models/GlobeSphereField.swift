import Foundation
import simd

/// Where a picked hop's people sit in its sphere (Logen 2026-11-25: "a 360
/// 3d globe view of that ring", not a flat ring at the edge). Picking Hop 3
/// or Hop 4 turns that ring into a globe of its own, round your nested inner
/// one. Its people fill the ball, not just its skin (Logen 2026-11-25: a
/// shell only reads as a thin ring at the edge): the best sit nearest the
/// middle, round your globe, and lower scores drift out to the edge
/// (`NV_GLOBE_HAZE_PLAN` §4). Each one's direction comes from a 2D
/// low-discrepancy sequence that does not follow rank, so any run of the
/// best (the faces) is spread all the way round, never in one cap.
///
/// Points come out inside the unit ball in the globe's own space, so the
/// same camera turn that spins the inner globe spins this one (one drag
/// turns both). A small twist from each key keeps the pattern from reading
/// as one. Worked out once per ring and pole; each frame only turns them.
/// Pure math, so the tests and the Android twin can pin it.
enum GlobeSphereField {
    /// Each point's turn round the pole is nudged by up to this, radians,
    /// from its key.
    static let twist = 0.35

    /// The point of the globe that faces you at rest: `GlobeCamera.facing`
    /// turns the core's direction to the front, so the sphere's pole is the
    /// globe-space point that same turn brings to dead centre.
    static func pole(center: String) -> SIMD3<Double> {
        let rest = GlobeCamera.facing(TrustMap.direction(of: center))
        return simd_normalize(rest.inverse.act(SIMD3(0, 0, 1)))
    }

    /// The best sit this far out (of the sphere's radius): clear of the
    /// nested inner globe, and of a nested Hop 3 inside Hop 4.
    static let innerRadius = 0.4

    /// Points in the unit ball for `keys`, best first: the first nearest
    /// the middle, the last at the edge, each shell of rank taking an equal
    /// share of the volume so the ball fills evenly.
    static func points(_ keys: [String], pole: SIMD3<Double>) -> [SIMD3<Double>] {
        let p = simd_normalize(pole)
        // Any axis not along the pole gives the two directions across it.
        let helper = abs(p.y) < 0.9 ? SIMD3<Double>(0, 1, 0) : SIMD3<Double>(1, 0, 0)
        let u = simd_normalize(simd_cross(helper, p)), v = simd_cross(p, u)
        let n = Double(max(keys.count, 1))
        // R2 sequence (plastic number): even over the sphere for any run of i.
        let g = 1.32471795724474602596
        let a1 = 1 / g, a2 = 1 / (g * g)
        let r3 = innerRadius * innerRadius * innerRadius
        return keys.enumerated().map { i, key in
            let x = Double(i)
            let c = 1 - 2 * (0.5 + x * a1).truncatingRemainder(dividingBy: 1)
            let s = max(0, 1 - c * c).squareRoot()
            let wobble = GlobeHazeField.hash(key).wobble
            let a = 2 * Double.pi * (0.5 + x * a2).truncatingRemainder(dividingBy: 1) + twist * (2 * wobble - 1)
            let rho = cbrt(r3 + (1 - r3) * (x + 0.5) / n)
            return (p * c + u * (s * cos(a)) + v * (s * sin(a))) * rho
        }
    }

    /// How far toward you a point's direction faces (0 back, 1 front),
    /// whatever its depth: a face shows on the near half of its own shell,
    /// so faces come in all round the ball, not only on its front skin.
    static func facing(_ v: SIMD3<Double>) -> Double {
        let l = simd_length(v)
        return l > 0 ? (v.z / l + 1) / 2 : 0.5
    }

    /// Which of a sphere's top (best first) keep their pictures loaded, by
    /// index, from each one's 0-1 `fronts` (Tron on PR 2526): the best
    /// `faces` that can show a face now (front at least `faceFrom`), and the
    /// best `coming` just round the rim (from `comingFrom`), so a face is
    /// ready as the sphere turns it in. Never the whole top.
    static func window(fronts: [Double], faceFrom: Double, comingFrom: Double,
                       faces: Int, coming: Int) -> [Int] {
        let shown = fronts.indices.filter { fronts[$0] >= faceFrom }.prefix(faces)
        let rim = fronts.indices.filter { fronts[$0] >= comingFrom && fronts[$0] < faceFrom }.prefix(coming)
        return Array(shown) + Array(rim)
    }

    /// How a point turned by the camera lands on screen, against the
    /// sphere's outline: `x`, `y` within -1...1 of its centre (y down), and
    /// `front` from 0 at the back to 1 at the front. Seen from `eye` radii
    /// away, so the near side is a little bigger than the far side.
    static let eye = 3.4

    static func project(_ v: SIMD3<Double>) -> (x: Double, y: Double, scale: Double, front: Double) {
        let s = eye / (eye - v.z)
        // The outline of a unit sphere `eye` away, so the edge lands on 1.
        let fit = (eye * eye - 1).squareRoot() / eye
        return (v.x * s * fit, -v.y * s * fit, s, (v.z + 1) / 2)
    }
}
