import SwiftUI
import Combine
import simd
#if canImport(UIKit)
import UIKit
#endif

/// Everything the globe draws, as flat arrays so a frame is one pass with no
/// lookups. Mutated by the frame clock; only `awake` and `faceKeys` publish.
@MainActor
final class GlobeScene: ObservableObject {
    enum Kind { case ring, mutual, haze, closeHaze, bridge, via }

    /// False once nothing moves: the frame clock stops until a touch or new data.
    @Published private(set) var awake = true
    /// Who is drawn with a picture: the core, the author, and the faces.
    @Published private(set) var faceKeys: [String] = []

    /// Pictures are drawn from a symbol this size, scaled to each face.
    static let pictureSize: CGFloat = 64
    /// Upright on a phone the globe fills the width; iPad and Mac keep their framing.
    static let isPhone: Bool = {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }()
    /// A new globe fades and glides in over this long, then holds still.
    private static let settleTime: TimeInterval = 1.8

    var camera = GlobeCamera()
    var reduceMotion = false
    private(set) var center = ""
    private(set) var hasLoaded = false
    private var author = ""
    private var me = ""
    private var bridges: [String] = []
    private var chains: [TrustMap.Chain] = []
    private var faces: [String] = []
    /// Faces that are follows on someone's own globe: drawn in the ring's colour.
    private var ringFaceSet: Set<String> = []
    /// Faces on the outer shells for the picked layer: drawn in the shell's colour.
    private var layerFaceSet: Set<String> = []
    /// With Everyone picked the shells' faces are a small, dim few that give
    /// way to your follows' faces.
    private var dimLayerFaces = false
    /// How far the shells' faces are dimmed and shrunk, easing toward
    /// `dimLayerFaces`, so a layer change doesn't pop every face's size.
    private var layerDim = 0.0
    /// Faces drawn with a picture last frame, so they keep their seat.
    private var seated: Set<String> = []
    private var direct = false
    /// Who the core follows, for a direct thread to the traced person.
    private var ring: Set<String> = []
    /// The trust card's person on the WOT tab. The globe stays on you, so they
    /// take the author's place: threads run from you through `traceBridges`.
    private var traceTarget: String?
    private var traceBridges: [String] = []
    /// The traced person and their bridges: lit whatever layer is picked.
    private var traced: Set<String> = []
    /// A traced person who had no star of their own (found by search).
    private var tracedStar: String?
    /// How brightly your follows (x), the Close shell (y) and the rest of the
    /// shell (z) are drawn, easing toward the picked layer's
    /// (`TrustMap.layerWeights`).
    private var weights = SIMD3<Double>(1, 1, 1)
    private var weightTarget = SIMD3<Double>(1, 1, 1)
    /// Who the filter icons light, easing from `filterFrom` to `filterTo`
    /// as `filterMix` runs 0 to 1. nil lights everyone.
    private var filterFrom: Set<String>?
    private var filterTo: Set<String>?
    private var filterMix = 1.0
    /// How bright someone a filter leaves out stays: still there, just back.
    private static let filteredOut = 0.08
    private static let filterFade: TimeInterval = 0.35

    private var keys: [String] = []
    private var dirs: [SIMD3<Double>] = []
    private var kinds: [Kind] = []
    private var isFace: [Bool] = []
    private var radius: [Double] = []
    private var radiusTarget: [Double] = []
    private var alpha: [Double] = []
    private var alphaTarget: [Double] = []
    private var index: [String: Int] = [:]

    private var born: TimeInterval = 0
    private var threadsBorn: TimeInterval = 0
    private var threadProgress = 1.0
    private var settling = false
    private var lastTick: TimeInterval?
    private var sleepQueued = false

    // MARK: Data

    func load(_ frame: TrustWebView.Frame, me: String, author: String, myFollows: Set<String>, haze: [String],
              closeHaze: Set<String> = [], ringFaces: [String] = [], layerFaces: [String] = [],
              layer: TrustMap.Layer = .everyone) {
        let now = Date.timeIntervalSinceReferenceDate
        let newCenter = !hasLoaded || frame.center != center
        self.me = me
        self.author = author
        center = frame.center

        // Every star's shell and look for this core. Whoever is in the middle,
        // the globe is still yours: your haze stays, and on someone else's
        // globe your follows they don't follow drift out to it. Each star keeps
        // its direction, so re-centering only glides people in or out.
        let bridgeSet = Set(frame.bridges)
        var want: [String: (Kind, Double)] = [:]
        // Close people sit on their own shell, nearer than the rest.
        func shell(close: Bool) -> (Kind, Double) {
            close ? (.closeHaze, TrustMap.closeRadius) : (.haze, TrustMap.outerRadius)
        }
        for key in haze { want[key] = shell(close: closeHaze.contains(key)) }
        // Close is who someone is, not which layer is picked: a Close face past
        // the shell's cap keeps its shell when the layer changes.
        func wasClose(_ key: String) -> Bool { index[key].map { kinds[$0] == .closeHaze } ?? false }
        if frame.center != me {
            for key in myFollows { want[key] = (.haze, TrustMap.outerRadius) }
            want[me] = (.bridge, TrustMap.outerRadius)
        }
        for key in frame.ring {
            let kind: Kind = bridgeSet.contains(key) ? .bridge
                : frame.center != me && myFollows.contains(key) ? .mutual : .ring
            want[key] = (kind, TrustMap.ringRadius)
        }
        for chain in frame.chains ?? [] where want[chain.via]?.0 != .bridge {
            want[chain.via] = (.via, TrustMap.outerRadius)
        }
        // A bridge the ring snapshot missed (the follow list changed or
        // loaded late) still gets its star and thread.
        for key in frame.bridges where want[key] == nil { want[key] = (.bridge, TrustMap.ringRadius) }
        want[author] = (.bridge, TrustMap.authorRadius)
        want[frame.center] = (.ring, 0)
        if let tracedStar, want[tracedStar] == nil { want[tracedStar] = (.bridge, TrustMap.outerRadius) }
        // A layer's face may be past the shell's cap: it still gets its star.
        if frame.center == me {
            for key in layerFaces where want[key] == nil {
                want[key] = shell(close: layer == .close || closeHaze.contains(key) || (!newCenter && wasClose(key)))
            }
        }

        for i in keys.indices where want[keys[i]] == nil {
            radiusTarget[i] = TrustMap.leavingRadius(from: radius[i], newCenter: newCenter)
            alphaTarget[i] = 0
        }
        for (key, (kind, r)) in want {
            if let i = index[key] {
                kinds[i] = kind
                radiusTarget[i] = r
                alphaTarget[i] = 1
            } else {
                index[key] = keys.count
                keys.append(key)
                dirs.append(TrustMap.direction(of: key))
                kinds.append(kind)
                isFace.append(false)
                radius.append(r)
                radiusTarget.append(r)
                alpha.append(0)
                alphaTarget.append(1)
            }
        }

        direct = frame.center != author && frame.ring.contains(author)
        ring = Set(frame.ring)
        bridges = frame.center == author ? [] : frame.bridges
        chains = frame.chains ?? []
        var shown: [String] = []
        var taken: Set<String> = [frame.center, author]
        // On someone else's globe you're one of the stars: keep your face.
        if frame.center != me, taken.insert(me).inserted { shown.append(me) }
        for key in TrustMap.spread(bridges, count: TrustGlobeCanvas.maxFaces) where taken.insert(key).inserted {
            shown.append(key)
        }
        for chain in chains.prefix(TrustMap.shownChains) {
            for key in [chain.bridge, chain.via] where taken.insert(key).inserted { shown.append(key) }
        }
        // Whoever is in the middle, their follows get the faces left over
        // from the paths, so the globe opens with pictures.
        let ringSet = Set(frame.ring)
        ringFaceSet = []
        for key in ringFaces where ringSet.contains(key) && taken.insert(key).inserted {
            shown.append(key)
            ringFaceSet.insert(key)
        }
        layerFaceSet = []
        dimLayerFaces = layer == .everyone
        if frame.center == me {
            for key in layerFaces where taken.insert(key).inserted {
                shown.append(key)
                layerFaceSet.insert(key)
            }
        }
        faces = shown
        seatFaces()

        born = now
        settling = true
        if newCenter {
            // Only a new globe draws its threads in. Moving onto someone keeps
            // them: they ride along with the stars as those glide.
            if !hasLoaded {
                threadsBorn = now
                threadProgress = reduceMotion ? 1 : 0
            }
            let target = GlobeCamera.facing(TrustMap.direction(of: frame.center == author ? frame.center : author))
            if hasLoaded {
                camera.fly(to: target, at: now)
            } else {
                // Opens already turned to show the paths.
                camera.orientation = target
                camera.touch(at: now)
            }
        }
        // A new globe opens with its faces already the right size.
        if !hasLoaded { layerDim = dimLayerFaces && filterTo == nil ? 1 : 0 }
        hasLoaded = true
        if reduceMotion { settle() }
        wake()
    }

    /// Who is drawn with a picture. While a person is traced only they and
    /// their bridges are; the rest keep their symbols for when the card closes.
    private func seatFaces() {
        var symbols = (center == author ? [author] : [center, author]) + faces
        let traced = traceTarget.map { [$0] + traceBridges } ?? []
        for key in traced where !symbols.contains(key) { symbols.append(key) }
        let pictured = Set([center] + (traceTarget == nil ? [author] + faces : traced))
        for i in keys.indices { isFace[i] = pictured.contains(keys[i]) }
        if faceKeys != symbols { faceKeys = symbols }
    }

    /// Draws the threads from the core to `key` through `bridges`, or drops
    /// them for nil. The core and the author stay where they are.
    func trace(to key: String?, through bridges: [String]) {
        let target = key == center ? nil : key
        let through = target == nil ? [] : bridges.filter { $0 != center && $0 != target }
        guard target != traceTarget || through != traceBridges else { return }
        let now = Date.timeIntervalSinceReferenceDate
        if let old = tracedStar, old != target, let i = index[old] {
            alphaTarget[i] = 0
            tracedStar = nil
        }
        if let target, index[target] == nil {
            index[target] = keys.count
            keys.append(target)
            dirs.append(TrustMap.direction(of: target))
            kinds.append(.bridge)
            isFace.append(false)
            radius.append(TrustMap.outerRadius)
            radiusTarget.append(TrustMap.outerRadius)
            alpha.append(0)
            alphaTarget.append(1)
            tracedStar = target
        }
        traceTarget = target
        traceBridges = through
        traced = target.map { Set([$0] + through) } ?? []
        seatFaces()
        // A new path draws in; closing one leaves the rest as they were.
        if target != nil {
            threadsBorn = now
            threadProgress = reduceMotion ? 1 : 0
        }
        born = now
        settling = true
        if reduceMotion { settle() }
        wake()
    }

    /// Turn toward someone tapped, before their globe has loaded.
    func turn(to key: String) {
        camera.fly(to: GlobeCamera.facing(TrustMap.direction(of: key)), at: Date.timeIntervalSinceReferenceDate)
        wake()
    }

    func reset() {
        let target = center == author ? center : author
        camera.fly(to: GlobeCamera.facing(TrustMap.direction(of: target)), at: Date.timeIntervalSinceReferenceDate)
        wake()
    }

    /// How brightly star `i` is drawn for the picked layer. The core, the
    /// author and a traced path are always lit.
    private func weight(_ i: Int) -> Double {
        if keys[i] == center || keys[i] == author || traced.contains(keys[i]) { return 1 }
        let lit = filterWeight(keys[i])
        switch kinds[i] {
        case .haze: return weights.z * lit
        case .closeHaze: return weights.y * lit
        default: return weights.x * lit
        }
    }

    private func filterWeight(_ key: String) -> Double {
        func level(_ lit: Set<String>?) -> Double { lit.map { $0.contains(key) ? 1 : Self.filteredOut } ?? 1 }
        let to = level(filterTo)
        guard filterMix < 1 else { return to }
        let from = level(filterFrom)
        return from + (to - from) * filterMix
    }

    /// Lights who the filters match and sets the rest back. Nothing is reloaded.
    func filter(_ lit: Set<String>?) {
        guard lit != filterTo else { return }
        filterFrom = filterTo
        filterTo = lit
        filterMix = reduceMotion ? 1 : 0
        wake()
    }

    /// Lights one layer and hides the rest. Nothing is reloaded.
    func focus(_ layer: TrustMap.Layer) {
        weightTarget = TrustMap.layerWeights(layer)
        if reduceMotion { weights = weightTarget }
        wake()
    }

    func wake() {
        sleepQueued = false
        if !awake {
            lastTick = nil
            awake = true
        }
    }

    // MARK: Frame clock

    func tick(now: TimeInterval) {
        let dt = lastTick.map { min(GlobeCamera.maxStep, max(0, now - $0)) } ?? 0
        lastTick = now
        camera.step(dt: dt, now: now, reduceMotion: reduceMotion)
        if filterMix < 1 {
            filterMix = min(1, filterMix + dt / Self.filterFade)
            if filterMix >= 1 { filterFrom = nil }
        }
        let dimTarget = dimLayerFaces && filterTo == nil ? 1.0 : 0
        if layerDim != dimTarget {
            layerDim += (dimTarget - layerDim) * (1 - exp(-dt * 8))
            if abs(dimTarget - layerDim) < 0.005 || reduceMotion { layerDim = dimTarget }
        }
        let fading = weights != weightTarget || filterMix < 1 || layerDim != dimTarget
        if weights != weightTarget {
            weights += (weightTarget - weights) * (1 - exp(-dt * 8))
            if simd_reduce_max(abs(weightTarget - weights)) < 0.005 { weights = weightTarget }
        }
        if settling {
            let age = now - born
            let glide = 1 - exp(-dt * 7), fade = 1 - exp(-dt * 6)
            for i in keys.indices {
                radius[i] += (radiusTarget[i] - radius[i]) * glide
                // Sweep in by direction so the shell fills like a wave, not a pop.
                if age > (dirs[i].x + 1) * 0.12 { alpha[i] += (alphaTarget[i] - alpha[i]) * fade }
            }
            threadProgress = min(1, max(0, (now - threadsBorn - 0.35) / 0.55))
            if age > Self.settleTime { settle() }
        }
        if !settling, !fading, !camera.wantsFrames(now: now, reduceMotion: reduceMotion), awake, !sleepQueued {
            // Not from inside the draw: publishing mid-update is undefined.
            sleepQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sleepQueued else { return }
                self.sleepQueued = false
                self.awake = false
            }
        }
    }

    /// Land every star where it's heading and drop the ones that faded out.
    private func settle() {
        radius = radiusTarget
        alpha = alphaTarget
        threadProgress = 1
        settling = false
        let keep = keys.indices.filter { alphaTarget[$0] > 0 }
        guard keep.count < keys.count else { return }
        keys = keep.map { keys[$0] }
        dirs = keep.map { dirs[$0] }
        kinds = keep.map { kinds[$0] }
        isFace = keep.map { isFace[$0] }
        radius = keep.map { radius[$0] }
        radiusTarget = keep.map { radiusTarget[$0] }
        alpha = keep.map { alpha[$0] }
        alphaTarget = keep.map { alphaTarget[$0] }
        index = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })
    }

    // MARK: Projection

    struct Projected {
        let point: CGPoint
        /// Toward the viewer: about −1.6 (back of the outer shell) to 1.6.
        let depth: Double
        let scale: Double
        /// 0 at the back of the globe, 1 at the front.
        var front: Double { min(1, max(0, (depth + 1.7) / 3.4)) }
    }

    /// One camera's projection, worked out once per frame.
    private struct Projector {
        let turn: simd_double3x3
        let cameraZ: Double
        let unit: Double
        let mid: CGPoint

        init(_ camera: GlobeCamera, size: CGSize) {
            turn = simd_double3x3(camera.orientation)
            cameraZ = GlobeCamera.distance / camera.zoom
            unit = GlobeCamera.unit(for: size, phone: GlobeScene.isPhone)
            mid = CGPoint(x: size.width / 2, y: size.height / 2)
        }

        func callAsFunction(_ p: SIMD3<Double>) -> Projected? {
            let v = turn * p
            let gap = cameraZ - v.z
            // Zoomed in, the outer shell passes the camera: drop what's behind the lens.
            guard gap >= 0.45 else { return nil }
            let s = 1 / gap
            return Projected(point: CGPoint(x: mid.x + v.x * s * unit, y: mid.y - v.y * s * unit),
                             depth: v.z, scale: s * cameraZ)
        }
    }

    private func position(_ key: String, _ project: Projector) -> Projected? {
        guard let i = index[key] else { return nil }
        return project(dirs[i] * radius[i])
    }

    /// Closest front-facing face to a tap, within reach of a fingertip.
    /// Zoomed in, plain stars can be tapped too.
    func hit(_ point: CGPoint, in size: CGSize) -> String? {
        let project = Projector(camera, size: size)
        var best: (key: String, distance: CGFloat)?
        func consider(_ i: Int, reach: CGFloat) {
            guard alpha[i] * min(1, weight(i)) > 0.5, let p = project(dirs[i] * radius[i]), p.depth > -0.15 else { return }
            let d = hypot(p.point.x - point.x, p.point.y - point.y)
            if d < reach, d < (best?.distance ?? .infinity) { best = (keys[i], d) }
        }
        for i in keys.indices where isFace[i] { consider(i, reach: 30) }
        if best == nil, camera.zoom >= 1.6 {
            for i in keys.indices where !isFace[i] && kinds[i] != .haze && kinds[i] != .closeHaze { consider(i, reach: 16) }
        }
        return best?.key
    }

    // MARK: Drawing

    private static let ringColor = Color(red: 0.72, green: 0.82, blue: 1)
    private static let hazeColor = Color(red: 0.62, green: 0.55, blue: 0.9)
    /// Warm amber for the threads, lighter than the glow behind them.
    private static let threadColor = Color(red: 1, green: 0.66, blue: 0.3)
    /// How bright Everyone's few faces past your follows are drawn.
    private static let dimFace = 0.55
    /// Star brightness is rounded to this many steps, so each kind of star
    /// is a handful of fills however many people there are. Fine enough that
    /// the faint haze keeps its front-to-back depth.
    private static let levels = 40

    func draw(in context: inout GraphicsContext, size: CGSize, accent: Color, name: (String) -> String) {
        guard hasLoaded, let centerIndex = index[center] else { return }
        let project = Projector(camera, size: size)
        let zoom = camera.zoom
        let k = min(1, min(size.width, size.height) / 620)
        let view = CGRect(origin: .zero, size: size).insetBy(dx: -8, dy: -8)
        guard let core = project(dirs[centerIndex] * radius[centerIndex]) else { return }
        // The trust card's person, if any, takes the author's place.
        let author = traceTarget ?? self.author
        let bridges = traceTarget == nil ? self.bridges : traceBridges
        let chains = traceTarget == nil ? self.chains : []
        let faces = traceTarget == nil ? self.faces : traceBridges
        let direct = traceTarget.map { ring.contains($0) } ?? self.direct
        let origin = project(.zero) ?? core
        let coreR = 22 * k * core.scale * min(zoom, 1.8)

        // Glow behind the core.
        context.fill(Path(ellipseIn: CGRect(x: origin.point.x - coreR * 3, y: origin.point.y - coreR * 3,
                                            width: coreR * 6, height: coreR * 6)),
                     with: .radialGradient(Gradient(colors: [accent.opacity(0.32), .clear]),
                                           center: origin.point, startRadius: 0, endRadius: coreR * 3))

        // Stars, bucketed by kind and brightness: one pass, a few fills.
        enum Slot: Int, CaseIterable { case haze, ring, mutual, hot }
        var buckets = Array(repeating: Array(repeating: Path(), count: Self.levels + 1), count: Slot.allCases.count)
        var labelled: [(key: String, at: CGPoint, r: Double, a: Double)] = []
        let namesOut = zoom > 2.2
        for i in keys.indices where !isFace[i] {
            let a = alpha[i] * weight(i)
            guard a > 0.02, let p = project(dirs[i] * radius[i]), view.contains(p.point) else { continue }
            let front = p.front
            let slot: Slot, base: Double, size: Double
            switch kinds[i] {
            case .haze: (slot, base, size) = (.haze, 0.06 + 0.16 * front, 1.2)
            // A touch brighter and bigger: close enough to tell apart in the shell.
            case .closeHaze: (slot, base, size) = (.haze, 0.10 + 0.22 * front, 1.4)
            case .ring: (slot, base, size) = (.ring, 0.25 + 0.65 * front, 2.1)
            case .mutual: (slot, base, size) = (.mutual, 0.45 + 0.55 * front, 2.4)
            case .bridge, .via: (slot, base, size) = (.hot, 0.35 + 0.65 * front, 2.8)
            }
            let level = Int((min(1, base * a) * Double(Self.levels)).rounded())
            guard level > 0 else { continue }
            let r = size * p.scale * zoom
            buckets[slot.rawValue][min(Self.levels, level)]
                .addEllipse(in: CGRect(x: p.point.x - r, y: p.point.y - r, width: 2 * r, height: 2 * r))
            if namesOut, slot != .haze, p.depth > 0.6, labelled.count < 200 {
                labelled.append((keys[i], p.point, r, a))
            }
        }
        func fill(_ slot: Slot, _ color: Color) {
            for level in 1...Self.levels where !buckets[slot.rawValue][level].isEmpty {
                context.fill(buckets[slot.rawValue][level],
                             with: .color(color.opacity(Double(level) / Double(Self.levels))))
            }
        }
        fill(.haze, Self.hazeColor)
        fill(.ring, Self.ringColor)
        fill(.mutual, .white)

        // Threads: core → bridge → author, drawn out over half a second.
        // Glow for every front thread goes in one blurred layer.
        let authorP = center == author ? nil : position(author, project)
        if let authorP {
            let t = threadProgress
            let leg1 = min(1, t * 2), leg2 = max(0, t * 2 - 1)
            var glow = Array(repeating: Path(), count: 4), dashed = Path()
            var strong = Array(repeating: Path(), count: 4), faint = Array(repeating: Path(), count: 4)
            func band(_ front: Double) -> Int { min(3, Int(front * 4)) }
            if direct {
                var p = Path()
                p.move(to: core.point)
                p.addLine(to: lerp(core.point, authorP.point, t))
                strong[3].addPath(p)
                glow[3].addPath(p)
            }
            for key in bridges {
                guard let i = index[key], alpha[i] > 0.05, let b = project(dirs[i] * radius[i]) else { continue }
                var inner = Path()
                inner.move(to: core.point)
                inner.addLine(to: lerp(core.point, b.point, leg1))
                faint[band(b.front)].addPath(inner)
                var outer = Path()
                if leg2 > 0 {
                    outer.move(to: b.point)
                    outer.addLine(to: lerp(b.point, authorP.point, leg2))
                    strong[band(b.front)].addPath(outer)
                }
                if b.front > 0.62 {
                    glow[band(b.front)].addPath(inner)
                    glow[band(b.front)].addPath(outer)
                }
            }
            if t >= 1 {
                for chain in chains {
                    guard let b = position(chain.bridge, project), let v = position(chain.via, project) else { continue }
                    dashed.move(to: core.point)
                    dashed.addLine(to: b.point)
                    dashed.addLine(to: v.point)
                    dashed.addLine(to: authorP.point)
                }
            }
            // Glow brightens toward the front, still in one blurred layer.
            func bandAlpha(_ level: Int) -> Double {
                let front = (Double(level) + 0.5) / 4
                return 0.10 + 0.75 * front * front
            }
            if glow.contains(where: { !$0.isEmpty }) {
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: 5))
                    for level in 0..<4 where !glow[level].isEmpty {
                        layer.stroke(glow[level], with: .color(accent.opacity(bandAlpha(level) * 0.6)), lineWidth: 3)
                    }
                }
            }
            for level in 0..<4 {
                let a = bandAlpha(level)
                if !faint[level].isEmpty {
                    context.stroke(faint[level], with: .color(Self.threadColor.opacity(a * 0.45)), lineWidth: 0.8)
                }
                if !strong[level].isEmpty {
                    context.stroke(strong[level], with: .color(Self.threadColor.opacity(a)), lineWidth: 1.3)
                }
            }
            if !dashed.isEmpty {
                context.stroke(dashed, with: .color(Self.threadColor.opacity(0.7)),
                               style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round, dash: [5, 4]))
            }
        }
        fill(.hot, accent)

        // Faces, back to front: bridges, chain steps and the author.
        var drawn: [(key: String, p: Projected, tint: Color, size: Double, dim: Bool)] = []
        // A filter's matches are the point of the filter, so they never dim.
        let dimLayer = dimLayerFaces && filterTo == nil
        for key in faces {
            guard let p = position(key, project) else { continue }
            if traceTarget == nil, ringFaceSet.contains(key) {
                drawn.append((key, p, Self.ringColor, 14, false))
            } else if traceTarget == nil, layerFaceSet.contains(key) {
                drawn.append((key, p, Self.hazeColor, 14 - 4 * layerDim, dimLayer))
            } else {
                drawn.append((key, p, accent, 15, false))
            }
        }
        if let authorP { drawn.append((author, authorP, .yellow, 24, false)) }
        // Faces the picked layer hides take no seat, so the lit ones get the room.
        drawn = drawn.filter { face in index[face.key].map { alpha[$0] * weight($0) > 0.02 } ?? true }
        drawn.sort { $0.p.depth < $1.p.depth }

        // Seats: a face only where it covers no other face and not the core;
        // the rest stay stars until the globe turns them some room. Dim faces
        // are seated last and hold no seat, so they never push out a bright one.
        let front = drawn.reversed().filter { $0.p.depth >= -0.1 || $0.key == author }
        let spots = (front.filter { !$0.dim } + front.filter(\.dim)).map {
            TrustMap.FaceSpot(key: $0.key, x: $0.p.point.x, y: $0.p.point.y,
                              r: $0.size * k * $0.p.scale * min(zoom, 1.8))
        }
        let dimKeys = Set(drawn.filter(\.dim).map(\.key))
        let seats = TrustMap.seatFaces(spots, always: [author], kept: seated.subtracting(dimKeys),
                                       blocked: [TrustMap.FaceSpot(key: center, x: core.point.x, y: core.point.y, r: coreR)])
        seated = seats

        // Labels: front-most first, skipping any that would cover one placed.
        // Pictures count as placed too, so a name never runs across a face.
        var placed = [CGRect(x: core.point.x - 40, y: core.point.y - coreR, width: 80, height: coreR * 2 + 22)]
            + spots.filter { seats.contains($0.key) }.map { CGRect(x: $0.x - $0.r, y: $0.y - $0.r, width: 2 * $0.r, height: 2 * $0.r) }
        var showLabel = Set<String>()
        let labelCap = zoom < 1.5 ? 9 : 40
        for face in drawn.reversed() where face.p.depth > 0.15 && !face.dim && seats.contains(face.key) && showLabel.count < labelCap {
            let r = face.size * k * face.p.scale * min(zoom, 1.8)
            let box = CGRect(x: face.p.point.x - 46, y: face.p.point.y + r + 2, width: 92, height: 16)
            if face.key == author || !placed.contains(where: { $0.intersects(box) }) {
                placed.append(box)
                showLabel.insert(face.key)
            }
        }
        for face in drawn {
            let a = min(1, alpha[index[face.key] ?? centerIndex] * weight(index[face.key] ?? centerIndex))
            let faint = layerFaceSet.contains(face.key) && traceTarget == nil ? 1 - (1 - Self.dimFace) * layerDim : 1
            let dim = (0.35 + 0.65 * face.p.front) * a * faint
            let r = face.size * k * face.p.scale * min(zoom, 1.8)
            if face.p.depth < -0.1 && face.key != author {
                // Behind the globe: a warm ember, not a face.
                let e = 3.2 * face.p.scale * zoom
                context.fill(Path(ellipseIn: CGRect(x: face.p.point.x - e, y: face.p.point.y - e, width: 2 * e, height: 2 * e)),
                             with: .color(face.tint.opacity(dim)))
                continue
            }
            if !seats.contains(face.key) {
                // No room for its picture here: a bright star in its colour.
                let e = 3.6 * face.p.scale * zoom
                context.fill(Path(ellipseIn: CGRect(x: face.p.point.x - e, y: face.p.point.y - e, width: 2 * e, height: 2 * e)),
                             with: .color(face.tint.opacity(dim)))
                continue
            }
            drawFace(&context, key: face.key, at: face.p.point, r: r, tint: face.tint, opacity: dim, name: name)
            if showLabel.contains(face.key) {
                let text = context.resolve(Text(name(face.key))
                    .font(.system(size: face.key == author ? 14 : 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9 * dim)))
                context.draw(text, at: CGPoint(x: face.p.point.x, y: face.p.point.y + r + 10))
            }
        }

        // Names on plain stars once zoomed well in, where they fit.
        if namesOut {
            for star in labelled where placed.count < 60 {
                let box = CGRect(x: star.at.x - 40, y: star.at.y + star.r + 2, width: 80, height: 13)
                guard !placed.contains(where: { $0.intersects(box) }) else { continue }
                placed.append(box)
                let text = context.resolve(Text(name(star.key)).font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.6 * star.a)))
                context.draw(text, at: CGPoint(x: star.at.x, y: star.at.y + star.r + 8))
            }
        }

        // The core last: it is always in front of its own shell.
        drawFace(&context, key: center, at: core.point, r: coreR, tint: center == me ? accent : .white,
                 opacity: 1, name: name)
        let label = context.resolve(Text(name(center)).font(.system(size: 13, weight: .bold)).foregroundColor(.white))
        context.draw(label, at: CGPoint(x: core.point.x, y: core.point.y + coreR + 11))
    }

    private func drawFace(_ context: inout GraphicsContext, key: String, at p: CGPoint, r: Double,
                          tint: Color, opacity: Double, name: (String) -> String) {
        var c = context
        c.opacity = opacity
        let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        c.fill(Path(ellipseIn: rect.insetBy(dx: -r * 0.9, dy: -r * 0.9)),
               with: .radialGradient(Gradient(colors: [tint.opacity(0.35), .clear]),
                                     center: p, startRadius: r * 0.6, endRadius: r * 1.9))
        if let picture = c.resolveSymbol(id: key) {
            c.draw(picture, in: rect)
        } else {
            // No picture yet: a colour of their own and their first initial.
            let hue = index[key].map { (dirs[$0].x + 1) / 2 } ?? 0
            c.fill(Path(ellipseIn: rect), with: .color(Color(hue: hue, saturation: 0.45, brightness: 0.62)))
            let initial = c.resolve(Text(String(name(key).prefix(1)))
                .font(.system(size: r * 0.95, weight: .bold, design: .rounded)).foregroundColor(.white))
            c.draw(initial, at: p)
        }
        c.stroke(Path(ellipseIn: rect), with: .color(tint), lineWidth: max(1.2, r * 0.12))
    }

    private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}
