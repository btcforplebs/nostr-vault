import Foundation
import simd

/// Notes the gate refuses, on the WoT tab's globe (step 7 of
/// RESEARCH/NV_ONE_WOT_GATE.md, Logen go 2026-11-18: "not distracting, a lot
/// of spam"). A refused note flies in as a small, faint red star on the
/// arrival star's own curve, stops at the edge of your web's shell, bounces
/// back out and fades. Reduce Motion: no flight, it fades in place on the
/// shell. No sound, no badge; a small "N bounced in the last hour" counter.
extension GlobeArcs {
    /// What the globe does with an arrival the gate has judged.
    enum Flight: Equatable {
        /// Flies in as today.
        case fly
        /// Red, off the shell.
        case bounce
        /// Nothing at all: someone you blocked or muted never shows, not even red.
        case none
    }

    static func flight(for verdict: WebGate.Verdict) -> Flight {
        switch verdict {
        case .inside, .hop3: .fly
        case .outside: .bounce
        case .blocked: .none
        }
    }

    /// `arrival` (from relay event `event`) as the gate has it: nil when it
    /// shows nothing (blocked, muted), marked bounced and set out from the
    /// outer haze when it is refused, as it was when let in. The signer is
    /// the arrival's author: a repost's reposter, a zap's verified zapper.
    /// The mute list reads the note's own text and tags; a zap's comment
    /// sits inside its request, so a zap is judged on its zapper alone.
    static func judged(_ arrival: Arrival, event: [String: Any], in web: WebGate.Web,
                       reach: WebGate.Reach) -> Arrival? {
        let subject: WebGate.Subject = arrival.zap
            ? WebGate.Subject(signer: arrival.author, id: arrival.id)
            : .note(id: arrival.id, author: arrival.author, content: event["content"] as? String ?? "",
                    tags: event["tags"] as? [[String]] ?? [])
        switch flight(for: WebGate.judge(subject, in: web, reach: reach)) {
        case .fly: return arrival
        case .none: return nil
        case .bounce:
            var out = arrival
            out.bounced = true
            out.ring = .global
            return out
        }
    }

    /// The star's way in to the shell: shorter than a full flight, at the
    /// same pace near enough, so it reads as the same star.
    static let bounceIn: TimeInterval = 1.0
    /// The reflect: back out and gone.
    static let bounceReflect: TimeInterval = 0.35
    static var bounceLife: TimeInterval { bounceIn + bounceReflect }
    /// How far back along its curve the star goes as it bounces, as a share
    /// of its way in.
    static let bounceBack = 0.3
    /// The shell it bounces off: the edge of your wider web.
    static let bounceShell = TrustMap.closeRadius
    /// Faint: a bounced star at this share of an arrival's brightness.
    static let bounceBrightness = 0.55

    /// A bounced line's stage. `head` runs 0 to 1 along its way in to the
    /// shell (the painter maps that onto the curve with `shellHit`), then
    /// back toward 1 - `bounceBack` while it fades. It never lands.
    static func bounceStage(of line: Line, at now: TimeInterval, reduceMotion: Bool = false) -> Stage {
        let age = max(0, now - line.born)
        var head: Double
        var alpha: Double
        if reduceMotion {
            // On the shell, in and out.
            let edge = bounceReflect
            head = 1
            alpha = min(1, age / edge, max(0, bounceLife - age) / edge)
        } else if age < bounceIn {
            head = ease(age / bounceIn)
            alpha = min(1, age / 0.25)
        } else {
            let r = min(1, (age - bounceIn) / bounceReflect)
            // Out fast, then slowing, as off a wall.
            head = 1 - bounceBack * (1 - (1 - r) * (1 - r))
            alpha = 1 - r
        }
        if let retired = line.retired {
            alpha = min(alpha, 1 - min(1, max(0, now - retired) / retireFade))
        }
        alpha = max(0, alpha)
        return Stage(head: head, trail: reduceMotion ? 0 : alpha, alpha: alpha, landing: 0)
    }

    /// How far along the curve from `a` to `b` (0 to 1) it first comes in to
    /// `radius`: where a star bounces. A curve that never comes that close
    /// bounces halfway.
    static func shellHit(from a: SIMD3<Double>, to b: SIMD3<Double>, radius: Double = bounceShell,
                         facing: SIMD3<Double> = SIMD3(0, 0, 1)) -> Double {
        if simd_length(a) <= radius { return 0.5 }
        let steps = 24
        var last = 0.0
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            if simd_length(point(from: a, to: b, at: t, facing: facing)) <= radius {
                // Narrow it between the last sample outside and this one.
                var lo = last, hi = t
                for _ in 0..<8 {
                    let mid = (lo + hi) / 2
                    if simd_length(point(from: a, to: b, at: mid, facing: facing)) <= radius { hi = mid } else { lo = mid }
                }
                return hi
            }
            last = t
        }
        return 0.5
    }

    /// Notes bounced, for the counter: each once, however many relays send
    /// it, over the last hour.
    struct BounceLog: Equatable {
        static let window: TimeInterval = 3_600
        /// Held at most: past it the oldest go, and the counter stops climbing.
        static let cap = 5_000
        private var order: [(id: String, at: TimeInterval)] = []
        private var ids: Set<String> = []

        static func == (a: BounceLog, b: BounceLog) -> Bool { a.ids == b.ids }

        /// True when `id` is new.
        @discardableResult
        mutating func record(_ id: String, at now: TimeInterval) -> Bool {
            trim(now)
            guard ids.insert(id).inserted else { return false }
            order.append((id, now))
            if order.count > Self.cap {
                ids.remove(order.removeFirst().id)
            }
            return true
        }

        mutating func count(at now: TimeInterval) -> Int {
            trim(now)
            return order.count
        }

        mutating func clear() {
            order = []
            ids = []
        }

        private mutating func trim(_ now: TimeInterval) {
            let cutoff = now - Self.window
            let stale = order.prefix { $0.at < cutoff }.count
            guard stale > 0 else { return }
            for entry in order.prefix(stale) { ids.remove(entry.id) }
            order.removeFirst(stale)
        }
    }

    /// The counter's words.
    static func bounceLabel(_ count: Int) -> String {
        "\(count) bounced in the last hour"
    }
}
