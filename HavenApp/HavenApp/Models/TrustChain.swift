import Foundation

/// How someone on the globe connects to you: the chain of `via` links in
/// your desktop Vault's globe list (`TrustRankCopy.globe`), walked back to
/// one of your follows, all on this device with no relay call. Each link is
/// the highest-scored follower one ring nearer (haven-go `trustrank.Globe`).
/// Read only by the globe and the "why?" sheet, never by the feed.
/// Android twin: `data/model/TrustChain.kt`.
enum TrustChain {
    /// From one of your follows (ring 1) out to `pubkey`, nearest first:
    /// `[A, B, them]` for someone three hops out. nil when `pubkey` is not
    /// in the globe list, or the chain breaks: a link that is missing, not
    /// exactly one ring nearer, or a ring-1 link you no longer follow.
    static func links(to pubkey: String, copy: TrustRankCopy?) -> [String]? {
        guard let copy else { return nil }
        let start = pubkey.lowercased()
        guard let first = copy.globePerson(start) else { return nil }
        var out = [start]
        var at = first
        // Hops go down by one each step, so this ends within GlobeHop steps.
        while at.hop > 2 {
            guard let next = copy.globePerson(at.via), next.hop == at.hop - 1 else { return nil }
            out.append(at.via)
            at = next
        }
        guard at.hop == 2, copy[at.via]?.hop == 1 else { return nil }
        out.append(at.via)
        return out.reversed()
    }

    /// "You > Alice > Bob > Carol".
    static func text(_ links: [String], name: (String) -> String) -> String {
        (["You"] + links.map(name)).joined(separator: " > ")
    }
}
