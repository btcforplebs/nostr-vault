import SwiftUI
import Combine
import simd

extension TrustWebView {
    // MARK: - Live arcs

    /// The bar's switch for live arrival arcs, like the feed's Auto-load.
    var liveArcsButton: some View { LiveArcsToggle() }
}

/// Whether notes fly across the WOT globe as they reach the relay, and from
/// which feeds. Kept across launches, like Auto-load. The bar's antenna is
/// the main switch; the My Web dashboard picks the feeds.
enum LiveArcsSetting {
    static let key = "wotLiveArcs"

    /// Each feed's own switch. All three start on.
    static func key(_ ring: GlobeArcs.Ring) -> String {
        "wotLiveArcs." + ring.rawValue
    }
}

private struct LiveArcsToggle: View {
    @AppStorage(LiveArcsSetting.key) private var on = false

    var body: some View {
        IconFilterButton(icon: "antenna.radiowaves.left.and.right", tooltip: "Live arrivals",
                         isSelected: on, color: .havenPurple) { on.toggle() }
            .accessibilityLabel(Text("Live arrivals"))
            .accessibilityValue(Text(on ? "On" : "Off"))
            .accessibilityHint(Text("A star flies across the globe for each new note"))
            .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Notes arriving, as globe arrivals, each marked with the feed it belongs
/// to. Your follows' notes: when the feed has their timeline open
/// (Following, or Media on Following) they come from its own live
/// subscriptions, which stay open whichever tab is on screen: one stream, no
/// second set of connections. In every other feed mode the feed carries no
/// follows' notes, so the globe asks for them itself. Which of the two is
/// re-picked whenever the feed mode or your device relay changes. Reposts,
/// Discover and Global come from a second, wider REQ on your read relays.
@MainActor
final class GlobeArrivalStream: ObservableObject {
    let arrived = PassthroughSubject<GlobeArcs.Arrival, Never>()
    /// Watches what decides the source; lives for the whole start.
    private var watch: AnyCancellable?
    /// The current source's connections and sinks.
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
    /// Most Discover authors asked for: three filters' worth.
    private static let discoverCap = 1_500
    /// The wider REQ's connections and sinks, apart from the follows' source.
    private var wideClients: [WebSocketClient] = []
    private var wideCancellables: Set<AnyCancellable> = []
    /// How far back a note in the feed still counts as just arrived, for
    /// authors whose clocks run a little slow.
    private static let freshWindow: TimeInterval = 60

    /// Where arrivals come from.
    private enum Source: Equatable {
        /// The feed's own live timeline.
        case feed
        /// The globe's own REQ; `inbox` is your device relay's, when it is up.
        case own(inbox: URL?)
    }

    /// Opens the connections for the feeds in `rings`; returns the token
    /// that stops them.
    @discardableResult
    func start(me: String, rings: Set<GlobeArcs.Ring> = Set(GlobeArcs.Ring.allCases)) -> Int {
        stop()
        generation += 1
        guard !rings.isEmpty else { return generation }
        #if DEBUG
        // For looking at the arcs without anyone posting: made-up notes from
        // people on the globe. Nothing is published.
        if ProcessInfo.processInfo.arguments.contains("-GlobeArcsStub") {
            stub = Task { [weak self] in await self?.runStub(me: me) }
            return generation
        }
        #endif
        let feed = FeedService.shared
        let relay = RelayProcessManager.shared
        let people = Self.people(feed, me: me)
        openWide(feed, me: me, rings: rings, people: people)
        guard rings.contains(.following) else { return generation }
        watch = Publishers.CombineLatest4(feed.$feedMode, feed.$mediaFeedMode, relay.$isRunning, relay.$isBooting)
            .receive(on: DispatchQueue.main)
            .map { mode, media, _, _ -> Source in
                // The hop above runs this after the change is stored (@Published
                // fires in willSet), so the relay's flags read here are the new ones.
                let carriesFollows = mode == .following || (mode == .media && media == .following)
                return carriesFollows && feed.localInboxURL != nil ? .feed : .own(inbox: feed.localInboxURL)
            }
            .removeDuplicates()
            .sink { [weak self] source in self?.open(source, me: me) }
        return generation
    }

    /// Closes the connections, unless `token` is from an earlier start.
    /// True when they were closed.
    @discardableResult
    func stop(_ token: Int? = nil) -> Bool {
        if let token, token != generation { return false }
        watch = nil
        closeSource()
        wideCancellables.removeAll()
        wideClients.forEach { $0.disconnect() }
        wideClients = []
        #if DEBUG
        stub?.cancel()
        stub = nil
        #endif
        return true
    }

    private func closeSource() {
        cancellables.removeAll()
        clients.forEach { $0.disconnect() }
        clients = []
    }

    private func open(_ source: Source, me: String) {
        closeSource()
        let feed = FeedService.shared
        let blocked = ConfigService.shared.activeAccountBlockedHexPubkeys
        switch source {
        case .feed: watchFeed(feed, me: me, blocked: blocked)
        case .own(let inbox): ask(feed, inbox: inbox, me: me, blocked: blocked)
        }
    }

    /// New notes as the feed takes them in: yours, your follows', and those
    /// that tag you (the feed's are from your device relay's inbox, which
    /// already keeps strangers out). Notes land in `pendingNotes` or `notes`
    /// depending on their age and the feed's scroll, so both are watched;
    /// both are newest first, so only their fresh heads are read. What is
    /// already there when the globe opens has arrived, so it doesn't fly.
    private func watchFeed(_ feed: FeedService, me: String, blocked: Set<String>) {
        let follows = Set(feed.followedPubkeys).union([me])
        func fresh(_ notes: [FeedNote]) -> ArraySlice<FeedNote> {
            let cutoff = Date().addingTimeInterval(-Self.freshWindow)
            return notes.prefix { $0.createdAt >= cutoff }
        }
        // Seen ids and when they were written; only the fresh window is kept.
        var seen: [String: Date] = [:]
        for note in fresh(feed.notes) + fresh(feed.pendingNotes) { seen[note.id] = note.createdAt }
        feed.$pendingNotes.merge(with: feed.$notes)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notes in
                for note in fresh(notes) where note.repostedBy == nil && seen[note.id] == nil {
                    seen[note.id] = note.createdAt
                    guard var arrival = GlobeArcs.arrival(note.event), !blocked.contains(arrival.author),
                          follows.contains(arrival.author) || arrival.targets.contains(me) else { continue }
                    // A note to you from outside your follows still flies on
                    // Following: your relay's inbox already kept strangers out.
                    arrival.ring = .following
                    self?.arrived.send(arrival)
                }
                if seen.count > 256 {
                    let cutoff = Date().addingTimeInterval(-Self.freshWindow)
                    seen = seen.filter { $0.value >= cutoff }
                }
                // More than that inside one minute: keep the newest. The board
                // drops a repeat id itself.
                if seen.count > 256 {
                    seen = Dictionary(uniqueKeysWithValues: seen.sorted { $0.value > $1.value }.prefix(256).map { ($0.key, $0.value) })
                }
            }
            .store(in: &cancellables)
    }

    /// The globe's own REQ: yours and your follows' notes from your read
    /// relays, and notes to you. Relays cap how many authors one filter may
    /// name, so authors go in filters of up to 500 in the same REQ and every
    /// one counts. Notes to you come from your device relay's inbox when it
    /// is up, which keeps strangers out; when it isn't, from the read relays,
    /// where anyone can tag you, so only your web's come through, the same
    /// as Global.
    private func ask(_ feed: FeedService, inbox: URL?, me: String, blocked: Set<String>) {
        let note: [String: Any] = ["kinds": GlobeArcs.kinds, "since": Int(Date().timeIntervalSince1970)]
        let toMe = note.merging(["#p": [me]]) { $1 }
        let authors = Array(Set(feed.followedPubkeys).union([me])).sorted()
        let byAuthors = stride(from: 0, to: authors.count, by: Self.authorsPerFilter).map {
            note.merging(["authors": Array(authors[$0..<min($0 + Self.authorsPerFilter, authors.count)])]) { $1 }
        }
        var plan: [(url: URL, filters: [[String: Any]], trusted: Set<String>?)] = []
        if let inbox {
            plan.append((inbox, [toMe], nil))
            plan += feed.externalRelayURLs.prefix(3).map { ($0, byAuthors, Set(authors)) }
        } else {
            let trusted = feed.relayTabTrustedPubkeys().union(authors)
            plan += feed.externalRelayURLs.prefix(3).map { ($0, byAuthors + [toMe], trusted) }
        }
        for (url, filters, trusted) in plan {
            let client = Self.subscribe(url, filters: filters) { [weak self] event in
                guard var arrival = GlobeArcs.arrival(event), !blocked.contains(arrival.author),
                      trusted?.contains(arrival.author) ?? true else { return }
                arrival.ring = .following
                self?.arrived.send(arrival)
            }
            clients.append(client.client)
            cancellables.insert(client.sink)
        }
    }

    /// Who belongs to which feed: you and your follows, then your wider web
    /// (the Discover feed's people, or your saved web while those aren't
    /// worked out yet), capped.
    private static func people(_ feed: FeedService, me: String) -> (follows: Set<String>, discover: [String]) {
        let follows = Set(feed.followedPubkeys).union([me])
        let wider = feed.extendedNetworkPubkeys.isEmpty
            ? Array(feed.feedTrustedPubkeys) : feed.extendedNetworkPubkeys
        return (follows, Array(wider.lazy.filter { !follows.contains($0) }.prefix(discoverCap)))
    }

    /// The wider REQ on your read relays: your follows' reposts (the feed
    /// shows a repost as the note reposted, so it can't say when one is
    /// made), and the Discover and Global feeds when they're on. Global keeps
    /// to your web, as the Global feed does, unless that is set to Everyone.
    private func openWide(_ feed: FeedService, me: String, rings: Set<GlobeArcs.Ring>,
                          people: (follows: Set<String>, discover: [String])) {
        let since = Int(Date().timeIntervalSince1970)
        let all = GlobeArcs.kinds + GlobeArcs.repostKinds
        func byAuthors(_ authors: [String], kinds: [Int]) -> [[String: Any]] {
            stride(from: 0, to: authors.count, by: Self.authorsPerFilter).map {
                ["kinds": kinds, "since": since, "authors": Array(authors[$0..<min($0 + Self.authorsPerFilter, authors.count)])]
            }
        }
        var filters: [[String: Any]] = []
        if rings.contains(.following) { filters += byAuthors(people.follows.sorted(), kinds: GlobeArcs.repostKinds) }
        if rings.contains(.discover) { filters += byAuthors(people.discover, kinds: all) }
        if rings.contains(.global) { filters.append(["kinds": all, "since": since]) }
        guard !filters.isEmpty else { return }
        let discover = Set(people.discover)
        let blocked = ConfigService.shared.activeAccountBlockedHexPubkeys
        let trusted = rings.contains(.global) ? feed.globalTrustSet() : nil
        for url in feed.externalRelayURLs.prefix(rings.contains(.global) ? 2 : 3) {
            let wide = Self.subscribe(url, filters: filters) { [weak self] event in
                guard var arrival = GlobeArcs.arrival(event), !blocked.contains(arrival.author) else { return }
                arrival.ring = GlobeArcs.ring(of: arrival.author, follows: people.follows, discover: discover)
                guard rings.contains(arrival.ring),
                      arrival.ring != .global || (trusted?.contains(arrival.author) ?? true) else { return }
                self?.arrived.send(arrival)
            }
            wideClients.append(wide.client)
            wideCancellables.insert(wide.sink)
        }
    }

    /// One relay connection with one REQ; each event it sends goes to `onEvent`.
    private static func subscribe(_ url: URL, filters: [[String: Any]],
                                  onEvent: @escaping ([String: Any]) -> Void) -> (client: WebSocketClient, sink: AnyCancellable) {
        let client = WebSocketClient()
        client.isTemporary = true
        // WebSocketClient already delivers on the main thread.
        let sink = client.messageSubject
            .sink { message in
                guard message.hasPrefix("[\"EVENT\""),
                      let data = message.data(using: .utf8),
                      let array = try? JSONSerialization.jsonObject(with: data) as? [Any], array.count >= 3,
                      let event = array[2] as? [String: Any] else { return }
                onEvent(event)
            }
        client.connect(url: url)
        // Split, so a relay's size cap can't refuse every filter at once.
        let requests = GlobeArcs.requests(filters, subId: "arcs-\(UUID().uuidString.prefix(8))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak client] in
            guard let client else { return }
            for text in requests {
                client.send(text: text)
            }
        }
        return (client, sink)
    }

    #if DEBUG
    private func runStub(me: String) async {
        // Real authors from the feed; the lines they draw are made up.
        let feedNotes = FeedService.shared.notes.filter { $0.kind == 1 }
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
            let id = (0..<4).map { _ in String(format: "%016llx", UInt64.random(in: 0...UInt64.max)) }.joined()
            // Every feed in turn, so each shell's stars show.
            let ring = GlobeArcs.Ring.allCases[n % GlobeArcs.Ring.allCases.count]
            arrived.send(GlobeArcs.Arrival(id: id, author: author, targets: targets, ring: ring))
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
    /// Where someone sits on the globe; with a feed, where a star from them
    /// on that feed sets out.
    let place: (String, GlobeArcs.Ring?) -> SIMD3<Double>

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
            let a = place(line.from, line.ring), b = place(line.to, nil)
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
                // Round the back a star dims smoothly, never switches.
                let behind = GlobeEdge.arc(depth: head.depth)
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
    }

    /// Pictures at the ends of the lines, easing in as a star sets out and
    /// out as its light fades. Someone already seated as a face keeps their seat.
    func drawFaces(_ context: inout GraphicsContext, seated: Set<String>,
                   face: (inout GraphicsContext, String, CGPoint, Double, Color, Double) -> Void) {
        var shown: [String: Double] = [:]
        var setsOut: [String: GlobeArcs.Ring] = [:]
        for line in board.lines {
            let a = GlobeArcs.faceAlpha(of: line, at: now)
            for key in [line.from, line.to] where a > (shown[key] ?? 0) { shown[key] = a }
            if setsOut[line.from] == nil { setsOut[line.from] = line.ring }
        }
        // A face rolling toward the rim fades and shrinks rather than popping.
        let faces = shown.compactMap { key, alpha -> (String, GlobeScene.Projected, Double, Double)? in
            guard key != center, !seated.contains(key), alpha > 0.02,
                  let p = project(place(key, setsOut[key])) else { return nil }
            let edge = GlobeEdge.face(depth: p.depth)
            return edge > 0.02 ? (key, p, alpha, edge) : nil
        }.sorted { $0.1.depth < $1.1.depth }
        for (key, p, a, edge) in faces {
            let r = GlobeEdge.faceRadius(13 * k * p.scale * min(zoom, 1.8), shown: edge)
            face(&context, key, p.point, r, Self.starColor.opacity(0.85), a * edge * (0.4 + 0.6 * p.front))
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
