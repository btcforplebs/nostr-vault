import XCTest
@testable import MediaLogic

/// `FeedOutboxPlan.plan` counts gain over int flags for speed. These tests pin
/// it to the plain set-based greedy it replaced, on shapes like a real follow
/// list: a few big relays shared by many follows, a long tail of small ones,
/// down relays, follows with no list, and a fallback some listed follows use.
final class FeedOutboxPlanReferenceTests: XCTestCase {
    func testMatchesTheSetBasedGreedyOnRandomFollowLists() {
        var rng = SeededGenerator(seed: 0x5eed)
        for round in 0..<200 {
            let inputs = Self.randomInputs(&rng, follows: Int.random(in: 1...400, using: &rng))
            let cap = round % 5 == 0 ? Int.random(in: 0...3, using: &rng) : FeedOutboxPlan.maxExtraRelays
            let fast = FeedOutboxPlan.plan(follows: inputs.follows, writeRelays: inputs.writeRelays,
                                           feedRelays: inputs.feedRelays, unreachableRelays: inputs.down,
                                           maxExtraRelays: cap)
            let slow = Self.referencePlan(follows: inputs.follows, writeRelays: inputs.writeRelays,
                                          feedRelays: inputs.feedRelays, unreachableRelays: inputs.down,
                                          maxExtraRelays: cap)
            XCTAssertEqual(fast, slow, "round \(round)")
        }
    }

    private struct RandomInputs {
        var follows: [String]
        var writeRelays: [String: [String]]
        var feedRelays: [String]
        var down: [String]
    }

    private static func randomInputs(_ rng: inout SeededGenerator, follows count: Int) -> RandomInputs {
        let big = ["wss://relay.damus.io", "wss://nos.lol", "wss://relay.primal.net",
                   "wss://relay.nostr.band", FeedOutboxPlan.fallbackRelay]
        let tail = (0..<60).map { "wss://r\($0).example" }
        let follows = (0..<count).map { "p\($0)" }
        var lists: [String: [String]] = [:]
        for author in follows where Double.random(in: 0..<1, using: &rng) < 0.45 {
            var relays: [String] = []
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                relays.append(Bool.random(using: &rng) ? big.randomElement(using: &rng)!
                                                       : tail.randomElement(using: &rng)!)
            }
            if Int.random(in: 0..<10, using: &rng) == 0 { relays.append("ws://127.0.0.1:4869") }
            lists[author] = relays
        }
        let feedRelays = Array(big.prefix(Int.random(in: 0...2, using: &rng)))
        let down = (0..<Int.random(in: 0...4, using: &rng)).map { _ in tail.randomElement(using: &rng)! }
        return RandomInputs(follows: follows, writeRelays: lists, feedRelays: feedRelays, down: down)
    }

    /// The greedy as it was before 2026-10-23, kept verbatim as the oracle.
    private static func referencePlan(follows: [String],
                                      writeRelays: [String: [String]],
                                      feedRelays: [String],
                                      unreachableRelays: [String],
                                      fallbackRelay: String? = FeedOutboxPlan.fallbackRelay,
                                      maxExtraRelays: Int) -> [String: [String]] {
        let normalizedKey = FeedOutboxPlan.normalizedKey
        let down = Set(unreachableRelays.compactMap(normalizedKey))
        let asked = Set(feedRelays.compactMap(normalizedKey)).subtracting(down)
        var candidates: [String: Set<String>] = [:]
        var urlForKey: [String: String] = [:]
        var unlisted = Set<String>()
        for author in Set(follows) {
            let usable = (writeRelays[author] ?? []).compactMap { raw -> String? in
                guard let key = normalizedKey(raw), !down.contains(key) else { return nil }
                urlForKey[key] = urlForKey[key] ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return key
            }
            if usable.isEmpty {
                unlisted.insert(author)
                continue
            }
            if usable.contains(where: asked.contains) { continue }
            for key in usable { candidates[key, default: []].insert(author) }
        }
        var plan: [String: [String]] = [:]
        var covered = Set<String>()
        if !unlisted.isEmpty, let fallbackRelay, let key = normalizedKey(fallbackRelay),
           !asked.contains(key), !down.contains(key), maxExtraRelays > 0 {
            plan[fallbackRelay] = unlisted.sorted()
            urlForKey[key] = fallbackRelay
            if let reached = candidates.removeValue(forKey: key) {
                plan[fallbackRelay] = unlisted.union(reached).sorted()
                covered.formUnion(reached)
            }
        }
        while plan.count < maxExtraRelays {
            var best: (key: String, gain: Int)?
            for (key, authors) in candidates {
                let gain = authors.subtracting(covered).count
                guard gain > 0 else { continue }
                if best == nil || gain > best!.gain || (gain == best!.gain && key < best!.key) {
                    best = (key, gain)
                }
            }
            guard let pick = best, let url = urlForKey[pick.key] else { break }
            let authors = candidates.removeValue(forKey: pick.key) ?? []
            let newlyCovered = authors.subtracting(covered)
            covered.formUnion(newlyCovered)
            plan[url] = newlyCovered.sorted()
        }
        return plan
    }
}

/// SplitMix64, so a failing round reproduces.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
