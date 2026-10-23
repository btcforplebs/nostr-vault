import Foundation

/// Which extra relays the Following feed asks, and for whom (the NIP-65
/// outbox model, sized for a phone).
///
/// The feed used to ask only the owner's feed relays, so a follow who never
/// writes to any of them was invisible. Measured 2026-10-04 for an account
/// following 992 people: 56 of the 411 follows with a relay list wrote to
/// none of its 6 feed relays, and 7 of the 9 notes missing from two hours of
/// its feed were on relays it never asked (relay.damus.io alone is a write
/// relay for 241 of those follows).
///
/// Asking every follow's relays would open hundreds of sockets. Instead a
/// greedy cover picks the few relays that reach the most uncovered follows,
/// and each is asked only for the follows it was picked for.
///
/// Most follows publish no relay list at all (581 of those 992), so they go
/// to one fallback relay. Of their notes over three hours, the feed relays
/// had 53 of 59; relay.ditto.pub had all 59 (relay.nostr.net 56, damus 39 and
/// answering 503 that day). Re-measure before changing it.
enum FeedOutboxPlan {
    /// Extra sockets the feed may open on top of the feed relays, fallback
    /// included.
    static let maxExtraRelays = 8
    static let fallbackRelay = "wss://relay.ditto.pub"

    /// What a plan is built from. Equal inputs give the same plan, so a
    /// caller can keep the last plan instead of rebuilding it.
    struct Inputs: Equatable {
        var follows: [String]
        var writeRelays: [String: [String]]
        var feedRelays: [String]
        var unreachableRelays: Set<String>
    }

    static func plan(_ inputs: Inputs) -> [String: [String]] {
        plan(follows: inputs.follows,
             writeRelays: inputs.writeRelays,
             feedRelays: inputs.feedRelays,
             unreachableRelays: Array(inputs.unreachableRelays))
    }

    /// - Parameters:
    ///   - follows: the authors the feed shows.
    ///   - writeRelays: each author's NIP-65 write relays, where known.
    ///   - feedRelays: the relays the feed already asks for everyone.
    ///   - unreachableRelays: relays failing right now. A follow whose only
    ///     feed relay is down is not reached by it, and a down relay is never
    ///     picked.
    ///   - fallbackRelay: asked for the follows with no usable relay list;
    ///     nil to skip them.
    /// - Returns: extra relay URL → the follows to ask it for (sorted). Each
    ///   follow appears under one relay only: the first pick that reached them.
    static func plan(follows: [String],
                     writeRelays: [String: [String]],
                     feedRelays: [String],
                     unreachableRelays: [String] = [],
                     fallbackRelay: String? = fallbackRelay,
                     maxExtraRelays: Int = maxExtraRelays) -> [String: [String]] {
        let down = Set(unreachableRelays.compactMap(normalizedKey))
        let asked = Set(feedRelays.compactMap(normalizedKey)).subtracting(down)
        // Follows none of whose write relays the feed already asks, with the
        // relays that would reach them.
        var candidates: [String: Set<String>] = [:]   // relay key → follows
        var urlForKey: [String: String] = [:]
        var unlisted = Set<String>()
        // The same few hundred relay URLs recur across the follows; parse each once.
        var keyForRaw: [String: String?] = [:]
        for author in Set(follows) {
            let usable = (writeRelays[author] ?? []).compactMap { raw -> String? in
                let parsed: String?
                if let known = keyForRaw[raw] {
                    parsed = known
                } else {
                    parsed = normalizedKey(raw)
                    keyForRaw[raw] = parsed
                }
                guard let key = parsed, !down.contains(key) else { return nil }
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

        // Follows become small ints so a round counts each relay's gain over
        // a flag array. Allocating `authors.subtracting(covered)` for every
        // relay every round cost 2.4 s of main thread in 90 s of feed load on
        // an iPhone 12 mini (2026-10-23): the plan is rebuilt each time a
        // follow's relay list arrives.
        var index: [String: Int] = [:]
        var names: [String] = []
        var members: [String: [Int]] = candidates.mapValues { authors in
            authors.map { author in
                if let i = index[author] { return i }
                index[author] = names.count
                names.append(author)
                return names.count - 1
            }
        }
        var covered = [Bool](repeating: false, count: names.count)

        var plan: [String: [String]] = [:]
        // The fallback first: it takes a slot only when someone needs it.
        if !unlisted.isEmpty, let fallbackRelay, let key = normalizedKey(fallbackRelay),
           !asked.contains(key), !down.contains(key), maxExtraRelays > 0 {
            urlForKey[key] = fallbackRelay
            var taken = unlisted
            // Listed follows the fallback relay reaches are taken there too.
            if let reached = members.removeValue(forKey: key) {
                for i in reached {
                    covered[i] = true
                    taken.insert(names[i])
                }
            }
            plan[fallbackRelay] = taken.sorted()
        }
        while plan.count < maxExtraRelays {
            // Most still-uncovered follows wins; ties go to the smaller key so
            // the same inputs always pick the same relays.
            var best: (key: String, gain: Int)?
            var spent: [String] = []
            for (key, authors) in members {
                var gain = 0
                for i in authors where !covered[i] { gain += 1 }
                guard gain > 0 else {
                    spent.append(key)   // can only shrink, so never again
                    continue
                }
                if best == nil || gain > best!.gain || (gain == best!.gain && key < best!.key) {
                    best = (key, gain)
                }
            }
            for key in spent { members.removeValue(forKey: key) }
            guard let pick = best, let url = urlForKey[pick.key] else { break }
            let authors = members.removeValue(forKey: pick.key) ?? []
            var newlyCovered: [String] = []
            for i in authors where !covered[i] {
                covered[i] = true
                newlyCovered.append(names[i])
            }
            plan[url] = newlyCovered.sorted()
        }
        return plan
    }

    /// `wss://Host/` and `wss://host` are one relay. Only public `wss` relays
    /// qualify: a plain `ws://`, a loopback or LAN address, or an onion host
    /// is somebody else's private setup and cannot be reached from this phone.
    static func normalizedKey(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "wss",
              let host = url.host?.lowercased(), host.contains("."),
              !host.hasSuffix(".onion"), !host.hasSuffix(".local"),
              host != "localhost", !host.hasPrefix("127."), !host.hasPrefix("192.168."),
              !host.hasPrefix("10.") else { return nil }
        var key = "wss://\(host)"
        if let port = url.port { key += ":\(port)" }
        let path = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
        return key + path
    }
}
