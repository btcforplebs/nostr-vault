import Foundation

/// The path from someone on a hop sphere back to you (Logen 2026-11-25):
/// their `via` in the rank copy's globe list, that person's `via`, and so
/// on in toward your follows, each with the ring they sit on. The globe
/// draws a line through each one's spot on its layer to you at the centre
/// (`GlobeOuterRings.drawChain`); a link that is not on screen is skipped.
/// Pure, so the tests and the Android twin can pin it.
enum GlobeChain {
    struct Link: Equatable {
        let key: String
        /// The ring they are on: 1 for your follows, nil when unknown.
        let hop: Int?
    }

    /// `key` first, then each `via` in, ending at one of your follows (hop
    /// 1) or wherever the copy stops knowing. Never loops, never longer than
    /// the rings there are.
    static func links(from key: String, copy: TrustRankCopy?, follows: Set<String>) -> [Link] {
        guard let copy, let first = copy.globePerson(key) else { return [] }
        var out = [Link(key: key, hop: first.hop)]
        var seen: Set<String> = [key]
        var via = first.via
        while !via.isEmpty, seen.insert(via).inserted, out.count <= TrustRankCopy.ceilingHop {
            if follows.contains(via) {
                out.append(Link(key: via, hop: 1))
                break
            }
            let person = copy.globePerson(via)
            out.append(Link(key: via, hop: person?.hop))
            via = person?.via ?? ""
        }
        return out
    }
}
