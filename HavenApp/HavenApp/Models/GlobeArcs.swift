import Foundation
import simd

/// Live arrival arcs on the Web of Trust globe. A note reaching the relay
/// draws one line from its author to each person it is aimed at: one to you
/// for a note to you, one to each person a reply or quote is for. A note
/// aimed at no one only lights its author.
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
    /// A landed note's preview: up this long, at most this many at once.
    static let previewLife: TimeInterval = 4.5
    static let maxPreviews = 2
    /// Characters of a note's first line a preview shows.
    static let previewLength = 140
    static var life: TimeInterval { travel + hold + fade }
    /// A line sent out early to make room fades this fast.
    static let retireFade: TimeInterval = 0.7
    /// A light on its own, for a note aimed at no one.
    static let pulseLife: TimeInterval = 2.4
    /// A note older than this when it arrives is a relay catching up, not an arrival.
    static let maxAge: TimeInterval = 180
    /// Notes, replies and quotes.
    static let kinds = [1]

    /// One note: who wrote it, who it is aimed at, and its first line.
    struct Arrival: Equatable {
        let id: String
        let author: String
        let targets: [String]
        var text: String = ""
    }

    /// From a relay `EVENT`'s event: its `p` tags in order, once each,
    /// without the author. nil for anything that isn't a fresh note.
    static func arrival(_ event: [String: Any], now: Date = Date()) -> Arrival? {
        guard let kind = event["kind"] as? Int, kinds.contains(kind),
              let id = event["id"] as? String, isKey(id),
              let author = event["pubkey"] as? String, isKey(author) else { return nil }
        if let created = event["created_at"] as? Double,
           now.timeIntervalSince1970 - created > maxAge { return nil }
        var targets: [String] = []
        for tag in event["tags"] as? [[String]] ?? [] where tag.count > 1 && tag[0] == "p" {
            let key = tag[1].lowercased()
            guard isKey(key), key != author, !targets.contains(key) else { continue }
            targets.append(key)
            if targets.count == maxTargets { break }
        }
        return Arrival(id: id, author: author, targets: targets,
                       text: firstLine(event["content"] as? String ?? ""))
    }

    /// A note's first line with words in it, for its preview: links and
    /// `nostr:` references dropped, spaces collapsed, cut at a word.
    static func firstLine(_ content: String) -> String {
        for line in content.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: \.isWhitespace).filter {
                !$0.hasPrefix("http://") && !$0.hasPrefix("https://") && !$0.hasPrefix("nostr:")
            }
            guard !words.isEmpty else { continue }
            var text = ""
            for word in words {
                let next = text.isEmpty ? String(word) : text + " " + word
                if next.count > previewLength {
                    return text.isEmpty ? String(next.prefix(previewLength)) + "…" : text + "…"
                }
                text = next
            }
            return text
        }
        return ""
    }

    private static func isKey(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }
    }

    struct Line: Equatable {
        /// The note it carries.
        let note: String
        let from: String
        let to: String
        /// Aimed at you: its preview goes first.
        let toMe: Bool
        let born: TimeInterval
        /// Set when a newer line needs the room: it fades from here.
        var retired: TimeInterval?
    }

    struct Pulse: Equatable {
        let key: String
        let born: TimeInterval
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
        private(set) var pulses: [Pulse] = []
        private(set) var waiting: [Arrival] = []
        /// The notes still waiting or carried by a line, for their previews.
        /// Nothing else: a note dropped from the queue or faded out goes.
        private(set) var notes: [String: Arrival] = [:]
        private var seen: [String] = []
        private var lastRelease: TimeInterval = -.infinity

        var isIdle: Bool { lines.isEmpty && pulses.isEmpty && waiting.isEmpty }

        /// Queues a note; one already seen (another relay sent it too) is skipped.
        mutating func add(_ arrival: Arrival) {
            guard !seen.contains(arrival.id) else { return }
            seen.append(arrival.id)
            if seen.count > 256 { seen.removeFirst(seen.count - 256) }
            waiting.append(arrival)
            notes[arrival.id] = arrival
            if waiting.count > GlobeArcs.maxWaiting {
                waiting.removeFirst(waiting.count - GlobeArcs.maxWaiting)
                forgetDropped()
            }
        }

        /// Keeps only the notes still waiting or on a line.
        private mutating func forgetDropped() {
            let live = Set(lines.map(\.note) + waiting.map(\.id))
            notes = notes.filter { live.contains($0.key) }
        }

        /// Lets the next note on when its turn comes and drops what has faded.
        /// Returns the note let on, if any.
        @discardableResult
        mutating func step(now: TimeInterval, me: String) -> Arrival? {
            let before = lines.count
            lines.removeAll { GlobeArcs.stage(of: $0, at: now).alpha <= 0 }
            if lines.count != before { forgetDropped() }
            pulses.removeAll { now - $0.born >= GlobeArcs.pulseLife }
            guard !waiting.isEmpty, now - lastRelease >= GlobeArcs.spacing else { return nil }
            let next = waiting.removeFirst()
            lastRelease = now
            if next.targets.isEmpty {
                pulses.append(Pulse(key: next.author, born: now))
                notes[next.id] = nil
            }
            for target in next.targets {
                lines.append(Line(note: next.id, from: next.author, to: target, toMe: target == me, born: now))
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
            pulses = []
            waiting = []
            notes = [:]
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

    /// True once the star has reached its target.
    static func hasLanded(_ line: Line, at now: TimeInterval) -> Bool { now - line.born >= travel }

    /// How brightly an endpoint's face shows: in as its line sets out,
    /// out as it fades.
    static func faceAlpha(of line: Line, at now: TimeInterval) -> Double {
        let age = now - line.born
        let fadeIn = min(1, max(0, age / 0.8))
        return min(fadeIn, stage(of: line, at: now).alpha)
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
