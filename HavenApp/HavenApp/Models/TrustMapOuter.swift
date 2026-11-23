import Foundation

/// The globe's outer rings: people three or more hops out, as your desktop
/// Vault ranked them (`TrustRankCopy`), one ring per hop. Only your own
/// globe on the WOT tab draws them (plan phase 4, Logen 2026-11-22).
///
/// - `ranked`: a rank copy is here. Rings with someone over the Discovery
///   reach bar, labelled "found by your desktop Vault".
/// - `waiting`: a desktop Vault is paired but has not sent a rank yet.
///   Faint rings, no people.
/// - `invite`: no desktop Vault. Faint rings and the invite card.
///
/// Android twin: `data/model/TrustMapOuter.kt`.
struct TrustMapOuter: Equatable {
    enum Source: Equatable { case ranked, waiting, invite }

    struct Ring: Equatable, Identifiable {
        let hop: Int
        /// Everyone in this ring over the bar.
        let count: Int
        /// The highest-scored of them, best first, at most `shownPeople`.
        let top: [String]
        var id: Int { hop }
    }

    let source: Source
    /// Inner to outer. Empty when ranked with nobody out there.
    let rings: [Ring]
    /// The bar the counts are at, nil unless ranked.
    let bar: Double?

    static let none = TrustMapOuter(source: .invite, rings: [], bar: nil)

    /// The first outer ring: past your circle (`DiscoveryReach.circleHops`).
    static let firstHop = DiscoveryReach.circleHops + 1
    /// Faint rings drawn with no rank: hops 3 to 5.
    static let faintHops = firstHop...5
    /// How many people a ring's sheet and its dots show.
    static let shownPeople = 200

    /// Settings key: the invite card was put away with "Not now". Only
    /// Settings › Feeds › Discovery Reach turns it back on.
    static let inviteHiddenKey = "globeDesktopVaultInviteHidden"

    var isFaint: Bool { source != .ranked }

    static func make(copy: TrustRankCopy?, bar: Double?, desktopPaired: Bool,
                     hidden: Set<String> = []) -> TrustMapOuter {
        guard let copy, let bar else {
            let faint = faintHops.map { Ring(hop: $0, count: 0, top: []) }
            return TrustMapOuter(source: desktopPaired ? .waiting : .invite, rings: faint, bar: nil)
        }
        var byHop: [Int: [(String, Double)]] = [:]
        for (pubkey, person) in copy.people where person.hop >= firstHop && person.score >= bar {
            guard !hidden.contains(pubkey) else { continue }
            byHop[person.hop, default: []].append((pubkey, person.score))
        }
        let rings = byHop.keys.sorted().map { hop -> Ring in
            let people = byHop[hop] ?? []
            // Best first; equal scores by key so the order never shuffles.
            let top = people.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
                .prefix(shownPeople).map(\.0)
            return Ring(hop: hop, count: people.count, top: Array(top))
        }
        return TrustMapOuter(source: .ranked, rings: rings, bar: bar)
    }

    /// A Mac (or a Linux box, which pairs as one) is among your devices.
    /// A Mac is a desktop Vault itself.
    static func desktopPaired(_ devices: [MeshDevice], isDesktop: Bool) -> Bool {
        isDesktop || devices.contains { $0.role == .mac }
    }

    /// "3 hops · 2,015".
    static func chipText(_ ring: Ring) -> String {
        "\(ring.hop) hops · \(ring.count.formatted())"
    }

    /// The sheet's line: "2,015 people at score 55 and up."
    static func countText(_ ring: Ring, bar: Double?) -> String {
        let people = ring.count == 1 ? "person" : "people"
        guard let bar else { return "\(ring.count.formatted()) \(people)." }
        return "\(ring.count.formatted()) \(people) at score \(Int(bar)) and up."
    }

    static let foundLabel = "Found by your desktop Vault"
    static let waitingLabel = "Your desktop Vault hasn't sent its ranking yet"
    static let pairLine = "Pair a desktop Vault to see distant connections"
}
