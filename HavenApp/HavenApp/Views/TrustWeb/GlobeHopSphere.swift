import SwiftUI
import simd

/// Draws a picked hop as its own globe (`GlobeSphereField`, Logen
/// 2026-11-25): the ring's top 300 as bright stars, the best of them on the
/// front as faces you can tap, and its haze (`TrustRankCopy.haze`) as faint
/// dust over the rest of the surface. It turns with the inner globe's
/// camera, so one drag spins both. The inner globe stays in the middle,
/// shrunk inside it (`GlobeRingZoom.nest`), and its faces keep clear of the
/// inner globe so that stays in view and tappable. Picking a hop further
/// out nests this sphere in turn, smaller and fainter, round the inner globe.
///
/// Positions are built once per ring and pole; a frame turns ~2,000 points
/// and fills a handful of paths. Android twin (after Logen's OK):
/// `ui/components/trustweb/GlobeHopSphere.kt`.
enum GlobeHopSphere {
    /// The best of a ring that can show a picture: the canvas registers these
    /// as symbols (`pictureKeys`), the rest of the top stay stars.
    static let maxPictures = 120
    /// A face's radius on the front of a fitted sphere, points.
    static let faceSize = 11.0
    /// At most this many faces at once: the rest of the top stay stars, so
    /// the sphere reads as a globe of people, not a wall of pictures.
    static let maxFaces = 24
    /// Faces show on the part of the sphere facing you, fading in from here.
    static let faceFrom = 0.62
    static let faceFull = 0.78
    /// Brightness steps per kind of dot, so 2,000 dots are a few fills.
    private static let levels = 16

    static func pictureKeys(_ ring: TrustMapOuter.Ring) -> [String] {
        Array(ring.top.prefix(maxPictures))
    }

    // MARK: Positions

    private struct Built {
        let top: [String]
        let haze: [String]
        let pole: SIMD3<Double>
        let points: [SIMD3<Double>]
    }

    /// Which cache slot a sphere uses: its hop and its people, so the Mac's
    /// or iPad's second window on another account keeps its own.
    private struct Slot: Hashable {
        let hop: Int
        let first: String
        let count: Int
    }

    /// The canvas draws on the main thread only.
    private static var built: [Slot: Built] = [:]
    private static let maxSlots = 8

    private static func points(for ring: TrustMapOuter.Ring, pole: SIMD3<Double>) -> Built {
        let slot = Slot(hop: ring.hop, first: ring.top.first ?? "", count: ring.top.count + ring.haze.count)
        if let b = built[slot], b.pole == pole, b.top == ring.top, b.haze == ring.haze { return b }
        let b = Built(top: ring.top, haze: ring.haze, pole: pole,
                      points: GlobeSphereField.points(ring.top + ring.haze, pole: pole))
        if built.count >= maxSlots { built.removeAll(keepingCapacity: true) }
        built[slot] = b
        return b
    }

    // MARK: Taps

    /// Where last frame's faces and front stars landed, for `hit`.
    private struct Target {
        let key: String
        let at: CGPoint
        let reach: Double
    }

    private static var targets: [Target] = []
    /// The nested inner globe's disc on screen last frame: the sphere seats
    /// no face and takes no tap there, so the globe's own faces stay
    /// reachable (`TrustGlobeCanvas` asks the globe first inside it).
    private static var hole: (centre: CGPoint, r: Double)?

    /// Whether a tap lands on the nested inner globe.
    static func inHole(_ point: CGPoint) -> Bool {
        guard let hole else { return false }
        return hypot(Double(point.x - hole.centre.x), Double(point.y - hole.centre.y)) < hole.r
    }
    /// The picked sphere last drawn, so a tapped person can be turned to.
    private static var lastPicked: Built?

    /// Where `key` sits on the picked sphere, in the globe's own space: the
    /// globe turns this to the front when their trust card opens, instead
    /// of to their spot on the inner globe. Nil when they are not on it.
    static func direction(of key: String) -> SIMD3<Double>? {
        guard let b = lastPicked, let i = b.top.firstIndex(of: key) else { return nil }
        return b.points[i]
    }
    /// Who held a face last frame: they keep it while they still fit, so
    /// faces do not swap as the sphere turns.
    private static var seated: Set<String> = []

    /// The face (or, failing that, front star) of the picked sphere under a
    /// tap, from the frame last drawn. Nil when nothing is near, or no hop
    /// sphere is up.
    static func hit(_ point: CGPoint) -> String? {
        var best: (key: String, d: Double)?
        for t in targets {
            let d = hypot(Double(t.at.x - point.x), Double(t.at.y - point.y))
            if d < t.reach, d < (best?.d ?? .infinity) { best = (t.key, d) }
        }
        return best?.key
    }

    /// Clears the tap targets: no sphere is up this frame.
    static func clearTargets() {
        targets.removeAll(keepingCapacity: true)
        lastPicked = nil
        hole = nil
    }

    // MARK: Drawing

    /// Draws `ring` as a sphere of radius `r` round `centre`. `shown` is how
    /// strongly (its ring fade times its sphere share), `picked` how much it
    /// is the picked hop: only then do faces show and taps land. `focus` is
    /// the trust card's person: the globe turns them to the front, and their
    /// face always takes a seat there. `hole` is the nested inner globe's
    /// disc: no face is seated and no star tapped inside it.
    static func draw(_ ring: TrustMapOuter.Ring, centre: CGPoint, r: Double, shown: Double, picked: Double,
                     turn: simd_double3x3, pole: SIMD3<Double>, pictures: Set<String>,
                     focus: String? = nil, hole: (centre: CGPoint, r: Double)? = nil,
                     in context: inout GraphicsContext, ink: GlobeInk) {
        guard shown > 0.01, r > 4, !(ring.top.isEmpty && ring.haze.isEmpty) else { return }
        let b = points(for: ring, pole: pole)
        if picked > 0.5 {
            lastPicked = b
            self.hole = hole
        }
        func clear(_ p: CGPoint, _ pad: Double) -> Bool {
            guard let hole else { return true }
            return hypot(Double(p.x - hole.centre.x), Double(p.y - hole.centre.y)) >= hole.r + pad
        }
        // The body: a faint glass ball, lit a little up and to the left, and
        // its outline, so it reads as a globe before its dots do.
        let disc = CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r)
        context.fill(Path(ellipseIn: disc), with: .radialGradient(
            Gradient(colors: [ink.haze.opacity(0.10 * shown), ink.haze.opacity(0.02 * shown)]),
            center: CGPoint(x: centre.x - r * 0.3, y: centre.y - r * 0.35), startRadius: 0, endRadius: r * 1.2))
        context.stroke(Path(ellipseIn: disc), with: .color(ink.haze.opacity(0.22 * shown)), lineWidth: 0.8)

        enum Kind: Int { case haze, top }
        var buckets = Array(repeating: Array(repeating: Path(), count: levels + 1), count: 2)
        var faces: [(key: String, at: CGPoint, r: Double, front: Double, rank: Int)] = []
        let pictures = picked > 0.3 ? pictures : []
        // A sphere nested inside a later pick steps back: smaller, fainter dots.
        let back = 0.55 + 0.45 * picked
        let topCount = b.top.count
        var tapTargets: [Target] = []
        for (i, p) in b.points.enumerated() {
            let q = GlobeSphereField.project(turn * p)
            let at = CGPoint(x: centre.x + q.x * r, y: centre.y + q.y * r)
            let isTop = i < topCount
            let kind: Kind = isTop ? .top : .haze
            let a: Double, size: Double
            if isTop {
                a = (0.22 + 0.78 * q.front * q.front) * shown * back
                size = (1.1 + 1.3 * q.front) * q.scale * back
            } else {
                a = (0.08 + 0.42 * q.front * q.front) * shown * back
                size = (0.7 + 0.6 * q.front) * q.scale * back
            }
            if isTop, pictures.contains(b.top[i]), q.front >= faceFrom {
                faces.append((b.top[i], at, faceSize * q.scale * min(1, r / 160), q.front, i))
            }
            if isTop, picked > 0.5, q.front > 0.55, clear(at, 0) { tapTargets.append(Target(key: b.top[i], at: at, reach: 14)) }
            let level = Int((min(1, a) * Double(levels)).rounded())
            guard level > 0 else { continue }
            buckets[kind.rawValue][min(levels, level)]
                .addEllipse(in: CGRect(x: at.x - size, y: at.y - size, width: 2 * size, height: 2 * size))
        }
        func fill(_ kind: Kind, _ color: Color) {
            for level in 1...levels where !buckets[kind.rawValue][level].isEmpty {
                context.fill(buckets[kind.rawValue][level], with: .color(color.opacity(Double(level) / Double(levels))))
            }
        }
        fill(.haze, ink.haze)
        fill(.top, ink.star)

        guard picked > 0.3, !faces.isEmpty else {
            if picked > 0.5 { targets = tapTargets }
            return
        }
        let rank = Dictionary(faces.map { ($0.key, $0.rank) }, uniquingKeysWith: min)
        // Front-most first, so the nearest win a seat; no face covers another.
        faces.sort { $0.front > $1.front }
        let spots = faces.map { TrustMap.FaceSpot(key: $0.key, x: $0.at.x, y: $0.at.y, r: $0.r) }
        // The best-ranked of those that fit keep a face, up to `maxFaces`.
        let always: Set<String> = focus.map { [$0] } ?? []
        let blocked = hole.map { [TrustMap.FaceSpot(key: "", x: $0.centre.x, y: $0.centre.y, r: $0.r)] } ?? []
        let seats = Set(Array(TrustMap.seatFaces(spots, always: always, kept: seated, blocked: blocked)).sorted {
            always.contains($0) != always.contains($1) ? always.contains($0) : (rank[$0] ?? .max) < (rank[$1] ?? .max)
        }.prefix(maxFaces))
        seated = seats
        for face in faces.reversed() where seats.contains(face.key) {
            let o = GlobeEdge.smoothstep(faceFrom, faceFull, face.front) * min(1, (picked - 0.3) / 0.5) * shown
            guard o > 0.01 else { continue }
            var c = context
            c.opacity = o
            let rect = CGRect(x: face.at.x - face.r, y: face.at.y - face.r, width: 2 * face.r, height: 2 * face.r)
            guard let picture = c.resolveSymbol(id: face.key) else { continue }
            c.draw(picture, in: rect)
            c.stroke(Path(ellipseIn: rect), with: .color(ink.ring), lineWidth: max(1, face.r * 0.12))
            if o > 0.5 { tapTargets.append(Target(key: face.key, at: face.at, reach: max(24, face.r + 8))) }
        }
        if picked > 0.5 { targets = tapTargets }
    }
}
