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
        // The fallback first: it takes a slot only when someone needs it.
        if !unlisted.isEmpty, let fallbackRelay, let key = normalizedKey(fallbackRelay),
           !asked.contains(key), !down.contains(key), maxExtraRelays > 0 {
            plan[fallbackRelay] = unlisted.sorted()
            urlForKey[key] = fallbackRelay
            // Listed follows the fallback relay reaches are taken there too.
            if let reached = candidates.removeValue(forKey: key) {
                plan[fallbackRelay] = unlisted.union(reached).sorted()
                covered.formUnion(reached)
            }
        }
        while plan.count < maxExtraRelays {
            // Most still-uncovered follows wins; ties go to the smaller key so
            // the same inputs always pick the same relays.
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
