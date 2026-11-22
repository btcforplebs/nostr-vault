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

    subscript(pubkey: String) -> Person? { people[pubkey.lowercased()] }

    /// The engine's `trustrank.CeilingHop`.
    static let ceilingHop = 6

    /// haven-go `trustrank.ResultPath`.
    static func fileName(account: String) -> String { "wot_rank_\(account).json" }

    /// The file, when it is `account`'s, version 2, and every row is a hex
    /// pubkey with a 0-100 score in rings 1 to maxHop. Anything else is nil:
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
        return TrustRankCopy(account: account, builtAt: builtAt, maxHop: maxHop,
                             viewBar: score(root["viewBar"]) ?? 55, floor: score(root["floor"]) ?? 0,
                             people: people)
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
