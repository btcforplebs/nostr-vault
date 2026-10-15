import Foundation
import CoreGraphics
import simd

/// The WOT globe laid flat as a network map: you at the middle, your follows
/// spread through the zone around you, the Close haze through the next zone
/// out, the outer haze through the outermost. Inside its zone a star's place
/// comes from its own direction on the globe, so the people spread evenly
/// over the whole zone (by area, not bunched on a circle) and keep the same
/// place every time.
enum GlobeFlat {
    /// One shell's zone on the disc, as fractions of the rim: everyone at
    /// distance `radius` from the core lands between `inner` and `outer`.
    struct Zone {
        let radius: Double
        let inner: Double
        let outer: Double
    }

    /// The zones, middle outward, with small gaps between them so the
    /// depth still reads. Distances between shells (the author, a star
    /// gliding in or out) blend the two zones either side.
    static let zones = [
        Zone(radius: 0, inner: 0, outer: 0),
        // Your follows are the web: they get most of the disc.
        Zone(radius: TrustMap.ringRadius, inner: 0.12, outer: 0.64),
        Zone(radius: TrustMap.closeRadius, inner: 0.68, outer: 0.83),
        Zone(radius: TrustMap.outerRadius, inner: 0.86, outer: 0.98),
        // Stars leaving the globe drift out past the rim.
        Zone(radius: TrustMap.driftOutRadius, inner: 1.15, outer: 1.25),
    ]
    /// How far apart two faces' middles stay, in sums of their radii: a
    /// little more than touching.
    static let faceRoom = 1.12
    /// The disc's rim, in disc units.
    static let rim = 1.0
    /// Inner zones sit nearer the viewer than outer ones, so faces near you
    /// draw over the haze.
    static let coreDepth = 1.6
    static let depthPerUnit = 0.9

    /// The zone for a distance from the core, blended between shells.
    static func zone(for length: Double) -> Zone {
        guard let next = zones.firstIndex(where: { $0.radius >= length }) else { return zones[zones.count - 1] }
        guard next > 0 else { return zones[0] }
        let a = zones[next - 1], b = zones[next]
        let t = (length - a.radius) / (b.radius - a.radius)
        return Zone(radius: length, inner: a.inner + (b.inner - a.inner) * t, outer: a.outer + (b.outer - a.outer) * t)
    }

    /// Where a point of the globe's space lies on the disc, turned by `yaw`.
    /// Its angle round the disc is its longitude; its height picks where
    /// across its zone it sits, evenly by area.
    static func place(_ p: SIMD3<Double>, yaw: Double) -> SIMD2<Double> {
        let length = simd_length(p)
        guard length > 1e-9 else { return .zero }
        let d = p / length
        // `TrustMap.direction` picks a longitude and an even z: the same two
        // numbers, read back, spread everyone evenly round and across.
        let angle = atan2(d.y, d.x) + yaw
        let zone = zone(for: length)
        let u = (min(1, max(-1, d.z)) + 1) / 2
        let r = (zone.inner * zone.inner + (zone.outer * zone.outer - zone.inner * zone.inner) * u).squareRoot()
        return SIMD2(cos(angle), sin(angle)) * r * rim
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
        Double(min(size.width, size.height)) / 2 * 0.96 / rim
    }

    /// How far the disc may be panned: its middle never leaves the screen.
    static func clamp(_ offset: SIMD2<Double>, in size: CGSize) -> SIMD2<Double> {
        let x = Double(size.width) / 2, y = Double(size.height) / 2
        return SIMD2(min(x, max(-x, offset.x)), min(y, max(-y, offset.y)))
    }
}
