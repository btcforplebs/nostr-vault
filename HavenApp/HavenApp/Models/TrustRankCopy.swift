import Foundation

/// The Haven's trust rank for one account, as this phone keeps it
/// (`wot_rank_<account>.json` next to the WoT cache; the engine's catch-up
/// writes it, haven-go `copyv2_trust.go`). Only the account's follows and
/// people who show `floor` or more are in it. Scores are 0-100 on the shown
/// scale; hops are true follow distances, 1 to 6.
///
/// A phone with no Haven has no file, and so no scores (Logen 2026-11-22).
/// Android twin: `data/model/TrustRankCopy.kt`.
struct TrustRankCopy: Equatable {
    struct Person: Equatable {
        let score: Double
        let hop: Int
    }

    /// One row of the globe list: `via` is their highest-scored follower one
    /// ring in, the next link of the chain back to you.
    struct GlobePerson: Equatable {
        let score: Double
        let hop: Int
        let via: String
    }

    let account: String
    /// Unix seconds: when the Haven ranked. The file's age.
    let builtAt: Int64
    /// The furthest ring the Haven's pass reached.
    let maxHop: Int
    /// Where the slider starts (shown scale).
    let viewBar: Double
    /// People under this did not travel.
    let floor: Double
    let people: [String: Person]
    /// The globe list (`globe` in the file), keys in file order: for each
    /// ring 3 to 5 its top first, then chain links. Only the globe and the
    /// "how they connect" chain read it, never the feed (plan, two bars).
    /// Empty when the file has none (an engine from before G1).
    let globeOrder: [String]
    let globe: [String: GlobePerson]

    init(account: String, builtAt: Int64, maxHop: Int, viewBar: Double, floor: Double,
         people: [String: Person], globeOrder: [String] = [], globe: [String: GlobePerson] = [:]) {
        self.account = account
        self.builtAt = builtAt
        self.maxHop = maxHop
        self.viewBar = viewBar
        self.floor = floor
        self.people = people
        self.globeOrder = globeOrder
        self.globe = globe
    }

    subscript(pubkey: String) -> Person? { people[pubkey.lowercased()] }

    /// A globe row, for the globe and the chain only.
    func globePerson(_ pubkey: String) -> GlobePerson? { globe[pubkey.lowercased()] }

    /// The engine's `trustrank.CeilingHop`.
    static let ceilingHop = 6
    /// The engine's `trustrank.GlobeHop`: the furthest ring the globe list covers.
    static let globeHop = 5
    /// The engine's `trustrank.GlobePerRing`: each ring's top, best first.
    static let globePerRing = 300
    /// At most this many globe rows (chain links need links of their own:
    /// 9 x `globePerRing`). docs/MESH_COPY_V2_CONTRACT.md §5 says the number;
    /// `TrustMapOuterTests` reads it from there so the two cannot drift.
    static let maxGlobeRows = 9 * globePerRing

    /// haven-go `trustrank.ResultPath`.
    static func fileName(account: String) -> String { "wot_rank_\(account).json" }

    /// The file, when it is `account`'s, version 2, and every row is a hex
    /// pubkey with a 0-100 score in rings 1 to maxHop, and every globe row (when
    /// there are any, at most `maxGlobeRows`) a hex pubkey with a 0-100 score in
    /// rings 2 to 5 (and maxHop) and a hex `via`. Anything else is nil:
    /// the same checks the engine made before keeping it
    /// (`trustrank.CheckHandoff`), made again because a file on disk is only
    /// as good as whoever wrote it last.
    static func parse(_ data: Data, account: String) -> TrustRankCopy? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["account"] as? String == account,
              integer(root["version"]) == 2,
              let builtAt = integer(root["builtAt"]), builtAt > 0,
              let maxHop = integer(root["maxHop"]).map(Int.init), (1...ceilingHop).contains(maxHop),
              let rows = root["people"] as? [Any]
        else { return nil }
        var people: [String: Person] = [:]
        people.reserveCapacity(rows.count)
        for row in rows {
            // Numbers, not numbers in quotes: the engine's file never quotes them.
            guard let cells = row as? [Any], cells.count == 3,
                  let pk = cells[0] as? String, isHex64(pk),
                  let score = number(cells[1]), (0...100).contains(score),
                  let hop = integer(cells[2]).map(Int.init), (1...maxHop).contains(hop)
            else { return nil }
            people[pk] = Person(score: score, hop: hop)
        }
        guard let rowsGlobe = parseGlobe(root["globe"], maxHop: maxHop) else { return nil }
        var globe: [String: GlobePerson] = [:]
        globe.reserveCapacity(rowsGlobe.count)
        var order: [String] = []
        order.reserveCapacity(rowsGlobe.count)
        // A key twice keeps its first row (the engine never writes one twice).
        for row in rowsGlobe where globe[row.pubkey] == nil {
            globe[row.pubkey] = row.person
            order.append(row.pubkey)
        }
        return TrustRankCopy(account: account, builtAt: builtAt, maxHop: maxHop,
                             viewBar: score(root["viewBar"]) ?? 55, floor: score(root["floor"]) ?? 0,
                             people: people, globeOrder: order, globe: globe)
    }

    /// The optional `globe` list (haven-go `trustrank.CheckHandoff`): missing
    /// or null is empty; anything not a list of good rows is nil.
    private static func parseGlobe(_ value: Any?, maxHop: Int) -> [(pubkey: String, person: GlobePerson)]? {
        if value == nil || value is NSNull { return [] }
        guard let rows = value as? [Any], rows.count <= maxGlobeRows else { return nil }
        var out: [(pubkey: String, person: GlobePerson)] = []
        out.reserveCapacity(rows.count)
        let rings = 2...max(2, min(globeHop, maxHop))
        for row in rows {
            guard let cells = row as? [Any], cells.count == 4,
                  let pk = cells[0] as? String, isHex64(pk),
                  let score = number(cells[1]), (0...100).contains(score),
                  let hop = integer(cells[2]).map(Int.init), rings.contains(hop), hop <= maxHop,
                  let via = cells[3] as? String, isHex64(via)
            else { return nil }
            out.append((pk, GlobePerson(score: score, hop: hop, via: via)))
        }
        return out
    }

    /// A JSON number (not a string, not true/false).
    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    /// A number on the 0-100 shown scale; anything else is as if missing,
    /// so a corrupt bar can never reach the sheet's arithmetic (Tron, #2427).
    private static func score(_ value: Any?) -> Double? {
        number(value).flatMap { (0...100).contains($0) ? $0 : nil }
    }

    /// A JSON whole number: `2`, not `2.5` or `"2"`.
    private static func integer(_ value: Any?) -> Int64? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(n) else { return nil }
        return n.int64Value
    }

    private static func isHex64(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
