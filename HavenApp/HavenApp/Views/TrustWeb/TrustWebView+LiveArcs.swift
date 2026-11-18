import SwiftUI
import Combine
import simd

extension TrustWebView {
    // MARK: - Live arcs

    /// The bar's switch for live arrival arcs, like the feed's Auto-load.
    var liveArcsButton: some View { LiveArcsToggle() }
}

private struct LiveArcsToggle: View {
    @AppStorage(LiveArcsSetting.key) private var on = LiveArcsSetting.defaultOn

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
/// re-picked whenever the feed mode or your device relay changes. Everything
/// else comes from one wider REQ on each of your read relays. Every REQ
/// rides the feed's own open connection to its relay (`GlobeRelayLink`):
/// the globe opens no connections of its own.
@MainActor
final class GlobeArrivalStream: ObservableObject {
    let arrived = PassthroughSubject<GlobeArcs.Arrival, Never>()
    /// Watches what decides the source; lives for the whole start.
    private var watch: AnyCancellable?
    /// The current source's REQs and sinks.
    private var links: [GlobeRelayLink] = []
    private var cancellables: Set<AnyCancellable> = []
    /// Which start the open connections belong to, so a late stop from an
    /// earlier one leaves a newer one running.
    private var generation = 0
    /// Who the globe is for: a bounce counts only when it tags you.
    private var me = ""
    #if DEBUG
    private var stub: Task<Void, Never>?
    #endif

    /// Most authors one filter names.
    private static let authorsPerFilter = 500
    /// The wider REQ on each read relay, apart from the follows' source.
    private var wideLinks: [GlobeRelayLink] = []
    #if DEBUG
    /// Arrivals per minute, for the globe's debug readout.
    @Published private(set) var perMinute = 0
    private var meter = GlobeArcs.RateMeter()
    private var meterTick: Timer?
    #endif
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
    /// A sort switched off in My Web isn't asked for at all (`show`).
    func start(me: String, rings: Set<GlobeArcs.Ring> = Set(GlobeArcs.Ring.allCases),
               show: GlobeArcs.Show = .init()) -> Int {
        stop()
        generation += 1
        self.me = me
        guard !rings.isEmpty else { return generation }
        #if DEBUG
        meterTick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let rate = self.meter.perMinute(at: Date.timeIntervalSinceReferenceDate)
                if rate != self.perMinute { self.perMinute = rate }
            }
        }
        #endif
        #if DEBUG
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
        let relay = RelayProcessManager.shared
        let people = Self.people(feed, me: me)
        openWide(feed, me: me, rings: rings, people: people, show: show)
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
            .sink { [weak self] source in self?.open(source, me: me, show: show) }
        return generation
    }

    /// Closes the connections, unless `token` is from an earlier start.
    /// True when they were closed.
    @discardableResult
    func stop(_ token: Int? = nil) -> Bool {
        if let token, token != generation { return false }
        watch = nil
        closeSource()
        wideLinks.forEach { $0.close() }
        wideLinks = []
        #if DEBUG
        stub?.cancel()
        stub = nil
        meterTick?.invalidate()
        meterTick = nil
        #endif
        return true
    }

    private func closeSource() {
        cancellables.removeAll()
        links.forEach { $0.close() }
        links = []
    }

    /// Every arrival goes out through here.
    private func emit(_ arrival: GlobeArcs.Arrival) {
        #if DEBUG
        meter.record(arrival.id, at: Date.timeIntervalSinceReferenceDate)
        #endif
        if GlobeArcs.countsAsBounce(arrival, me: me) { GlobeBounceCount.shared.record(arrival.id) }
        arrived.send(arrival)
    }

    /// The gate's say on an arrival, the one rule every feed uses
    /// (`WebGate.judge`, step 7 of RESEARCH/NV_ONE_WOT_GATE.md): let in, sent
    /// back off your web's shell in red, or nothing. Read at each arrival,
    /// so a block, a mute or a new follow counts at once.
    private static func judged(_ arrival: GlobeArcs.Arrival, event: [String: Any],
                               reach: WebGate.Reach = .web) -> GlobeArcs.Arrival? {
        GlobeArcs.judged(arrival, event: event, in: FeedService.shared.feedGate, reach: reach)
    }

    private func open(_ source: Source, me: String, show: GlobeArcs.Show) {
        closeSource()
        let feed = FeedService.shared
        GlobeBounceCount.shared.use(account: me)
        switch source {
        case .feed: watchFeed(feed, me: me)
        case .own(let inbox): ask(feed, inbox: inbox, me: me, kinds: show.noteKinds)
        }
    }

    /// New notes as the feed takes them in: yours, your follows', and those
    /// that tag you (the feed's are from your device relay's inbox, which
    /// already keeps strangers out). Notes land in `pendingNotes` or `notes`
    /// depending on their age and the feed's scroll, so both are watched;
    /// both are newest first, so only their fresh heads are read. What is
    /// already there when the globe opens has arrived, so it doesn't fly.
    private func watchFeed(_ feed: FeedService, me: String) {
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
                    guard var arrival = GlobeArcs.arrival(note.event),
                          follows.contains(arrival.author) || arrival.targets.contains(me) else { continue }
                    // A note to you from your web flies on Following; one the
                    // gate refuses bounces.
                    arrival.ring = .following
                    if let judged = Self.judged(arrival, event: note.event) { self?.emit(judged) }
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

    /// Notes to you, when the feed isn't carrying your follows. Yours and
    /// your follows' own notes come in on the wider REQ (`openWide`), from
    /// the same read relays. Notes to you come from your device relay's
    /// inbox when it is up; when it isn't, from the read relays, where
    /// anyone can tag you. Either way the gate judges each: your web's fly,
    /// a stranger's bounce.
    private func ask(_ feed: FeedService, inbox: URL?, me: String, kinds: [Int]) {
        // An empty kinds list would match everything on some relays.
        guard !kinds.isEmpty else { return }
        let toMe: [String: Any] = ["kinds": kinds, "since": Int(Date().timeIntervalSince1970), "#p": [me]]
        let urls = inbox.map { [$0] } ?? feed.externalRelayURLs
        for url in urls {
            links.append(GlobeRelayLink(url: url, filters: [toMe]) { [weak self] event in
                guard var arrival = GlobeArcs.arrival(event) else { return }
                arrival.ring = .following
                if let judged = Self.judged(arrival, event: event) { self?.emit(judged) }
            })
        }
    }

    /// Who belongs to which feed: you and your follows, then all of your
    /// wider web (the Discover feed's people, or your saved web while those
    /// aren't worked out yet).
    private static func people(_ feed: FeedService, me: String) -> (follows: Set<String>, discover: Set<String>) {
        let follows = Set(feed.followedPubkeys).union([me])
        let wider = feed.extendedNetworkPubkeys.isEmpty
            ? Set(feed.feedTrustedPubkeys) : Set(feed.extendedNetworkPubkeys)
        return (follows, wider.subtracting(follows))
    }

    /// The wider REQ on every one of your read relays: your follows'
    /// notes, reposts (the feed shows a repost as the note reposted, so it
    /// can't say when one is made), reactions and zaps, and the Discover and
    /// Global feeds when they're on, as one stream sorted here by author
    /// (`GlobeArcs.storm`).
    /// Global keeps to your web, as the Global feed does, unless that is set
    /// to Everyone.
    private func openWide(_ feed: FeedService, me: String, rings: Set<GlobeArcs.Ring>,
                          people: (follows: Set<String>, discover: Set<String>), show: GlobeArcs.Show) {
        // A note the feed's timeline also carries flies once: the board
        // drops a repeat id.
        let filters = GlobeArcs.storm(rings: rings, show: show, follows: people.follows.sorted(),
                                      since: Int(Date().timeIntervalSince1970), authorsPerFilter: Self.authorsPerFilter)
        guard !filters.isEmpty else { return }
        // How far each ring reaches: its feed's Reach (Everyone for Global
        // with the shield off), so the globe refuses what that feed refuses.
        let reach: [GlobeArcs.Ring: WebGate.Reach] = [
            .following: .web,
            .discover: feed.reach(for: .discovery, globalLike: false),
            .global: feed.reach(for: .global, globalLike: true),
        ]
        for url in feed.externalRelayURLs {
            wideLinks.append(GlobeRelayLink(url: url, filters: filters) { [weak self] event in
                // A zap's request must be signed by its zapper.
                guard var arrival = GlobeArcs.arrival(event, verifyZap: NostrEventVerifier.isValid(json:)) else { return }
                arrival.ring = GlobeArcs.ring(of: arrival.author, follows: people.follows, discover: people.discover)
                guard rings.contains(arrival.ring),
                      let judged = Self.judged(arrival, event: event, reach: reach[arrival.ring] ?? .web) else { return }
                self?.emit(judged)
            })
        }
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
                // Every feed in turn, so each shell's stars show.
                let ring = GlobeArcs.Ring.allCases[n % GlobeArcs.Ring.allCases.count]
                // Every third one a zap, to someone: a bolt rather than a star.
                // Every fourth a reaction: a smaller star, to one person.
                // A storm is mostly notes and reactions, as the network is.
                let zap = storm > 0 ? n % 25 == 0 : n % 3 == 0
                let reaction = !zap && (storm > 0 ? n % 3 == 0 : n % 4 == 0)
                let zapped = targets.first ?? people.filter { $0 != author }.randomElement()!
                var arrival = GlobeArcs.Arrival(id: id, author: author, targets: zap || reaction ? [zapped] : targets, ring: ring,
                                                zap: zap, sort: zap ? .zap : reaction ? .reaction : .note,
                                                strength: GlobeArcs.zapStrength(sats: [21, 1_000, 21_000, 100_000].randomElement()!))
                // Every fifth a made-up stranger the gate refused: it bounces.
                if n % 5 == 4 {
                    arrival = GlobeArcs.Arrival(id: id, author: String(id.reversed()), targets: [me], ring: .global)
                    arrival.bounced = true
                }
                emit(arrival)
            }
            try? await Task.sleep(for: storm > 0 ? .milliseconds(100) : .milliseconds(Int.random(in: 900...2000)))
        }
    }
    #endif
}

/// "N bounced in the last hour" under the WoT tab's globe: notes the gate
/// refused, each once. Shared, so the counter and the globe's stream agree
/// whichever view is up; a switch of account starts it again.
@MainActor
final class GlobeBounceCount: ObservableObject {
    static let shared = GlobeBounceCount()
    @Published private(set) var lastHour = 0
    private var log = GlobeArcs.BounceLog()
    private var account = ""
    /// Counts down as bounces age out of the hour; only while there are some.
    private var tick: Timer?

    func use(account: String) {
        guard account != self.account else { return }
        self.account = account
        log.clear()
        refresh()
    }

    func record(_ id: String) {
        guard log.record(id, at: Date.timeIntervalSinceReferenceDate) else { return }
        refresh()
    }

    private func refresh() {
        let count = log.count(at: Date.timeIntervalSinceReferenceDate)
        if count != lastHour { lastHour = count }
        if count == 0 {
            tick?.invalidate()
            tick = nil
        } else if tick == nil {
            tick = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }
}

/// The small, faint counter, just above the My Web button: no badge, no
/// sound. A tap opens "Outside your web" in the Vault, where what tagged you
/// from outside is listed.
struct GlobeBounceCounter: View {
    @ObservedObject private var count = GlobeBounceCount.shared
    @AppStorage(LiveArcsSetting.key) private var liveArcsOn = LiveArcsSetting.defaultOn

    var body: some View {
        if liveArcsOn && count.lastHour > 0 {
            Button(action: Self.openOutside) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(LiveArcsPainter.bounceColor)
                        .frame(width: 5, height: 5)
                    Text(GlobeArcs.bounceLabel(count.lastHour))
                        .font(.appSystem(size: 11, weight: .medium))
                        .monospacedDigit()
                }
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.black.opacity(0.25), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .transition(.opacity)
            .accessibilityLabel(Text("\(GlobeArcs.bounceLabel(count.lastHour)), notes to you from outside your web"))
            .accessibilityHint(Text("Opens Outside your web"))
        }
    }

    /// The Vault, on Activity's "Outside your web" filter.
    static func openOutside() {
        NotificationCenter.default.post(name: .havenOpenVault, object: nil)
        // After the Vault's own switch to its first list (iPhone posts it on
        // the next turn), so Outside is where it lands.
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .havenOpenRelayActivity, object: ActivityFilter.outside)
            }
        }
    }
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

    /// A refused note's star: red, small and faint (`GlobeBounce.swift`).
    static let bounceColor = Color(red: 0.93, green: 0.28, blue: 0.28)

    /// Shooting stars, their faint trails, and the lights where they land:
    /// over the stars and threads, under the faces. Refused notes' red
    /// stars go first, under the rest.
    func drawLines(_ context: inout GraphicsContext) {
        let lines = board.lines
        let bounced = lines.filter(\.bounced)
        if !bounced.isEmpty {
            draw(bounced, in: &context, color: Self.bounceColor, brightness: GlobeArcs.bounceBrightness,
                 samples: GlobeArcs.arcSamples(lines: lines.count))
        }
        draw(bounced.isEmpty ? lines : lines.filter { !$0.bounced }, in: &context, color: starColor, brightness: 1,
             samples: GlobeArcs.arcSamples(lines: lines.count))
    }

    private func draw(_ lines: [GlobeArcs.Line], in context: inout GraphicsContext, color: Color,
                      brightness: Double, samples: Int) {
        let unit = max(0.8, k)
        // Lights breathe slowly while they stay.
        let breath = reduceMotion ? 1 : 0.82 + 0.18 * sin(now * 2 * .pi / 2.6)
        var trails = Batch(), tails = Batch(), cores = Batch(), glows = Batch(), rings = Batch()
        var bolts: [GlobeBoltPainter.Shape] = []
        for line in lines {
            let raw = GlobeArcs.stage(of: line, at: now, reduceMotion: reduceMotion)
            let stage = brightness < 1
                ? GlobeArcs.Stage(head: raw.head, trail: raw.trail * brightness, alpha: raw.alpha * brightness, landing: raw.landing)
                : raw
            guard stage.alpha > 0.01 else { continue }
            let a = place(line.from, line.ring), b = place(line.to, nil)
            // A bounced star's whole way is in to the shell: its stage runs
            // over that part of the curve.
            let span = line.bounced ? GlobeArcs.shellHit(from: a, to: b, facing: facing) : 1
            func at(_ t: Double) -> GlobeScene.Projected? {
                project(GlobeArcs.point(from: a, to: b, at: t * span, facing: facing))
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
            // A reaction's star, tail and landing are smaller than a note's;
            // so is a bounced one.
            let sizeIndex = line.bounced ? 1 : Self.sizeIndex(line), size = Self.size(sizeIndex)
            // In flight: the star and its short tail, brightest at the star.
            // A bounced one is always in flight; at the shell, its turn.
            if stage.head < 1 || line.bounced, let head = at(stage.head) {
                // Round the back a star dims smoothly, never switches.
                let behind = GlobeEdge.arc(depth: head.depth)
                // A bounced star's tail runs over a shorter curve: as long on screen.
                let start = max(0, stage.head - GlobeArcs.tailLength / max(span, 0.2))
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
