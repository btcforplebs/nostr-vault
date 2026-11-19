import SwiftUI
import Combine
import simd

extension TrustWebView {
    // MARK: - Live arcs

    /// The bar's switch for live stars, like the feed's Auto-load; My Web
    /// has it again with the other two (`LiveStarsSwitches`).
    var liveArcsButton: some View { LiveArcsToggle() }
}

private struct LiveArcsToggle: View {
    @AppStorage(LiveArcsSetting.key) private var on = LiveArcsSetting.defaultOn

    var body: some View {
        IconFilterButton(icon: "antenna.radiowaves.left.and.right", tooltip: "Live stars",
                         isSelected: on, color: .havenPurple) { on.toggle() }
            .accessibilityLabel(Text("Live stars"))
            .accessibilityValue(Text(on ? "On" : "Off"))
            .accessibilityHint(Text("A star flies across the globe for each new note in your web"))
            .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Your web's activity as globe arrivals (RESEARCH/NV_GLOBE_STARS_FINAL.md,
/// Logen 2026-11-19): one REQ on each of your read relays asks for your
/// follows' and, with Friends of friends on, your friends of friends' notes
/// by author, plus zap receipts. The gate (`GlobeArcs.ring`) is the one hop
/// check: whoever it doesn't place inside your web flies only a zap, and is
/// never drawn red. Every REQ rides the feed's own open connection to its
/// relay (`GlobeRelayLink`): the globe opens no connections of its own.
@MainActor
final class GlobeArrivalStream: ObservableObject {
    let arrived = PassthroughSubject<GlobeArcs.Arrival, Never>()
    /// Which start the open connections belong to, so a late stop from an
    /// earlier one leaves a newer one running.
    private var generation = 0
    private var links: [GlobeRelayLink] = []
    #if DEBUG
    private var stub: Task<Void, Never>?
    /// Arrivals per minute, for the globe's debug readout.
    @Published private(set) var perMinute = 0
    private var meter = GlobeArcs.RateMeter()
    private var meterTick: Timer?
    #endif

    /// Most authors one filter names.
    private static let authorsPerFilter = 500

    /// Opens the REQs `show` asks for; returns the token that stops them.
    @discardableResult
    func start(me: String, show: GlobeArcs.Show = .init()) -> Int {
        stop()
        generation += 1
        #if DEBUG
        meterTick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let rate = self.meter.perMinute(at: Date.timeIntervalSinceReferenceDate)
                if rate != self.perMinute { self.perMinute = rate }
            }
        }
        // For looking at the arcs without anyone posting: made-up notes from
        // people on the globe. Nothing is published.
        // `-GlobeArcsStorm <per second>`: a stress feed, that many a second.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-GlobeArcsStub") || arguments.contains("-GlobeArcsStorm") {
            stub = Task { [weak self] in await self?.runStub(me: me) }
            return generation
        }
        #endif
        let feed = FeedService.shared
        let follows = Set(feed.followedPubkeys.map { $0.lowercased() }).union([me.lowercased()])
        let web = feed.feedGate
        let filters = GlobeArcs.storm(show: show,
                                      authors: GlobeArcs.askedAuthors(follows: follows, web: web.web, friends: show.friends),
                                      since: Int(Date().timeIntervalSince1970), authorsPerFilter: Self.authorsPerFilter)
        for url in feed.externalRelayURLs {
            links.append(GlobeRelayLink(url: url, filters: filters) { [weak self] event in
                // A zap's request must be signed by its zapper.
                guard var arrival = GlobeArcs.arrival(event, verifyZap: NostrEventVerifier.isValid(json:)) else { return }
                // Judged on the gate as it is now, so a block, a mute or a new
                // follow counts at once.
                guard let ring = GlobeArcs.ring(of: arrival, event: event, in: FeedService.shared.feedGate,
                                                follows: follows, show: show) else { return }
                arrival.ring = ring
                self?.emit(arrival)
            })
        }
        return generation
    }

    /// Closes the connections, unless `token` is from an earlier start.
    /// True when they were closed.
    @discardableResult
    func stop(_ token: Int? = nil) -> Bool {
        if let token, token != generation { return false }
        links.forEach { $0.close() }
        links = []
        #if DEBUG
        stub?.cancel()
        stub = nil
        meterTick?.invalidate()
        meterTick = nil
        #endif
        return true
    }

    /// Every arrival goes out through here.
    private func emit(_ arrival: GlobeArcs.Arrival) {
        #if DEBUG
        meter.record(arrival.id, at: Date.timeIntervalSinceReferenceDate)
        #endif
        arrived.send(arrival)
    }

    #if DEBUG
    private func runStub(me: String) async {
        let storm = UserDefaults.standard.integer(forKey: "GlobeArcsStorm")
        // Real authors from the feed; the lines they draw are made up.
        let feedNotes = FeedService.shared.notes.filter { $0.kind == 1 }
        let people = Array(Set(FeedService.shared.followedPubkeys + feedNotes.map(\.pubkey)
                               + FeedService.shared.extendedNetworkPubkeys.prefix(400)).shuffled().prefix(storm > 0 ? 600 : 80))
        guard people.count > 4 else { return }
        var n = 0
        // A storm comes in tenths of a second, a tenth of its rate each.
        let burst = max(1, storm / 10)
        while !Task.isCancelled {
            for _ in 0..<(storm > 0 ? burst : 1) {
                n += 1
                let real = feedNotes.randomElement()
                let author = real?.pubkey ?? people.randomElement()!
                // Mostly notes to you; some replies to a few people; some to no one.
                let targets: [String]
                switch n % 5 {
                case 0, 2: targets = [me]
                case 1: targets = Array(people.filter { $0 != author }.shuffled().prefix(Int.random(in: 2...3)))
                case 3: targets = [people.filter { $0 != author }.randomElement()!]
                default: targets = []
                }
                let id = (0..<4).map { _ in String(format: "%016llx", UInt64.random(in: 0...UInt64.max)) }.joined()
                // Every third one a zap, to someone: a bolt rather than a star.
                // Every fourth a reaction: a smaller star, to one person.
                // A storm is mostly notes and reactions, as the network is.
                let zap = storm > 0 ? n % 25 == 0 : n % 3 == 0
                let reaction = !zap && (storm > 0 ? n % 3 == 0 : n % 4 == 0)
                // Follows and friends of friends in turn; only a zap comes from outside.
                let ring: GlobeArcs.Ring = zap && n % 2 == 0 ? .outside : n % 2 == 0 ? .following : .friends
                let zapped = targets.first ?? people.filter { $0 != author }.randomElement()!
                emit(GlobeArcs.Arrival(id: id, author: author, targets: zap || reaction ? [zapped] : targets, ring: ring,
                                       zap: zap, sort: zap ? .zap : reaction ? .reaction : .note,
                                       strength: GlobeArcs.zapStrength(sats: [21, 1_000, 21_000, 100_000].randomElement()!)))
            }
            try? await Task.sleep(for: storm > 0 ? .milliseconds(100) : .milliseconds(Int.random(in: 900...2000)))
        }
    }
    #endif
}

/// Draws the live arcs for one frame. The globe hands it where everyone is
/// and draws the faces itself, so the arcs never reach into its arrays.
struct LiveArcsPainter {
    let board: GlobeArcs.Board
    let now: TimeInterval
    let reduceMotion: Bool
    /// The core: a line can end on it, but it never gets a second face.
    let center: String
    /// The globe's scale for this screen, and the camera's zoom.
    let k: Double
    let zoom: Double
    /// Toward the viewer, in the globe's own space.
    let facing: SIMD3<Double>
    let project: (SIMD3<Double>) -> GlobeScene.Projected?
    /// Where someone sits on the globe; with a feed, where a star from them
    /// on that feed sets out.
    let place: (String, GlobeArcs.Ring?) -> SIMD3<Double>
    /// Night or day colours, from the globe.
    var ink: GlobeInk = .night

    /// Every arrival is a small star in the globe's own star colour.
    var starColor: Color { ink.star }
    /// A reaction's star beside a note's.
    static let reactionSize = 0.6
    /// Steps in a star's tail, each a little fainter and thinner than the last.
    private static let tailSteps = 8

    /// Paths gathered by how they're drawn: everything at one opacity step
    /// and width is one fill or stroke, so a storm of hundreds of lines
    /// costs a few dozen draws, not thousands (`GlobeArcs.band`).
    private struct Batch {
        var paths: [Int: Path] = [:]
        mutating func add(_ key: Int, _ build: (inout Path) -> Void) { build(&paths[key, default: Path()]) }
    }

    /// Size steps: a note's star, and a reaction's smaller one.
    private static func sizeIndex(_ line: GlobeArcs.Line) -> Int { line.sort == .reaction ? 1 : 0 }
    private static func size(_ index: Int) -> Double { index == 1 ? reactionSize : 1 }

    private static func disc(_ path: inout Path, at p: CGPoint, r: Double) {
        path.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
    }

    /// Shooting stars, their faint trails, and the lights where they land:
    /// over the stars and threads, under the faces.
    func drawLines(_ context: inout GraphicsContext) {
        draw(board.lines, in: &context, color: starColor, samples: GlobeArcs.arcSamples(lines: board.lines.count))
    }

    private func draw(_ lines: [GlobeArcs.Line], in context: inout GraphicsContext, color: Color, samples: Int) {
        let unit = max(0.8, k)
        // Lights breathe slowly while they stay.
        let breath = reduceMotion ? 1 : 0.82 + 0.18 * sin(now * 2 * .pi / 2.6)
        var trails = Batch(), tails = Batch(), cores = Batch(), glows = Batch(), rings = Batch()
        var bolts: [GlobeBoltPainter.Shape] = []
        for line in lines {
            let stage = GlobeArcs.stage(of: line, at: now, reduceMotion: reduceMotion)
            guard stage.alpha > 0.01 else { continue }
            let a = place(line.from, line.ring), b = place(line.to, nil)
            func at(_ t: Double) -> GlobeScene.Projected? {
                project(GlobeArcs.point(from: a, to: b, at: t, facing: facing))
            }
            // A zap is a lightning bolt, not a star.
            if line.zap {
                if let bolt = GlobeBoltPainter.shape(of: line, stage: stage, now: now, reduceMotion: reduceMotion, at: at) {
                    bolts.append(bolt)
                }
                continue
            }
            // The faint trail it leaves, gone soon after it lands.
            let trailBand = GlobeArcs.band(stage.trail)
            if trailBand > 0 {
                trails.add(trailBand) { path in
                    var open = false
                    for s in 0...samples {
                        guard let p = at(stage.head * Double(s) / Double(samples)) else { open = false; continue }
                        if open { path.addLine(to: p.point) } else { path.move(to: p.point); open = true }
                    }
                }
            }
            // A reaction's star, tail and landing are smaller than a note's.
            let sizeIndex = Self.sizeIndex(line), size = Self.size(sizeIndex)
            // In flight: the star and its short tail, brightest at the star.
            if stage.head < 1, let head = at(stage.head) {
                // Round the back a star dims smoothly, never switches.
                let behind = GlobeEdge.arc(depth: head.depth)
                let start = max(0, stage.head - GlobeArcs.tailLength)
                var last = at(start)?.point
                for step in 1...Self.tailSteps {
                    let t = start + (stage.head - start) * Double(step) / Double(Self.tailSteps)
                    guard let p = at(t) else { last = nil; continue }
                    let f = Double(step) / Double(Self.tailSteps)
                    let band = GlobeArcs.band(f * f * stage.alpha * behind)
                    if let last, band > 0 {
                        tails.add((band * 16 + step) * 2 + sizeIndex) { path in
                            path.move(to: last)
                            path.addLine(to: p.point)
                        }
                    }
                    last = p.point
                }
                let band = GlobeArcs.band(stage.alpha * behind)
                if band > 0 {
                    let r = 1.8 * size * unit
                    cores.add(band * 2 + sizeIndex) { Self.disc(&$0, at: head.point, r: r) }
                    glows.add(band * 2 + sizeIndex) { Self.disc(&$0, at: head.point, r: 2 * r) }
                }
            }
            // Where it lands: a small ring opens once, then a light stays and breathes.
            if stage.landing > 0, let p = project(b) {
                let ringBand = GlobeArcs.band(0.5 * (1 - stage.landing) * stage.alpha)
                if ringBand > 0 {
                    rings.add(ringBand) { Self.disc(&$0, at: p.point, r: (5 + 14 * stage.landing) * size * unit) }
                }
                let band = GlobeArcs.band(0.7 * stage.alpha * breath)
                if band > 0 {
                    let r = 1.8 * size * unit
                    cores.add(band * 2 + sizeIndex) { Self.disc(&$0, at: p.point, r: r) }
                    glows.add(band * 2 + sizeIndex) { Self.disc(&$0, at: p.point, r: 2 * r) }
                }
            }
        }
        for (band, path) in trails.paths {
            context.stroke(path, with: .color(color.opacity(0.14 * GlobeArcs.bandAlpha(band))),
                           style: StrokeStyle(lineWidth: 0.8, lineCap: .round, lineJoin: .round))
        }
        func tailWidth(_ key: Int) -> Double {
            let step = (key / 2) % 16
            return (0.4 + 1.4 * Double(step) / Double(Self.tailSteps)) * Self.size(key % 2)
        }
        if !tails.paths.isEmpty || !glows.paths.isEmpty {
            // Every glow, tails' and stars', in one blurred layer.
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 2.5))
                for (key, path) in tails.paths {
                    layer.stroke(path, with: .color(color.opacity(0.5 * GlobeArcs.bandAlpha(key / 32))),
                                 lineWidth: tailWidth(key) + 2)
                }
                for (key, path) in glows.paths {
                    layer.fill(path, with: .color(color.opacity(0.5 * GlobeArcs.bandAlpha(key / 2))))
                }
            }
        }
        for (key, path) in tails.paths {
            context.stroke(path, with: .color(color.opacity(0.9 * GlobeArcs.bandAlpha(key / 32))),
                           style: StrokeStyle(lineWidth: tailWidth(key), lineCap: .round))
        }
        for (key, path) in cores.paths {
            context.fill(path, with: .color(color.opacity(GlobeArcs.bandAlpha(key / 2))))
        }
        for (band, path) in rings.paths {
            context.stroke(path, with: .color(color.opacity(GlobeArcs.bandAlpha(band))), lineWidth: 1)
        }
        // Bolts over the stars: a zap should flash brighter than a note.
        GlobeBoltPainter.draw(bolts, in: &context, unit: unit, core: ink.boltCore)
    }

    /// Pictures at the ends of the lines, easing in as a star sets out and
    /// out as its light fades. Someone already seated as a face keeps their seat.
    /// Only `pictured` get a face: in a storm, the ends of the newest lines.
    func drawFaces(_ context: inout GraphicsContext, seated: Set<String>, pictured: Set<String>,
                   face: (inout GraphicsContext, String, CGPoint, Double, Color, Double) -> Void) {
        var shown: [String: Double] = [:]
        var setsOut: [String: GlobeArcs.Ring] = [:]
        for line in board.lines where pictured.contains(line.from) || pictured.contains(line.to) {
            let a = GlobeArcs.faceAlpha(of: line, at: now)
            for key in [line.from, line.to] where a > (shown[key] ?? 0) { shown[key] = a }
            if setsOut[line.from] == nil { setsOut[line.from] = line.ring }
        }
        // A face rolling toward the rim fades and shrinks rather than popping.
        let faces = shown.compactMap { key, alpha -> (String, GlobeScene.Projected, Double, Double)? in
            guard key != center, !seated.contains(key), pictured.contains(key), alpha > 0.02,
                  let p = project(place(key, setsOut[key])) else { return nil }
            let edge = GlobeEdge.face(depth: p.depth)
            return edge > 0.02 ? (key, p, alpha, edge) : nil
        }.sorted { $0.1.depth < $1.1.depth }
        for (key, p, a, edge) in faces {
            let r = GlobeEdge.faceRadius(13 * k * p.scale * min(zoom, 1.8), shown: edge)
            face(&context, key, p.point, r, starColor.opacity(0.85), a * edge * (0.4 + 0.6 * p.front))
        }
    }
}

private extension FeedNote {
    /// The fields of its relay event the globe reads.
    var event: [String: Any] {
        ["id": id, "pubkey": pubkey, "kind": kind, "content": content, "tags": tags,
         "created_at": createdAt.timeIntervalSince1970]
    }
}
