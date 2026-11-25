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
    /// A face's radius on the front of a fitted sphere, points: the inner
    /// globe's ring faces' size.
    static let faceSize = 11.0
    /// As many faces at once as the inner globe shows on its ring
    /// (`TrustMap.ringFaceCount`, scaled like the globe's), so the sphere
    /// reads as the same kind of globe; the rest of the top stay stars
    /// (Logen 2026-11-25: "populate photos all around it").
    static let maxFaces = TrustGlobeCanvas.faces(TrustMap.ringFaceCount)
    /// Faces show over the whole side facing you and fade toward the rim,
    /// where the inner globe's do (`GlobeEdge.faceGone`, `faceFull` as
    /// 0-1 front-ness on a unit sphere).
    static let faceFrom = (1 + GlobeEdge.faceGone) / 2
    static let faceFull = (1 + GlobeEdge.faceFull) / 2
    /// A picked sphere's radius on a phone at zoom 1, points: faces and dots
    /// are drawn their own size there and grow with a pinch.
    private static let fittedSize = 170.0
    /// Brightness steps per kind of dot, so 2,000 dots are a few fills.
    private static let levels = 16

    /// Whose profiles the picked sphere asks for: its whole top, so faces
    /// come in all the way round, the back included.
    static func pictureKeys(_ ring: TrustMapOuter.Ring) -> [String] { ring.top }

    // MARK: Picture window

    /// The picked sphere's top people who can show a face now (at most
    /// `maxFaces`) or are just coming round (at most `maxComing`)
    /// (`GlobeSphereField.window`): the canvas keeps only their pictures as
    /// symbols, so faces load as the sphere turns (Logen 2026-11-25) without
    /// holding every one on the front (Tron on PR 2526).
    private static var facing: Set<String> = []
    private static var windowSent: Set<String> = []
    private static var windowSentAt: TimeInterval = -.infinity
    /// A point counts as coming round from here (front 0 is the back).
    static let windowFrom = 0.3
    /// At most this many coming round are kept ready.
    static let maxComing = maxFaces / 2
    /// The window is sent on at most this often while the sphere turns.
    static let windowEvery: TimeInterval = 0.4

    /// The new window when it changed since the last one sent and that was
    /// long enough ago; nil otherwise.
    static func windowIfChanged(now: TimeInterval) -> [String]? {
        guard facing != windowSent, now - windowSentAt >= windowEvery else { return nil }
        windowSent = facing
        windowSentAt = now
        return Array(facing)
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
                      points: GlobeSphereField.points(ring.top + ring.haze, top: ring.top.count, pole: pole))
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

    /// Each sphere drawn last frame (picked and nested), so a path can find
    /// where someone on it is now (`screenPoint`).
    private struct Placed {
        let built: Built
        let centre: CGPoint
        let r: Double
        let turn: simd_double3x3
    }
    private static var placed: [Int: Placed] = [:]

    /// Where `key` is on screen on the hop `hop` sphere drawn last frame (any
    /// sphere when nil), with how far toward you (0 back, 1 front). Nil when
    /// they are on none.
    static func screenPoint(of key: String, hop: Int?) -> (point: CGPoint, front: Double)? {
        for (h, p) in placed where hop == nil || hop == h {
            let i = p.built.top.firstIndex(of: key) ?? p.built.haze.firstIndex(of: key).map { $0 + p.built.top.count }
            guard let i else { continue }
            let q = GlobeSphereField.project(p.turn * p.built.points[i])
            return (CGPoint(x: p.centre.x + q.x * p.r, y: p.centre.y + q.y * p.r), q.front)
        }
        return nil
    }

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
        return simd_normalize(b.points[i])
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
        facing.removeAll(keepingCapacity: true)
        placed.removeAll(keepingCapacity: true)
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
        placed[ring.hop] = Placed(built: b, centre: centre, r: r, turn: turn)
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
            Gradient(colors: [ink.haze.opacity(0.14 * shown), ink.haze.opacity(0.03 * shown)]),
            center: CGPoint(x: centre.x - r * 0.3, y: centre.y - r * 0.35), startRadius: 0, endRadius: r * 1.2))
        context.stroke(Path(ellipseIn: disc), with: .color(ink.haze.opacity(0.08 * shown)), lineWidth: 0.6)

        enum Kind: Int { case haze, top }
        var buckets = Array(repeating: Array(repeating: Path(), count: levels + 1), count: 2)
        var faces: [(key: String, at: CGPoint, r: Double, front: Double, rank: Int)] = []
        let pictures = picked > 0.3 ? pictures : []
        // A sphere nested inside a later pick steps back: smaller, fainter dots.
        let back = 0.55 + 0.45 * picked
        let topCount = b.top.count
        var tapTargets: [Target] = []
        var fronts: [Double] = []
        fronts.reserveCapacity(b.top.count)
        for (i, p) in b.points.enumerated() {
            let turned = turn * p
            let q = GlobeSphereField.project(turned), facing = GlobeSphereField.facing(turned)
            let at = CGPoint(x: centre.x + q.x * r, y: centre.y + q.y * r)
            let isTop = i < topCount
            let kind: Kind = isTop ? .top : .haze
            let a: Double, size: Double
            // The inner globe's ring stars and haze stars, at the sphere's size.
            let zoomed = min(1.8, max(0.7, r / fittedSize))
            if isTop {
                a = (0.25 + 0.65 * q.front) * shown * back
                size = 2.1 * q.scale * zoomed * back
            } else {
                a = (0.06 + 0.22 * q.front) * shown * back
                size = 1.2 * q.scale * zoomed * back
            }
            if isTop { fronts.append(facing) }
            if isTop, pictures.contains(b.top[i]), facing >= faceFrom {
                faces.append((b.top[i], at, faceSize * q.scale * zoomed, facing, i))
            }
            if isTop, picked > 0.5, facing > 0.55, clear(at, 0) { tapTargets.append(Target(key: b.top[i], at: at, reach: 14)) }
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
        if picked > 0.5 {
            facing = Set(GlobeSphereField.window(fronts: fronts, faceFrom: faceFrom, comingFrom: windowFrom,
                                                 faces: maxFaces, coming: maxComing).map { b.top[$0] })
        }
        fill(.haze, ink.haze)
        fill(.top, ink.ring)

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
            // Rolling toward the rim a face shrinks as it fades, like the globe's.
            let fr = GlobeEdge.faceRadius(face.r, shown: o / max(shown, 0.01))
            let rect = CGRect(x: face.at.x - fr, y: face.at.y - fr, width: 2 * fr, height: 2 * fr)
            guard let picture = c.resolveSymbol(id: face.key) else { continue }
            c.draw(picture, in: rect)
            c.stroke(Path(ellipseIn: rect), with: .color(ink.ring), lineWidth: max(1, fr * 0.12))
            if o > 0.5 { tapTargets.append(Target(key: face.key, at: face.at, reach: max(24, face.r + 8))) }
        }
        if picked > 0.5 { targets = tapTargets }
    }
}
