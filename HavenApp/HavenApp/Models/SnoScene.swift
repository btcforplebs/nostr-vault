import Foundation
import simd

/// An `SnoObject` turned to a viewing angle and flattened to what a 2D canvas
/// draws, back to front.
///
/// No 3D engine: the objects are tens to a few thousand flat-coloured
/// triangles, so a painter's sort on the CPU draws them in one `Canvas` pass,
/// the way the trust globe is drawn. Kept free of SwiftUI so it can be tested.
struct SnoScene {
    enum Primitive: Equatable {
        case triangle(SIMD2<Double>, SIMD2<Double>, SIMD2<Double>, SnoObject.RGB)
        case line(SIMD2<Double>, SIMD2<Double>, SnoObject.RGB, SnoObject.RGB)
        case point(SIMD2<Double>, SnoObject.RGB)
        /// Where a placed object (§1.10) would stand. We do not fetch it.
        case placeholder(SIMD2<Double>, radius: Double)
    }

    let object: SnoObject
    /// Centre of the object's bounds, and the radius of the sphere around it
    /// that every vertex sits in. Fitting the sphere rather than the box keeps
    /// the object the same size as it turns.
    let center: SIMD3<Double>
    let radius: Double
    /// Edges drawn in `lines` mode, each once (§1.5).
    let edges: [SIMD2<Int>]

    init(_ object: SnoObject) {
        self.object = object
        let points = object.positions + object.parts.map(\.at)
        if let first = points.first {
            var lo = first, hi = first
            for p in points { lo = pointwiseMin(lo, p); hi = pointwiseMax(hi, p) }
            center = (lo + hi) / 2
            let c = center
            radius = max(points.map { simd_length($0 - c) }.max() ?? 0, 0.5)
        } else {
            center = .zero
            radius = 1
        }
        if object.mode == .lines {
            if object.faces.isEmpty {
                // No faces: one polyline through the vertices in order.
                edges = object.positions.indices.dropFirst().map { SIMD2($0 - 1, $0) }
            } else {
                var seen = Set<SIMD2<Int>>()
                var list: [SIMD2<Int>] = []
                for f in object.faces {
                    for (a, b) in [(f.x, f.y), (f.y, f.z), (f.z, f.x)] {
                        let key = SIMD2(min(a, b), max(a, b))
                        if seen.insert(key).inserted { list.append(key) }
                    }
                }
                edges = list
            }
        } else {
            edges = []
        }
    }

    /// Light comes from above, a little to the left and toward the viewer, in
    /// view space, so the side facing you is the lit one at every angle.
    private static let light = simd_normalize(SIMD3(-0.35, 0.75, 0.55))

    /// The object turned by `yaw` about Y then tilted by `pitch` about X
    /// (radians), fitted into a `size` square, as primitives to draw in order.
    func primitives(yaw: Double, pitch: Double, size: Double) -> [Primitive] {
        let cy = cos(yaw), sy = sin(yaw), cp = cos(pitch), sp = sin(pitch)
        func turn(_ p: SIMD3<Double>) -> SIMD3<Double> {
            let x1 = p.x * cy + p.z * sy, z1 = -p.x * sy + p.z * cy
            return SIMD3(x1, p.y * cp - z1 * sp, p.y * sp + z1 * cp)
        }
        let scale = size * 0.46 / radius
        // A gentle perspective: the camera sits four radii back.
        let eye = radius * 4
        func project(_ v: SIMD3<Double>) -> SIMD2<Double> {
            let f = eye / (eye - v.z)
            return SIMD2(size / 2 + v.x * scale * f, size / 2 - v.y * scale * f)
        }
        let turned = object.positions.map { turn($0 - center) }
        let screen = turned.map(project)

        var drawn: [(depth: Double, primitive: Primitive)] = []
        switch object.mode {
        case .solid:
            drawn.reserveCapacity(object.faces.count + turned.count)
            for (i, f) in object.faces.enumerated() {
                let a = turned[f.x], b = turned[f.y], c = turned[f.z]
                // §4: flat normals from the face's own winding; both sides are
                // drawn, the back a little darker.
                let n = simd_cross(b - a, c - a)
                let length = simd_length(n)
                var shade = 0.62
                if length > 0 {
                    let unit = n / length
                    let facing = unit.z >= 0
                    let lambert = abs(simd_dot(unit, Self.light))
                    shade = (0.42 + 0.58 * lambert) * (facing ? 1 : 0.78)
                }
                let base = object.faceColors?[i] ?? Self.mean(object.colors[f.x], object.colors[f.y], object.colors[f.z])
                drawn.append(((a.z + b.z + c.z) / 3,
                              .triangle(screen[f.x], screen[f.y], screen[f.z], Self.shaded(base, shade))))
            }
            // §1.5: points in every mode, so an object smaller than a triangle
            // still shows. Sorted in with the faces, a hidden vertex stays hidden.
            for i in turned.indices {
                drawn.append((turned[i].z + radius * 0.002, .point(screen[i], object.colors[i])))
            }
        case .lines:
            for e in edges {
                drawn.append(((turned[e.x].z + turned[e.y].z) / 2,
                              .line(screen[e.x], screen[e.y], object.colors[e.x], object.colors[e.y])))
            }
            for i in turned.indices { drawn.append((turned[i].z, .point(screen[i], object.colors[i]))) }
        case .points:
            for i in turned.indices { drawn.append((turned[i].z, .point(screen[i], object.colors[i]))) }
        }
        for part in object.parts {
            let t = turn(part.at - center)
            drawn.append((t.z, .placeholder(project(t), radius: max(scale * 0.5, 3))))
        }
        // Far first. Stable, so equal depths keep the payload's order.
        let order = drawn.indices.sorted { drawn[$0].depth < drawn[$1].depth || (drawn[$0].depth == drawn[$1].depth && $0 < $1) }
        return order.map { drawn[$0].primitive }
    }

    /// A face with no colour of its own takes its corners' mean. §1.3 asks for
    /// interpolation across the face; a 2D canvas fills a triangle with one
    /// colour, and for the blocky objects this format is used for the corners
    /// almost always agree.
    static func mean(_ a: SnoObject.RGB, _ b: SnoObject.RGB, _ c: SnoObject.RGB) -> SnoObject.RGB {
        SnoObject.RGB(r: UInt8((Int(a.r) + Int(b.r) + Int(c.r)) / 3),
                      g: UInt8((Int(a.g) + Int(b.g) + Int(c.g)) / 3),
                      b: UInt8((Int(a.b) + Int(b.b) + Int(c.b)) / 3))
    }

    static func shaded(_ c: SnoObject.RGB, _ k: Double) -> SnoObject.RGB {
        func ch(_ v: UInt8) -> UInt8 { UInt8(min(255, (Double(v) * k).rounded())) }
        return SnoObject.RGB(r: ch(c.r), g: ch(c.g), b: ch(c.b))
    }
}
