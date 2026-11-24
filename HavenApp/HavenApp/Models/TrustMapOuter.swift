import Foundation

/// The globe's outer rings: people three or more hops out, as your desktop
/// Vault ranked them (`TrustRankCopy`), one ring per hop. Only your own
/// globe on the WOT tab draws them (plan phase 4, Logen 2026-11-22).
///
/// - `ranked`: a rank copy is here. Each ring's top 300 by score from the
///   copy's globe list, whatever their score (no bar: the feed keeps the
///   bar, the globe shows the best of each ring; Logen 2026-11-23),
///   labelled "found by your desktop Vault".
/// - `waiting`: a desktop Vault is paired but has not sent a rank yet.
///   Faint rings, no people.
/// - `invite`: no desktop Vault. Faint rings and the invite card.
///
/// Android twin: `data/model/TrustMapOuter.kt`.
struct TrustMapOuter: Equatable {
    enum Source: Equatable { case ranked, waiting, invite }

    struct Ring: Equatable, Identifiable {
        let hop: Int
        /// The ring's top from the globe list, best first, at most `shownPeople`.
        let top: [String]
        /// Each of `top`'s link one ring in (`TrustRankCopy.GlobePerson.via`):
        /// the zoomed globe draws a line to them (`GlobeRingZoom`).
        var via: [String: String] = [:]
        /// The people ranked after `top`, best first (`TrustRankCopy.haze`):
        /// the zoomed-out ring's faint, untappable dots (`GlobeHaze`).
        var haze: [String] = []
        var id: Int { hop }
        var count: Int { top.count }
    }

    let source: Source
    /// Inner to outer. Empty when ranked with nobody out there.
    let rings: [Ring]

    static let none = TrustMapOuter(source: .invite, rings: [])

    /// The first outer ring: past your circle (`DiscoveryReach.circleHops`).
    static let firstHop = DiscoveryReach.circleHops + 1
    /// Faint rings drawn with no rank: hops 3 to 5.
    static let faintHops = firstHop...5
    /// Rings drawn from the globe list: hops 3 to 5 (`trustrank.GlobeFromHop`..`GlobeHop`).
    static let rankedHops = firstHop...TrustRankCopy.globeHop
    /// How many people a ring's sheet and its dots show: the engine's per-ring top.
    static let shownPeople = TrustRankCopy.globePerRing

    /// Settings key: the invite card was put away with "Not now". Only
    /// Settings › Feeds › Discovery Reach turns it back on.
    static let inviteHiddenKey = "globeDesktopVaultInviteHidden"

    var isFaint: Bool { source != .ranked }

    /// A hop layer (Hop 3, 4, 5) is picked only once a desktop Vault's
    /// ranking is on this device with that ring in it; until then the
    /// picker greys it out, as the reason to run one (Logen 2026-11-24).
    func unlocks(hop: Int) -> Bool {
        source == .ranked && rings.contains { $0.hop == hop }
    }

    /// The line a greyed hop shows when tapped.
    static let lockedLine = "A desktop Vault unlocks the far rings"

    static func make(copy: TrustRankCopy?, desktopPaired: Bool, hidden: Set<String> = []) -> TrustMapOuter {
        guard let copy else {
            let faint = faintHops.map { Ring(hop: $0, top: []) }
            return TrustMapOuter(source: desktopPaired ? .waiting : .invite, rings: faint)
        }
        // The globe list's first `shownPeople` rows of a hop are that ring's
        // top, best first; any later ones are chain links (contract §5).
        // The top leaves out anyone who shows 0 (haven-go `Globe`), so a
        // 0 row is always a link, even in a ring with under 300 scored.
        var byHop: [Int: [String]] = [:]
        var via: [Int: [String: String]] = [:]
        var seen: [Int: Int] = [:]
        for key in copy.globeOrder {
            guard let person = copy.globe[key], rankedHops.contains(person.hop), person.score > 0 else { continue }
            let n = seen[person.hop, default: 0]
            guard n < shownPeople else { continue }
            seen[person.hop] = n + 1
            guard !hidden.contains(key) else { continue }
            byHop[person.hop, default: []].append(key)
            if !person.via.isEmpty, !hidden.contains(person.via) { via[person.hop, default: [:]][key] = person.via }
        }
        let rings = byHop.keys.sorted().map { hop in
            let top = Set(byHop[hop] ?? [])
            let haze = (copy.haze[hop] ?? []).filter { !hidden.contains($0) && !top.contains($0) }
            return Ring(hop: hop, top: byHop[hop] ?? [], via: via[hop] ?? [:], haze: haze)
        }
        return TrustMapOuter(source: .ranked, rings: rings)
    }

    /// How strong a ring's dots and line are: hop 3 full, hop 4 about 60%,
    /// hop 5 about 35% (plan, two bars).
    static func fade(hop: Int) -> Double {
        switch hop {
        case ...3: return 1
        case 4: return 0.6
        default: return 0.35
        }
    }

    /// A Mac (or a Linux box, which pairs as one) is among your devices.
    /// A Mac is a desktop Vault itself.
    static func desktopPaired(_ devices: [MeshDevice], isDesktop: Bool) -> Bool {
        isDesktop || devices.contains { $0.role == .mac }
    }

    /// "3 hops". The rank copy has no ring total, so no "best 300 of N";
    /// the sheet's `countText` says how many are shown. Never "people at
    /// 55 and up": the globe has no bar.
    static func chipText(_ ring: Ring) -> String {
        "\(ring.hop) hops"
    }

    /// The sheet's line: "Top 300 by score, whatever their score."
    static func countText(_ ring: Ring) -> String {
        let people = ring.count == 1 ? "person" : "people"
        return "The \(ring.count.formatted()) best-scored \(people) in this ring, whatever their score."
    }

    static let foundLabel = "Found by your desktop Vault"
    static let waitingLabel = "Your desktop Vault hasn't sent its ranking yet"
    static let pairLine = "Pair a desktop Vault to see distant connections"
}
