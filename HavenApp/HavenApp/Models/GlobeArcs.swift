import Foundation
import simd

/// Live arrival arcs on the Web of Trust globe. Every note reaching the
/// relay flies a star. A reply, quote or repost flies between its two
/// parties: from its author to each person it is aimed at. A note aimed at
/// no one flies into you at the center. Where a star sets out says which
/// feed it came from: your follows from the ring, Discover from the next
/// shell out, Global from the outer haze (Logen, 10/14).
enum GlobeArcs {
    /// Most lines on the globe at once. A new one past this sends the oldest
    /// on its way out early, so the globe never fills up with lines.
    static let maxLines = 10
    /// People one note draws lines to: a reply to a crowd stays a few lines.
    static let maxTargets = 4
    /// Arrivals waiting their turn. A burst past this drops its oldest:
    /// the globe shows what is arriving now, not a backlog.
    static let maxWaiting = 8
    /// Arrivals are let onto the globe at most this often, so a burst
    /// reads as a stream rather than a flash.
    static let spacing: TimeInterval = 0.7
    /// A star travels from its author to its target over this long,
    static let travel: TimeInterval = 2.0
    /// its faint trail fades this long after it lands,
    static let trailFade: TimeInterval = 1.2
    /// and the light where it landed stays this long
    static let hold: TimeInterval = 2.6
    /// and fades over this long.
    static let fade: TimeInterval = 2.2
    /// How much of the line, behind the star, its tail covers.
    static let tailLength = 0.16
    static var life: TimeInterval { travel + hold + fade }
    /// A line sent out early to make room fades this fast.
    static let retireFade: TimeInterval = 0.7
    /// A note older than this when it arrives is a relay catching up, not an arrival.
    static let maxAge: TimeInterval = 180
    /// Notes, replies and quotes, and NIP-22 comments: Amethyst, Ditto,
    /// Coracle and Snort send a reply to a note as a kind 1111 comment, and
    /// the feed takes them in, so leaving them out lost those replies.
    static let kinds = [1, NIP10Thread.commentKind]
    /// Reposts (kind 6) and generic reposts (kind 16): the reposter to the
    /// person reposted.
    static let repostKinds = [6, 16]

    /// The feed a note came in on, which sets where its star starts.
    enum Ring: String, CaseIterable, Comparable {
        case following, discover, global

        var title: String {
            switch self {
            case .following: "Following"
            case .discover: "Discover"
            case .global: "Global"
            }
        }

        /// Off the globe, an author's star starts on this shell. Your follows
        /// start where their own star is, on the ring.
        var radius: Double {
            switch self {
            case .following: TrustMap.ringRadius
            case .discover: TrustMap.closeRadius
            case .global: TrustMap.outerRadius
            }
        }

        static func < (a: Ring, b: Ring) -> Bool { a.order < b.order }
        private var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    }

    /// One note: who wrote it, who it is aimed at, and the feed it came in on.
    struct Arrival: Equatable {
        let id: String
        let author: String
        let targets: [String]
        var ring: Ring = .following
    }

    /// From a relay `EVENT`'s event: its `p` tags in order, once each,
    /// without the author. nil for anything that isn't a fresh note or repost.
    static func arrival(_ event: [String: Any], now: Date = Date()) -> Arrival? {
        guard let kind = event["kind"] as? Int, kinds.contains(kind) || repostKinds.contains(kind),
              let id = event["id"] as? String, isKey(id),
              let author = event["pubkey"] as? String, isKey(author) else { return nil }
        if let created = event["created_at"] as? Double,
           now.timeIntervalSince1970 - created > maxAge { return nil }
        let tags = event["tags"] as? [[String]] ?? []
        // Comments on videos, articles and the like aren't conversation.
        if kind == NIP10Thread.commentKind, !NIP10Thread.isNoteComment(kind: kind, tags: tags) { return nil }
        // A reply flies to the person it answers, not to everyone in the thread.
        if let to = repliedTo(kind: kind, tags: tags), to != author {
            return Arrival(id: id, author: author, targets: [to])
        }
        // A reply we can't place (no pubkey slot, no p tag) doesn't fly: only
        // a note aimed at no one lands on you.
        if isReply(kind: kind, tags: tags), repliedTo(kind: kind, tags: tags) == nil { return nil }
        var targets: [String] = []
        for tag in tags where tag.count > 1 && tag[0] == "p" {
            let key = tag[1].lowercased()
            guard isKey(key), key != author, !targets.contains(key) else { continue }
            targets.append(key)
            if targets.count == maxTargets { break }
        }
        // A repost with no p tag (most of them on some relays) has no one to
        // point at: like any note aimed at no one, it flies into you.
        return Arrival(id: id, author: author, targets: targets)
    }

    /// Who a reply answers: the author of the event it replies to. NIP-10
    /// puts it in the parent `e` tag's fifth slot; a NIP-22 comment in its
    /// `e` tag's fourth slot and its lowercase `p`. Without that, the first
    /// `p` tag, the same rule the feed's reply line uses. nil for a note
    /// that isn't a reply (a quote's `e` is a mention, not a parent).
    static func repliedTo(kind: Int, tags: [[String]]) -> String? {
        func key(_ s: String?) -> String? { s.map { $0.lowercased() }.flatMap { isKey($0) ? $0 : nil } }
        if kind == NIP10Thread.commentKind {
            let e = tags.first { $0.count >= 2 && $0[0] == "e" }
            return key(e.flatMap { $0.count > 3 ? $0[3] : nil })
                ?? key(tags.first { $0.count >= 2 && $0[0] == "p" }?[1])
        }
        guard kinds.contains(kind), let parent = NIP10Thread.parentEventId(kind: kind, tags: tags) else { return nil }
        let e = tags.first { $0.count >= 2 && $0[0] == "e" && $0[1] == parent }
        return key(e.flatMap { $0.count > 4 ? $0[4] : nil })
            ?? key(tags.first { $0.count >= 2 && $0[0] == "p" }?[1])
    }

    /// True for a note that answers another: a comment on a note, or a
    /// kind 1 note with a parent `e` tag (a quote's mention isn't one).
    static func isReply(kind: Int, tags: [[String]]) -> Bool {
        kind == NIP10Thread.commentKind || (kind == 1 && NIP10Thread.parentEventId(kind: kind, tags: tags) != nil)
    }

    /// Which feed a note's author belongs to: yours and your follows' are
    /// Following, your wider web's Discover, anyone else's Global.
    static func ring(of author: String, follows: Set<String>, discover: Set<String>) -> Ring {
        follows.contains(author) ? .following : discover.contains(author) ? .discover : .global
    }

    private static func isKey(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }
    }

    struct Line: Equatable {
        /// The note it carries.
        let note: String
        let from: String
        let to: String
        /// Aimed at you, or at no one and so flying into you.
        let toMe: Bool
        /// The feed its note came in on: where its star sets out.
        var ring: Ring = .following
        let born: TimeInterval
        /// Set when a newer line needs the room: it fades from here.
        var retired: TimeInterval?
    }

    /// Where a line is at a moment: its star at `head` (0 at the author, 1 at
    /// the target), its faint trail behind at `trail`, and the light where it
    /// lands at `alpha`.
    struct Stage: Equatable {
        let head: Double
        let trail: Double
        let alpha: Double
        /// 0 to 1 as the line lands: the target's light swells, then settles.
        let landing: Double
    }

    /// Everything live on the globe, and what is waiting to go on.
    struct Board {
        private(set) var lines: [Line] = []
        private(set) var waiting: [Arrival] = []
        private var seen: [String] = []
        private var lastRelease: TimeInterval = -.infinity

        var isIdle: Bool { lines.isEmpty && waiting.isEmpty }

        /// Queues a note; one already seen (another relay sent it too) is
        /// skipped. Past the waiting cap the oldest of the widest feed goes,
        /// so a busy Global never pushes out a note from someone you follow.
        mutating func add(_ arrival: Arrival) {
            guard !seen.contains(arrival.id) else { return }
            seen.append(arrival.id)
            if seen.count > 256 { seen.removeFirst(seen.count - 256) }
            waiting.append(arrival)
            while waiting.count > GlobeArcs.maxWaiting, let widest = waiting.map(\.ring).max(),
                  let i = waiting.firstIndex(where: { $0.ring == widest }) {
                waiting.remove(at: i)
            }
        }

        /// Lets the next note on when its turn comes and drops what has faded.
        /// Returns the note let on, if any.
        @discardableResult
        mutating func step(now: TimeInterval, me: String) -> Arrival? {
            lines.removeAll { GlobeArcs.isGone($0, at: now) }
            guard !waiting.isEmpty, now - lastRelease >= GlobeArcs.spacing else { return nil }
            let next = waiting.removeFirst()
            lastRelease = now
            // Aimed at no one: it flies into you, where your relay is.
            for target in next.targets.isEmpty ? [me] : next.targets where target != next.author {
                lines.append(Line(note: next.id, from: next.author, to: target, toMe: target == me,
                                  ring: next.ring, born: now))
            }
            // Over the cap: the oldest still-standing lines start their fade now.
            var standing = lines.filter { $0.retired == nil }.count
            for i in lines.indices where standing > GlobeArcs.maxLines && lines[i].retired == nil {
                lines[i].retired = now
                standing -= 1
            }
            return next
        }

        mutating func clear() {
            lines = []
            waiting = []
        }
    }

    static func stage(of line: Line, at now: TimeInterval, reduceMotion: Bool = false) -> Stage {
        let age = max(0, now - line.born)
        let head = reduceMotion ? 1 : ease(min(1, age / travel))
        let landed = reduceMotion ? age : age - travel
        let landing = reduceMotion ? 0 : max(0, min(1, landed / 1.2))
        var alpha = 1.0
        if age > travel + hold { alpha = 1 - min(1, (age - travel - hold) / fade) }
        var trail = landed > 0 ? 1 - min(1, landed / trailFade) : 1
        if let retired = line.retired {
            let out = 1 - min(1, max(0, now - retired) / retireFade)
            alpha = min(alpha, out)
            trail = min(trail, out)
        }
        if age < 0.25 { alpha = min(alpha, age / 0.25) }
        return Stage(head: head, trail: min(trail, alpha), alpha: max(0, alpha), landing: landing)
    }

    /// True once a line has faded out for good. Not `alpha <= 0`: a line is
    /// also at 0 the instant it is let on (it fades in), and the globe can
    /// draw that instant twice, which dropped every star before it flew.
    static func isGone(_ line: Line, at now: TimeInterval) -> Bool {
        if let retired = line.retired, now - retired >= retireFade { return true }
        return now - line.born >= travel + hold + fade
    }

    /// True once the star has reached its target.
    static func hasLanded(_ line: Line, at now: TimeInterval) -> Bool { now - line.born >= travel }

    /// How brightly an endpoint's face shows: in as its line sets out,
    /// out as it fades.
    static func faceAlpha(of line: Line, at now: TimeInterval) -> Double {
        let age = now - line.born
        let fadeIn = min(1, max(0, age / 0.8))
        return min(fadeIn, stage(of: line, at: now).alpha)
    }

    /// The biggest REQ message sent to one relay. Relays cap a message's
    /// size (relay.btcforplebs.com at 128 KB) and refuse a bigger one whole,
    /// with a NOTICE: every filter in it is lost, not just the extra ones.
    /// Tied to `GlobeArrivalStream.authorsPerFilter` (500): one 500-author
    /// filter is about 33.5 KB, so this fits one or two. A single filter
    /// past about 890 authors goes over again and is sent on its own.
    static let maxRequestBytes = 60_000

    /// `filters` as REQ messages, each with its own subscription id and
    /// under `maxBytes` (a single filter bigger than that goes on its own).
    /// Filters keep their order.
    static func requests(_ filters: [[String: Any]], subId: String,
                         maxBytes: Int = maxRequestBytes) -> [String] {
        func text(_ id: String, _ group: [[String: Any]]) -> String? {
            guard let data = try? JSONSerialization.data(withJSONObject: ["REQ", id] + group, options: [.sortedKeys]) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        var groups: [[[String: Any]]] = []
        var current: [[String: Any]] = []
        for filter in filters {
            let candidate = current + [filter]
            if !current.isEmpty, (text(subId, candidate)?.utf8.count ?? 0) > maxBytes {
                groups.append(current)
                current = [filter]
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups.enumerated().compactMap { i, group in
            text(groups.count == 1 ? subId : "\(subId)-\(i)", group)
        }
    }

    static func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }

    /// A point `t` of the way along a line from `a` to `b`, lifted off the
    /// globe so it reads as a flight rather than a cut through it. `facing`
    /// is toward the viewer: a line bent to one side bends across the screen.
    static func point(from a: SIMD3<Double>, to b: SIMD3<Double>, at t: Double,
                      facing: SIMD3<Double> = SIMD3(0, 0, 1)) -> SIMD3<Double> {
        let c = control(a, b, facing: facing)
        let u = 1 - t
        return u * u * a + 2 * u * t * c + t * t * b
    }

    /// The bend: away from the core, or to one side when the line runs at
    /// or through the core.
    static func control(_ a: SIMD3<Double>, _ b: SIMD3<Double>,
                        facing: SIMD3<Double> = SIMD3(0, 0, 1)) -> SIMD3<Double> {
        let mid = (a + b) / 2
        let span = simd_length(b - a)
        guard span > 1e-6 else { return mid }
        let lift = 0.32 * span
        let along = (b - a) / span
        // Out from the core, square to the line: a line running into the core
        // has nothing square to it there, and bends sideways instead.
        let out = mid - simd_dot(mid, along) * along
        if simd_length(out) > 0.25 * span {
            return mid + simd_normalize(out) * lift
        }
        var side = simd_cross(along, facing)
        if simd_length(side) < 1e-3 { side = simd_cross(along, SIMD3(0, 1, 0)) }
        if simd_length(side) < 1e-3 { side = simd_cross(along, SIMD3(1, 0, 0)) }
        return mid + simd_normalize(side) * lift
    }
}
