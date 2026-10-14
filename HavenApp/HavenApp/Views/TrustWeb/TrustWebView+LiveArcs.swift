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

/// Notes arriving, as globe arrivals. While your device relay is up they
/// come from the feed's own live subscriptions, which stay open whichever tab
/// is on screen: one stream, no second set of connections. When it is down
/// the feed has nothing open, so your follows' notes and notes to you are
/// asked from your read relays directly.
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

    /// Most authors one filter names.
    private static let authorsPerFilter = 500

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
        let blocked = ConfigService.shared.activeAccountBlockedHexPubkeys
        if feed.localInboxURL != nil {
            watchFeed(feed, me: me, blocked: blocked)
        } else {
            askReadRelays(feed, me: me, blocked: blocked)
        }
        return generation
    }

    /// New notes as the feed takes them in: your follows' always; anyone's
    /// that tag you, except in a Global-like mode, where strangers reach the
    /// feed too and only your web's come through. Notes land in `pendingNotes`
    /// or `notes` depending on their age and the feed's scroll, so both are
    /// watched; both are newest first, so only their new heads are read.
    private func watchFeed(_ feed: FeedService, me: String, blocked: Set<String>) {
        // A minute back, for authors whose clocks run a little slow.
        let since = Date().addingTimeInterval(-60)
        let follows = Set(feed.followedPubkeys)
        var web: Set<String>?
        var seen = Set<String>()
        feed.$pendingNotes.merge(with: feed.$notes)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notes in
                for note in notes.prefix(while: { $0.createdAt >= since })
                where note.repostedBy == nil && seen.insert(note.id).inserted {
                    guard let arrival = GlobeArcs.arrival(note.event), !blocked.contains(arrival.author) else { continue }
                    if !follows.contains(arrival.author) {
                        guard arrival.targets.contains(me) else { continue }
                        if feed.isGlobalLikeMode {
                            if web == nil { web = feed.relayTabTrustedPubkeys() }
                            guard web?.contains(arrival.author) == true else { continue }
                        }
                    }
                    self?.arrived.send(arrival)
                }
            }
            .store(in: &cancellables)
    }

    /// The device relay is down: your follows' notes and notes to you from
    /// your read relays. Relays cap how many authors one filter may name, so
    /// follows go in filters of up to 500 in the same REQ and every one
    /// counts. Anyone can tag you out there: only your web's notes come
    /// through, the same as Global.
    private func askReadRelays(_ feed: FeedService, me: String, blocked: Set<String>) {
        let note: [String: Any] = ["kinds": GlobeArcs.kinds, "since": Int(Date().timeIntervalSince1970)]
        let follows = Array(Set(feed.followedPubkeys)).sorted()
        let filters = stride(from: 0, to: follows.count, by: Self.authorsPerFilter).map {
            note.merging(["authors": Array(follows[$0..<min($0 + Self.authorsPerFilter, follows.count)])]) { $1 }
        } + [note.merging(["#p": [me]]) { $1 }]
        let trusted = feed.relayTabTrustedPubkeys().union(follows)
        let subId = "arcs-\(UUID().uuidString.prefix(8))"
        for url in feed.externalRelayURLs.prefix(3) {
            let client = WebSocketClient()
            client.isTemporary = true
            clients.append(client)
            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { [weak self] message in self?.handle(message, blocked: blocked, trusted: trusted) }
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

    private func handle(_ message: String, blocked: Set<String>, trusted: Set<String>) {
        guard message.hasPrefix("[\"EVENT\""),
              let data = message.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any], array.count >= 3,
              let event = array[2] as? [String: Any],
              let arrival = GlobeArcs.arrival(event),
              !blocked.contains(arrival.author),
              trusted.contains(arrival.author) else { return }
        arrived.send(arrival)
    }

    #if DEBUG
    private func runStub(me: String) async {
        // Real notes from the feed, so a preview shows real words and opens a
        // real note; the lines they draw are made up.
        let feedNotes = FeedService.shared.notes.filter { $0.kind == 1 && !GlobeArcs.firstLine($0.content).isEmpty }
        let people = Array(Set(FeedService.shared.followedPubkeys + feedNotes.map(\.pubkey)).shuffled().prefix(80))
        guard people.count > 4 else { return }
        var n = 0
        while !Task.isCancelled {
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
            let id = real?.id ?? (0..<4).map { _ in String(format: "%016llx", UInt64.random(in: 0...UInt64.max)) }.joined()
            arrived.send(GlobeArcs.Arrival(id: id, author: author, targets: targets,
                                   text: GlobeArcs.firstLine(real?.content ?? "")))
            try? await Task.sleep(for: .milliseconds(Int.random(in: 900...2000)))
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

    /// Every arrival is a small white star, like the stars of the globe itself.
    static let starColor = Color.white
    /// Points along a drawn line: smooth at full zoom, cheap at ten lines.
    private static let arcSamples = 40
    /// Steps in a star's tail, each a little fainter and thinner than the last.
    private static let tailSteps = 8

    /// One soft light: a glow with a bright middle.
    private func light(_ context: inout GraphicsContext, at p: CGPoint, r: Double, opacity: Double) {
        guard opacity > 0.01 else { return }
        let color = Self.starColor
        context.fill(Path(ellipseIn: CGRect(x: p.x - r * 3, y: p.y - r * 3, width: r * 6, height: r * 6)),
                     with: .radialGradient(Gradient(colors: [color.opacity(0.5 * opacity), .clear]),
                                           center: p, startRadius: 0, endRadius: r * 3))
        context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                     with: .color(color.opacity(opacity)))
    }

    /// Shooting stars, their faint trails, and the lights where they land:
    /// over the stars and threads, under the faces.
    func drawLines(_ context: inout GraphicsContext) {
        let unit = max(0.8, k)
        // Lights breathe slowly while they stay.
        let breath = reduceMotion ? 1 : 0.82 + 0.18 * sin(now * 2 * .pi / 2.6)
        var trails: [(Path, Double)] = []
        var tails: [(Path, Double, Double)] = []
        var stars: [(CGPoint, Double)] = []
        var landings: [(CGPoint, GlobeArcs.Stage)] = []
        for line in board.lines {
            let stage = GlobeArcs.stage(of: line, at: now, reduceMotion: reduceMotion)
            guard stage.alpha > 0.01 else { continue }
            let a = place(line.from), b = place(line.to)
            func at(_ t: Double) -> GlobeScene.Projected? {
                project(GlobeArcs.point(from: a, to: b, at: t, facing: facing))
            }
            // The faint trail it leaves, gone soon after it lands.
            if stage.trail > 0.01 {
                var path = Path(), open = false
                let n = Self.arcSamples
                for s in 0...n {
                    guard let p = at(stage.head * Double(s) / Double(n)) else { open = false; continue }
                    if open { path.addLine(to: p.point) } else { path.move(to: p.point); open = true }
                }
                trails.append((path, stage.trail))
            }
            // In flight: the star and its short tail, brightest at the star.
            if stage.head < 1, let head = at(stage.head) {
                let behind = head.depth > -0.2 ? 1.0 : 0.35
                let start = max(0, stage.head - GlobeArcs.tailLength)
                var last = at(start)?.point
                for step in 1...Self.tailSteps {
                    let t = start + (stage.head - start) * Double(step) / Double(Self.tailSteps)
                    guard let p = at(t) else { last = nil; continue }
                    if let last {
                        var segment = Path()
                        segment.move(to: last)
                        segment.addLine(to: p.point)
                        let f = Double(step) / Double(Self.tailSteps)
                        tails.append((segment, f * f * stage.alpha * behind, 0.4 + 1.4 * f))
                    }
                    last = p.point
                }
                stars.append((head.point, stage.alpha * behind))
            }
            if stage.landing > 0, let p = project(b) { landings.append((p.point, stage)) }
        }
        let color = Self.starColor
        for (path, a) in trails {
            context.stroke(path, with: .color(color.opacity(0.14 * a)),
                           style: StrokeStyle(lineWidth: 0.8, lineCap: .round, lineJoin: .round))
        }
        if !tails.isEmpty {
            // The tails' glow in one blurred layer.
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 2.5))
                for (segment, a, width) in tails {
                    layer.stroke(segment, with: .color(color.opacity(0.5 * a)), lineWidth: width + 2)
                }
            }
            for (segment, a, width) in tails {
                context.stroke(segment, with: .color(color.opacity(0.9 * a)),
                               style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
        }
        for (p, a) in stars { light(&context, at: p, r: 1.8 * unit, opacity: a) }
        // Where it lands: a small ring opens once, then a light stays and breathes.
        for (p, stage) in landings {
            let r = (5 + 14 * stage.landing) * unit
            context.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(color.opacity(0.5 * (1 - stage.landing) * stage.alpha)), lineWidth: 1)
            light(&context, at: p, r: 1.8 * unit, opacity: 0.7 * stage.alpha * breath)
        }
        // A note to no one: its author's light swells and fades.
        for pulse in board.pulses {
            let t = min(1, (now - pulse.born) / GlobeArcs.pulseLife)
            guard let p = project(place(pulse.key)), p.depth > -0.2 else { continue }
            let swell = reduceMotion ? 0 : sin(t * .pi)
            let r = (6 + 12 * t) * unit
            if !reduceMotion {
                context.stroke(Path(ellipseIn: CGRect(x: p.point.x - r, y: p.point.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(color.opacity(0.4 * (1 - t))), lineWidth: 1)
            }
            light(&context, at: p.point, r: (1.8 + 1 * swell) * unit, opacity: 0.8 * (1 - t * t))
        }
    }

    /// Pictures at the ends of the lines, easing in as a star sets out and
    /// out as its light fades. Someone already seated as a face keeps their seat.
    func drawFaces(_ context: inout GraphicsContext, seated: Set<String>,
                   face: (inout GraphicsContext, String, CGPoint, Double, Color, Double) -> Void) {
        var shown: [String: Double] = [:]
        for line in board.lines {
            let a = GlobeArcs.faceAlpha(of: line, at: now)
            for key in [line.from, line.to] where a > (shown[key] ?? 0) { shown[key] = a }
        }
        for pulse in board.pulses {
            let t = (now - pulse.born) / GlobeArcs.pulseLife
            let a = min(1, t / 0.3, (1 - t) / 0.4)
            if a > (shown[pulse.key] ?? 0) { shown[pulse.key] = a }
        }
        let faces = shown.compactMap { key, alpha -> (String, GlobeScene.Projected, Double)? in
            guard key != center, !seated.contains(key), alpha > 0.02,
                  let p = project(place(key)), p.depth > -0.2 else { return nil }
            return (key, p, alpha)
        }.sorted { $0.1.depth < $1.1.depth }
        for (key, p, a) in faces {
            let r = 13 * k * p.scale * min(zoom, 1.8)
            face(&context, key, p.point, r, Self.starColor.opacity(0.85), a * (0.4 + 0.6 * p.front))
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
