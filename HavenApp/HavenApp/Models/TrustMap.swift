import Foundation
import simd

/// The pure parts of the Web of Trust globe: where each person sits, which
/// follow lists to ask for next, and the 3-hop "look deeper" chains. No
/// layout is ever iterated: a person's spot comes straight from their key, so
/// the same person sits in the same place every time the globe opens.
enum TrustMap {
    /// Follow lists asked for per "show everyone" batch. Each list is a whole
    /// follow list (~90 KB at 1,000 follows), so one batch is ~2 MB.
    static let batchSize = 20
    /// Stop "show everyone" here (~9 MB). Past it the button asks again.
    static let maxBatchedLists = 100
    /// Lists tagging the author fetched from anyone for "look deeper".
    static let deeperSeeds = 30
    /// Lists from your follows that tag one of those seeds.
    static let deeperLinks = 12
    /// Faces drawn for 3-hop chains; the rest stay dots.
    static let shownChains = 12

    /// Radius of each shell: whoever is in the middle at 0, their follows on
    /// the unit sphere, and people further out on a faint outer shell.
    static let ringRadius = 1.0
    static let outerRadius = 1.62
    /// The author sits between the two shells, so their threads stay short.
    static let authorRadius = 1.32
    /// Outer-shell people drawn per globe. Your follows' follows run to tens
    /// of thousands; past this the shell reads the same and only costs frames.
    static let hazeCap = 2_500

    /// A person's fixed spot on the globe, from their key alone. Longitude and
    /// height come from separate hex digits; taking height straight (not as an
    /// angle) spreads people evenly over the sphere instead of bunching them
    /// at the poles.
    static func direction(of pubkey: String) -> SIMD3<Double> {
        let longitude = fraction(pubkey, from: 0) * 2 * .pi
        let z = fraction(pubkey, from: 8) * 2 - 1
        let r = (1 - z * z).squareRoot()
        return SIMD3(r * cos(longitude), r * sin(longitude), z)
    }

    /// Up to `cap` of `candidates`, picked by key so the same people show
    /// every time: a growing set only swaps people at the margin.
    static func haze(_ candidates: Set<String>, cap: Int = hazeCap) -> [String] {
        guard candidates.count > cap else { return candidates.sorted() }
        return candidates
            .map { (rank: fraction($0, from: 16), key: $0) }
            .sorted { ($0.rank, $0.key) < ($1.rank, $1.key) }
            .prefix(cap)
            .map(\.key)
    }

    private static func fraction(_ pubkey: String, from offset: Int) -> Double {
        let hex = pubkey.dropFirst(offset).prefix(8)
        if hex.count == 8, let value = UInt32(hex, radix: 16) {
            return Double(value) / 4_294_967_296
        }
        // Not hex (only in tests or a malformed tag): FNV-1a, still stable.
        var hash: UInt32 = 2_166_136_261
        for byte in pubkey.utf8.dropFirst(offset) { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return Double(hash) / 4_294_967_296
    }

    /// Up to `count` of `sorted`, evenly spaced through it. Keys sort in
    /// longitude order (that is the key's leading digits), so taking the first few
    /// would bunch every face on one arc; spacing them spreads faces around.
    static func spread(_ sorted: [String], count: Int) -> [String] {
        guard sorted.count > count, count > 0 else { return sorted }
        return (0..<count).map { sorted[$0 * sorted.count / count] }
    }

    /// The next "show everyone" filters: follows whose lists haven't come
    /// back yet, tagging the author, in chunks small enough for relays that
    /// cap a request's size. Empty once every follow has been asked about.
    static func nextBatch(author: String, follows: [String], seen: Set<String>,
                          chunkSize: Int = 1000) -> [[String: Any]] {
        let authors = follows.filter { $0 != author && !seen.contains($0) }
        return stride(from: 0, to: authors.count, by: chunkSize).map { start in
            let chunk = Array(authors[start..<min(start + chunkSize, authors.count)])
            return ["kinds": [3], "authors": chunk, "#p": [author], "limit": batchSize]
        }
    }

    /// The p-tags of the newest follow list `owner` signed: who they follow.
    /// Lists from anyone else are ignored. nil when no list came back.
    static func follows(of owner: String, in lists: [[String: Any]]) -> [String]? {
        var best: (createdAt: Int, tags: [[String]])?
        for list in lists {
            guard list["kind"] as? Int == 3, list["pubkey"] as? String == owner,
                  let tags = list["tags"] as? [[String]] else { continue }
            let createdAt = (list["created_at"] as? Int) ?? 0
            if let best, best.createdAt >= createdAt { continue }
            best = (createdAt, tags)
        }
        guard let best else { return nil }
        var seen = Set<String>()
        return best.tags.compactMap { tag in
            guard tag.count >= 2, tag[0] == "p", tag[1].count == 64, tag[1] != owner,
                  seen.insert(tag[1]).inserted else { return nil }
            return tag[1]
        }
    }

    /// One 3-hop route: you follow `bridge`, who follows `via`, who follows
    /// the author.
    struct Chain: Equatable {
        let bridge: String
        let via: String
    }

    /// Step 1 of "look deeper": anyone's follow list that tags the author.
    static func deeperSeedFilter(author: String) -> [String: Any] {
        ["kinds": [3], "#p": [author], "limit": deeperSeeds]
    }

    /// Who the seed lists say follows the author, minus you, your follows and
    /// the author: those are the possible middle steps. Keeps people already
    /// in your trust graph first when it's loaded, since they are the ones
    /// your follows most likely follow.
    static func deeperVia(author: String, me: String, follows: Set<String>, trustGraph: Set<String>,
                          seeds: [[String: Any]]) -> [String] {
        let candidates = TrustPath.allBridges(author: author, me: me, follows: allSigners(seeds),
                                              contactLists: seeds)
            .filter { !follows.contains($0) }
        guard !trustGraph.isEmpty else { return candidates }
        return candidates.filter(trustGraph.contains) + candidates.filter { !trustGraph.contains($0) }
    }

    /// Step 2: lists from your follows that tag any of the middle steps.
    static func deeperLinkFilters(follows: [String], via: [String], chunkSize: Int = 1000) -> [[String: Any]] {
        guard !via.isEmpty else { return [] }
        return stride(from: 0, to: follows.count, by: chunkSize).map { start in
            let chunk = Array(follows[start..<min(start + chunkSize, follows.count)])
            return ["kinds": [3], "authors": chunk, "#p": via, "limit": deeperLinks]
        }
    }

    /// Every route the link lists show, sorted by middle step then bridge.
    /// Only each follow's newest list counts, as in `TrustPath.resolve`.
    static func chains(me: String, follows: Set<String>, via: [String], links: [[String: Any]]) -> [Chain] {
        let viaSet = Set(via)
        var routes = Set<String>()
        var chains: [Chain] = []
        for bridge in allSigners(links).filter(follows.contains).sorted() where bridge != me {
            for target in Self.follows(of: bridge, in: links) ?? [] where viaSet.contains(target) {
                if routes.insert(bridge + target).inserted {
                    chains.append(Chain(bridge: bridge, via: target))
                }
            }
        }
        return chains.sorted { ($0.via, $0.bridge) < ($1.via, $1.bridge) }
    }

    private static func allSigners(_ lists: [[String: Any]]) -> Set<String> {
        Set(lists.compactMap { $0["pubkey"] as? String })
    }

    // MARK: Faces on someone's own globe

    /// Follows worth fetching a profile for when a globe shows everyone
    /// someone follows: a spread around the sphere, the same people each time.
    static let faceCandidateCount = 48
    /// Follows drawn as faces on that globe; the rest stay stars.
    static let ringFaceCount = 16

    static func faceCandidates(_ ring: [String], count: Int = faceCandidateCount) -> [String] {
        spread(ring.sorted(), count: count)
    }

    /// Faces for a globe of everyone someone follows: people with a picture
    /// first, so the globe shows faces rather than initials, then the rest.
    static func pickFaces(_ candidates: [String], hasPicture: (String) -> Bool,
                          count: Int = ringFaceCount) -> [String] {
        let pictured = candidates.filter(hasPicture)
        let plain = candidates.filter { !hasPicture($0) }
        return Array((pictured + plain).prefix(count))
    }

    // MARK: Finding someone

    /// Someone the WOT tab's search can find: their key and every name they go by.
    struct Person {
        let pubkey: String
        let names: [String]
    }

    /// The WOT tab's search: people you follow first, then your web, then
    /// everyone else; a name that starts with the query before one that only
    /// contains it; shorter names first.
    static func searchPeople(_ query: String, in people: [Person], follows: Set<String>,
                             web: Set<String>, limit: Int = 8) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        var ranked: [(tier: Int, prefix: Int, length: Int, key: String)] = []
        for person in people {
            let names = person.names.map { $0.lowercased() }.filter { $0.contains(q) }
            guard !names.isEmpty else { continue }
            let tier = follows.contains(person.pubkey) ? 0 : web.contains(person.pubkey) ? 1 : 2
            let prefix = names.contains { $0.hasPrefix(q) } ? 0 : 1
            ranked.append((tier, prefix, names.map(\.count).min() ?? 0, person.pubkey))
        }
        return ranked
            .sorted { ($0.tier, $0.prefix, $0.length, $0.key) < ($1.tier, $1.prefix, $1.length, $1.key) }
            .prefix(limit)
            .map(\.key)
    }
}

/// The globe's camera and how it moves. Every step is scaled by the real time
/// since the last frame, so it spins, glides and settles the same at 60Hz and
/// 120Hz.
struct GlobeCamera {
    var orientation = simd_quatd(angle: 0, axis: SIMD3(0, 1, 0))
    /// Angular velocity after a flick, radians a second.
    var spin = SIMD3<Double>(repeating: 0)
    var zoom = 1.0
    var zoomTarget = 1.0
    /// Where a fly-to is turning; nil when not flying.
    var flyTarget: simd_quatd?
    var dragging = false
    /// Frame-clock time of the last touch.
    var lastTouch: TimeInterval = 0

    static let zoomRange = 0.8...2.4
    /// Idle this long and the globe starts drifting, so it reads as alive.
    static let driftAfter: TimeInterval = 3
    /// Idle this long and it stops: the frame clock can sleep.
    static let sleepAfter: TimeInterval = 20
    static let driftSpeed = 0.05
    /// How fast a flick dies away, per second.
    static let spinDecay = 1.6
    /// A frame slower than this counts as this long, so a hitch can't fling it.
    static let maxStep: TimeInterval = 1.0 / 20

    /// The turn that brings `direction` to the front, a little up and right
    /// of the middle, so whoever it is never hides behind the core.
    static func facing(_ direction: SIMD3<Double>) -> simd_quatd {
        simd_quatd(from: simd_normalize(direction), to: simd_normalize(SIMD3(0.42, 0.30, 1)))
    }

    mutating func touch(at now: TimeInterval) { lastTouch = now }

    /// One finger moved by `dx`, `dy` points: turn under it.
    mutating func drag(dx: Double, dy: Double, at now: TimeInterval) {
        let k = 0.009
        let turn = simd_quatd(angle: dx * k, axis: SIMD3(0, 1, 0)) * simd_quatd(angle: dy * k, axis: SIMD3(1, 0, 0))
        orientation = simd_normalize(turn * orientation)
        flyTarget = nil
        spin = .zero
        touch(at: now)
    }

    /// Let go at `vx`, `vy` points a second: keep turning that way.
    mutating func flick(vx: Double, vy: Double, at now: TimeInterval, reduceMotion: Bool) {
        let k = 0.006
        spin = reduceMotion ? .zero : SIMD3(vy * k, vx * k, 0)
        touch(at: now)
    }

    mutating func fly(to target: simd_quatd, at now: TimeInterval) {
        flyTarget = target
        spin = .zero
        zoomTarget = 1
        touch(at: now)
    }

    mutating func step(dt: TimeInterval, now: TimeInterval, reduceMotion: Bool) {
        let dt = min(Self.maxStep, max(0, dt))
        if let target = flyTarget {
            if reduceMotion {
                orientation = target
            } else {
                orientation = simd_slerp(orientation, target, 1 - exp(-dt * 5))
            }
            if reduceMotion || abs(simd_dot(orientation.vector, target.vector)) > 0.99999 {
                orientation = target
                flyTarget = nil
            }
        } else if !dragging && !reduceMotion {
            let speed = simd_length(spin)
            if speed > 0.0005 {
                // The exact turn while the spin decays over this step, not
                // speed × dt: summed per frame, that drifts with the frame rate.
                let decay = exp(-dt * Self.spinDecay)
                let angle = speed * (1 - decay) / Self.spinDecay
                orientation = simd_normalize(simd_quatd(angle: angle, axis: spin / speed) * orientation)
                spin *= decay
            } else {
                spin = .zero
            }
            let idle = now - lastTouch
            if idle > Self.driftAfter && idle < Self.sleepAfter {
                orientation = simd_normalize(simd_quatd(angle: Self.driftSpeed * dt, axis: SIMD3(0, 1, 0)) * orientation)
            }
        }
        if reduceMotion || abs(zoomTarget - zoom) < 0.0005 {
            zoom = zoomTarget
        } else {
            zoom += (zoomTarget - zoom) * (1 - exp(-dt * 7))
        }
    }

    /// Something on screen is still moving, or will start drifting soon:
    /// keep the frame clock running. False is the cue to let it sleep.
    func wantsFrames(now: TimeInterval, reduceMotion: Bool) -> Bool {
        if dragging || flyTarget != nil || spin != .zero || zoom != zoomTarget { return true }
        return !reduceMotion && now - lastTouch < Self.sleepAfter
    }
}
