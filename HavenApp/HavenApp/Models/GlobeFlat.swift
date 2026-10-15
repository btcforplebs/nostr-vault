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
        Zone(radius: TrustMap.ringRadius, inner: 0.06, outer: 0.64),
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

    /// Points per unit at zoom 1: a plane three to four screens across, so
    /// the people have real space between them and the opening view still
    /// shows most of your follows. Scaled with the faces (`k` in the scene),
    /// and never less than a few screens on a big one.
    static func unit(for size: CGSize) -> Double {
        let side = Double(min(size.width, size.height))
        return max(1_300 * min(1, side / 620), 1.6 * side)
    }

    /// How big stars and faces draw at a map zoom: they shrink as you zoom
    /// out, but less than the map does, so they stay visible.
    static func scale(atZoom zoom: Double) -> Double {
        1.25 * min(1.4, max(0.5, zoom.squareRoot()))
    }

    /// Where you are looking on the map: `offset` is where you (the middle of
    /// the network) sit, in points from the middle of the screen. A drag
    /// moves it, a flick carries on and slows, a pinch zooms about the middle
    /// of the screen, and home glides back to you.
    struct Camera: Equatable {
        var offset = SIMD2<Double>(0, 0)
        var velocity = SIMD2<Double>(0, 0)
        var zoom = 1.0
        var homing = false

        static let zoomRange = 0.3...2.5
        /// Past the network's edge you can scroll this much further.
        static let margin = 120.0
        /// How fast a flick dies away, per second.
        static let decay = 3.5
        static let maxSpeed = 5_000.0

        /// Still moving on its own: the frame clock keeps running.
        var moving: Bool { homing || velocity != .zero }

        /// How far you (the network's middle) can be from the middle of the
        /// screen, in any direction. The network is round, so the limit is
        /// too: its edge plus `margin` can come in to the screen's nearer
        /// side, and the empty corners past it stay out of reach.
        func limit(in size: CGSize) -> Double {
            let reach = rim * GlobeFlat.unit(for: size) * zoom + Self.margin
            return max(0, reach - Double(min(size.width, size.height)) / 2)
        }

        private func clamped(_ p: SIMD2<Double>, in size: CGSize) -> SIMD2<Double> {
            let l = limit(in: size), d = simd_length(p)
            return d > l ? p * (l / d) : p
        }

        mutating func pan(by d: SIMD2<Double>, in size: CGSize) {
            homing = false
            velocity = .zero
            offset = clamped(offset + d, in: size)
        }

        /// Let go at `v` points a second.
        mutating func fling(_ v: SIMD2<Double>) {
            let speed = simd_length(v)
            velocity = speed > Self.maxSpeed ? v * (Self.maxSpeed / speed) : v
        }

        /// Zoom by `factor` about the middle of the screen.
        mutating func pinch(by factor: Double, in size: CGSize) {
            homing = false
            let z = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, zoom * factor))
            offset *= z / zoom
            zoom = z
            offset = clamped(offset, in: size)
        }

        mutating func home() {
            velocity = .zero
            homing = true
        }

        mutating func step(dt: Double, in size: CGSize) {
            if homing {
                let glide = 1 - exp(-dt * 6)
                offset += (SIMD2(0, 0) - offset) * glide
                zoom += (1 - zoom) * glide
                if simd_length(offset) < 0.5, abs(zoom - 1) < 0.002 {
                    offset = .zero
                    zoom = 1
                    homing = false
                }
            } else if velocity != .zero {
                let next = offset + velocity * dt
                let held = clamped(next, in: size)
                // At the edge it slides along it: the outward part stops.
                if held != next {
                    let out = simd_normalize(held)
                    velocity -= out * max(0, simd_dot(velocity, out))
                }
                offset = held
                velocity *= exp(-dt * Self.decay)
                if simd_length(velocity) < 8 { velocity = .zero }
            }
        }
    }
}
