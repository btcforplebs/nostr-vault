import Foundation
import simd

/// Where a picked hop's people sit on its sphere (Logen 2026-11-25: "a 360
/// 3d globe view of that ring", not a flat ring at the edge). Picking Hop 3
/// or Hop 4 turns that ring into a globe of its own, round your sunk inner
/// one; its people are spread over the whole surface, best first from the
/// pole that faces you when the globe is at rest, so the best scores sit
/// nearest the front and centre and the haze wraps round the back.
///
/// Points come out on the unit sphere in the globe's own space, so the same
/// camera turn that spins the inner globe spins this one (one drag turns
/// both). A Fibonacci spiral out from the pole spreads them evenly; a small
/// twist from each key keeps the spiral from reading as a pattern. Worked
/// out once per ring and pole; each frame only turns them. Pure math, so the
/// tests and the Android twin can pin it.
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

    /// Unit-sphere points for `keys`, best first: the first at the pole, the
    /// last at the far side.
    static func points(_ keys: [String], pole: SIMD3<Double>) -> [SIMD3<Double>] {
        let p = simd_normalize(pole)
        // Any axis not along the pole gives the two directions across it.
        let helper = abs(p.y) < 0.9 ? SIMD3<Double>(0, 1, 0) : SIMD3<Double>(1, 0, 0)
        let u = simd_normalize(simd_cross(helper, p)), v = simd_cross(p, u)
        let n = Double(max(keys.count, 1))
        let golden = Double.pi * (3 - 5.0.squareRoot())
        return keys.enumerated().map { i, key in
            // Equal area per point: the cosine of the angle from the pole
            // falls evenly from 1 to -1.
            let c = 1 - 2 * (Double(i) + 0.5) / n
            let s = max(0, 1 - c * c).squareRoot()
            let wobble = GlobeHazeField.hash(key).wobble
            let a = Double(i) * golden + twist * (2 * wobble - 1)
            return p * c + u * (s * cos(a)) + v * (s * sin(a))
        }
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
