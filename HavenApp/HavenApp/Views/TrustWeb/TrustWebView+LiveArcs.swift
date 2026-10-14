import SwiftUI
import Combine
import simd

extension TrustWebView {
    // MARK: - Live arcs

    /// The bar's switch for live arrival arcs, like the feed's Auto-load.
    var liveArcsButton: some View { LiveArcsToggle() }
}

/// Whether notes fly across the WOT globe as they reach the relay. Kept
/// across launches, like Auto-load.
enum LiveArcsSetting {
    static let key = "wotLiveArcs"
}

private struct LiveArcsToggle: View {
    @AppStorage(LiveArcsSetting.key) private var on = false

    var body: some View {
        IconFilterButton(icon: "antenna.radiowaves.left.and.right", tooltip: "Live arrivals",
                         isSelected: on, color: .havenPurple) { on.toggle() }
            .accessibilityLabel(Text("Live arrivals"))
            .accessibilityValue(Text(on ? "On" : "Off"))
            .accessibilityHint(Text("Draws a line across the globe for each note as it reaches your relay"))
            .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Notes arriving at the relay, as globe arrivals. Your device relay when it
/// is up: its feed cache (your follows' notes) and its inbox (notes to you).
/// Your read relays when it isn't.
@MainActor
final class GlobeArrivalStream: ObservableObject {
    let arrived = PassthroughSubject<GlobeArcs.Arrival, Never>()
    private var clients: [WebSocketClient] = []
    private var cancellables: Set<AnyCancellable> = []
    /// Which start the open connections belong to, so a late stop from an
    /// earlier one leaves a newer one running.
    private var generation = 0
    #if DEBUG
    private var stub: Task<Void, Never>?
    #endif

    /// Opens the connections; returns the token that stops them.
    @discardableResult
    func start(me: String) -> Int {
        stop()
        generation += 1
        #if DEBUG
        // For looking at the arcs without anyone posting: made-up notes from
        // people on the globe. Nothing is published.
        if ProcessInfo.processInfo.arguments.contains("-GlobeArcsStub") {
            stub = Task { [weak self] in await self?.runStub(me: me) }
            return generation
        }
        #endif
        let feed = FeedService.shared
        let since = Int(Date().timeIntervalSince1970)
        let note: [String: Any] = ["kinds": GlobeArcs.kinds, "since": since]
        var plan: [(URL, [[String: Any]])] = []
        if let local = feed.localFeedURL { plan.append((local, [note])) }
        if let inbox = feed.localInboxURL { plan.append((inbox, [note.merging(["#p": [me]]) { $1 }])) }
        if plan.isEmpty {
            let follows = Array(feed.followedPubkeys.prefix(500))
            let filters = [note.merging(["authors": follows]) { $1 }, note.merging(["#p": [me]]) { $1 }]
            plan = feed.externalRelayURLs.prefix(3).map { ($0, filters) }
        }
        let blocked = ConfigService.shared.activeAccountBlockedHexPubkeys
        let subId = "arcs-\(UUID().uuidString.prefix(8))"
        for (url, filters) in plan {
            let client = WebSocketClient()
            client.isTemporary = true
            clients.append(client)
            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { [weak self] message in self?.handle(message, blocked: blocked) }
                .store(in: &cancellables)
            client.connect(url: url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let req: [Any] = ["REQ", subId] + filters
                if let data = try? JSONSerialization.data(withJSONObject: req),
                   let text = String(data: data, encoding: .utf8) {
                    client.send(text: text)
                }
            }
        }
        return generation
    }

    /// Closes the connections, unless `token` is from an earlier start.
    /// True when they were closed.
    @discardableResult
    func stop(_ token: Int? = nil) -> Bool {
        if let token, token != generation { return false }
        cancellables.removeAll()
        clients.forEach { $0.disconnect() }
        clients = []
        #if DEBUG
        stub?.cancel()
        stub = nil
        #endif
        return true
    }

    private func handle(_ message: String, blocked: Set<String>) {
        guard message.hasPrefix("[\"EVENT\""),
              let data = message.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any], array.count >= 3,
              let event = array[2] as? [String: Any],
              let arrival = GlobeArcs.arrival(event),
              !blocked.contains(arrival.author) else { return }
        emit(arrival)
    }

    private func emit(_ arrival: GlobeArcs.Arrival) {
        // Their pictures, so the faces at each end can be pictures.
        NostrService.shared.fetchMissingProfiles(for: [arrival.author] + arrival.targets)
        arrived.send(arrival)
    }

    #if DEBUG
    private func runStub(me: String) async {
        let people = Array(FeedService.shared.followedPubkeys.shuffled().prefix(80))
        guard people.count > 4 else { return }
        var n = 0
        while !Task.isCancelled {
            n += 1
            let author = people.randomElement()!
            // Mostly notes to you; some replies to a few people; some to no one.
            let targets: [String]
            switch n % 5 {
            case 0, 2: targets = [me]
            case 1: targets = Array(people.filter { $0 != author }.shuffled().prefix(Int.random(in: 2...3)))
            case 3: targets = [people.filter { $0 != author }.randomElement()!]
            default: targets = []
            }
            let id = (0..<4).map { _ in String(format: "%016llx", UInt64.random(in: 0...UInt64.max)) }.joined()
            emit(GlobeArcs.Arrival(id: id, author: author, targets: targets))
            try? await Task.sleep(for: .milliseconds(Int.random(in: 600...1600)))
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
    /// Where someone sits on the globe.
    let place: (String) -> SIMD3<Double>

    /// Pink for a note to you, sky blue for one to someone else: apart from
    /// the amber trust threads, the violet haze and the pale follows.
    static let toMeColor = Color(red: 1, green: 0.46, blue: 0.72)
    static let toOthersColor = Color(red: 0.42, green: 0.84, blue: 1)
    static let pulseColor = Color(red: 0.94, green: 0.94, blue: 1)
    /// Points along a drawn line: smooth at full zoom, cheap at ten lines.
    static let arcSamples = 40

    /// One soft light: a glow with a bright middle.
    private func light(_ context: inout GraphicsContext, at p: CGPoint, r: Double, color: Color, opacity: Double) {
        guard opacity > 0.01 else { return }
        context.fill(Path(ellipseIn: CGRect(x: p.x - r * 3, y: p.y - r * 3, width: r * 6, height: r * 6)),
                     with: .radialGradient(Gradient(colors: [color.opacity(0.55 * opacity), .clear]),
                                           center: p, startRadius: 0, endRadius: r * 3))
        context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                     with: .color(color.opacity(opacity)))
    }

    /// The lines, their lights and the lights of notes aimed at no one:
    /// over the stars and threads, under the faces.
    func drawLines(_ context: inout GraphicsContext) {
        // Lights breathe slowly while their line stands.
        let breath = reduceMotion ? 1 : 0.82 + 0.18 * sin(now * 2 * .pi / 2.6)
        struct Drawn { let front: Path; let back: Path; let color: Color; let alpha: Double }
        var drawn: [Drawn] = []
        var heads: [(CGPoint, Color, Double)] = []
        var landings: [(CGPoint, Color, GlobeArcs.Stage)] = []
        for line in board.lines {
            let stage = GlobeArcs.stage(of: line, at: now, reduceMotion: reduceMotion)
            guard stage.alpha > 0.01, stage.head > stage.tail else { continue }
            let a = place(line.from), b = place(line.to)
            let color = line.toMe ? Self.toMeColor : Self.toOthersColor
            var front = Path(), back = Path()
            var last: (CGPoint, Bool)?
            // Which path the open run of points is in: one run per side, so joins stay smooth.
            var run: Bool?
            let n = Self.arcSamples
            for s in 0...n {
                let t = stage.tail + (stage.head - stage.tail) * Double(s) / Double(n)
                guard let p = project(GlobeArcs.point(from: a, to: b, at: t, facing: facing)) else { last = nil; run = nil; continue }
                // Behind the globe's middle, the line goes faint.
                let isFront = p.depth > -0.2
                if let (q, wasFront) = last {
                    let toFront = isFront || wasFront
                    if run != toFront {
                        if toFront { front.move(to: q) } else { back.move(to: q) }
                        run = toFront
                    }
                    if toFront { front.addLine(to: p.point) } else { back.addLine(to: p.point) }
                }
                last = (p.point, isFront)
                if s == n, stage.head < 1 { heads.append((p.point, color, stage.alpha * (isFront ? 1 : 0.4))) }
            }
            drawn.append(Drawn(front: front, back: back, color: color, alpha: stage.alpha))
            if stage.landing > 0, let p = project(b) { landings.append((p.point, color, stage)) }
        }
        // All the glow in one blurred layer.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 4))
            for line in drawn {
                layer.stroke(line.front, with: .color(line.color.opacity(0.55 * line.alpha)), lineWidth: 3.2)
            }
        }
        for line in drawn {
            context.stroke(line.back, with: .color(line.color.opacity(0.28 * line.alpha)),
                           style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            context.stroke(line.front, with: .color(line.color.opacity(0.9 * line.alpha)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        // The note in flight: a bright bead at the head.
        for (p, color, a) in heads { light(&context, at: p, r: 2.6 * max(0.8, k), color: color, opacity: a) }
        // Where it lands: a ring opens once, then a light stays and breathes.
        for (p, color, stage) in landings {
            let r = (6 + 22 * stage.landing) * max(0.8, k)
            context.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(color.opacity(0.7 * (1 - stage.landing) * stage.alpha)), lineWidth: 1.4)
            light(&context, at: p, r: 2.4 * max(0.8, k), color: color, opacity: 0.8 * stage.alpha * breath)
        }
        // A note to no one: its author's light swells and fades.
        for pulse in board.pulses {
            let t = min(1, (now - pulse.born) / GlobeArcs.pulseLife)
            guard let p = project(place(pulse.key)), p.depth > -0.2 else { continue }
            let swell = reduceMotion ? 0 : sin(t * .pi)
            let r = (8 + 14 * t) * max(0.8, k)
            if !reduceMotion {
                context.stroke(Path(ellipseIn: CGRect(x: p.point.x - r, y: p.point.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(Self.pulseColor.opacity(0.5 * (1 - t))), lineWidth: 1.2)
            }
            light(&context, at: p.point, r: (2 + 1.2 * swell) * max(0.8, k), color: Self.pulseColor,
                  opacity: 0.85 * (1 - t * t))
        }
    }

    /// Pictures at the ends of the lines, easing in as a line sets out and
    /// out as it fades. Someone already seated as a face keeps their seat.
    func drawFaces(_ context: inout GraphicsContext, seated: Set<String>,
                   face: (inout GraphicsContext, String, CGPoint, Double, Color, Double) -> Void) {
        var shown: [String: (alpha: Double, color: Color)] = [:]
        for line in board.lines {
            let a = GlobeArcs.faceAlpha(of: line, at: now)
            let color = line.toMe ? Self.toMeColor : Self.toOthersColor
            for key in [line.from, line.to] where a > (shown[key]?.alpha ?? 0) { shown[key] = (a, color) }
        }
        for pulse in board.pulses {
            let t = (now - pulse.born) / GlobeArcs.pulseLife
            let a = min(1, t / 0.3, (1 - t) / 0.4)
            if a > (shown[pulse.key]?.alpha ?? 0) { shown[pulse.key] = (a, Self.pulseColor) }
        }
        let faces = shown.compactMap { key, look -> (String, GlobeScene.Projected, Double, Color)? in
            guard key != center, !seated.contains(key), look.alpha > 0.02,
                  let p = project(place(key)), p.depth > -0.2 else { return nil }
            return (key, p, look.alpha, look.color)
        }.sorted { $0.1.depth < $1.1.depth }
        for (key, p, a, color) in faces {
            let r = 13 * k * p.scale * min(zoom, 1.8)
            face(&context, key, p.point, r, color, a * (0.4 + 0.6 * p.front))
        }
    }
}
