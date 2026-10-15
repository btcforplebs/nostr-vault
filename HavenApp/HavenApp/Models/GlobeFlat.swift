import Foundation
import CoreGraphics
import simd

/// The WOT globe laid flat, like a flat-earth map: you at the middle and each
/// shell a ring around you, your follows first, then the Close haze, then the
/// outer haze. A shell is a band, not a line: how far north a star sits on the
/// globe spreads it a little in or out across its ring, so a crowded shell
/// still reads as people rather than a drawn circle.
enum GlobeFlat {
    /// How far a shell's band spreads either side of its radius. Kept under
    /// the gap between shells, so the rings stay apart.
    static let bandSpread = 0.10
    /// The disc's rim, in the globe's units: just past the outer band.
    static var rim: Double { TrustMap.outerRadius * (1 + bandSpread) + 0.1 }
    /// Inner rings sit nearer the viewer than outer ones, so faces on your
    /// follows' ring draw over the haze.
    static let coreDepth = 1.6
    static let depthPerUnit = 0.9

    /// Where a point of the globe's space lies on the disc, turned by `yaw`.
    /// Its angle round the disc is its longitude; its distance from the
    /// middle is its distance from the core, nudged by its latitude.
    static func place(_ p: SIMD3<Double>, yaw: Double) -> SIMD2<Double> {
        let length = simd_length(p)
        guard length > 1e-9 else { return .zero }
        let d = p / length
        let angle = atan2(d.z, d.x) + yaw
        let r = length * (1 + bandSpread * d.y)
        return SIMD2(cos(angle), sin(angle)) * r
    }

    /// How far round the globe has turned about its axis: the disc turns
    /// with it, so the idle drift spins the disc. Tilt is ignored.
    static func yaw(of turn: simd_double3x3) -> Double {
        let x = turn * SIMD3<Double>(1, 0, 0)
        return atan2(x.z, x.x)
    }

    /// Depth for drawing order and brightness: the middle is nearest.
    static func depth(_ p: SIMD3<Double>) -> Double {
        max(0.05, coreDepth - simd_length(p) * depthPerUnit)
    }

    /// Points per unit at zoom 1: the rim sits just inside the shorter side.
    static func unit(for size: CGSize) -> Double {
        Double(min(size.width, size.height)) / 2 * 0.94 / rim
    }

    /// How far the disc may be panned: its middle never leaves the screen.
    static func clamp(_ offset: SIMD2<Double>, in size: CGSize) -> SIMD2<Double> {
        let x = Double(size.width) / 2, y = Double(size.height) / 2
        return SIMD2(min(x, max(-x, offset.x)), min(y, max(-y, offset.y)))
    }
}
