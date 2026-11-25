import Foundation

/// Rank only (haven-go copyv2_rank_only.go, Logen 2026-11-25): a phone
/// paired with a Mac or a box pulls its trust rank right away, with no
/// first copy. A device this one copied from keeps its catch-up, which
/// brings the rank as before; every other paired desktop gets a rank pull
/// (`RankPullC`), signed by this device's mesh key, never the account key.
/// Pure, so MediaLogicTests checks it. Android twin: `MeshRankPull.kt`.
enum MeshRankPull {
    static let startPath = "/copy/v2/rank-start"
    static let pulledMarker = "RANK_PULLED peer="

    /// A pull's end line: `RANK_PULLED peer=<npub> got=<n>[ error=<code>]`.
    struct Pulled: Equatable {
        let peer: String
        let got: Int
        let error: String
    }

    /// The kind 27235 tags for POST <base>/copy/v2/rank-start: `u` without
    /// the ingress path (A checks the path), POST, and `p` = A's mesh npub.
    static func startTags(base: URL, receiver: String) -> [[String]]? {
        let receiver = receiver.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = base.scheme, let host = base.host, !host.isEmpty, !receiver.isEmpty else { return nil }
        let port = base.port.map { ":\($0)" } ?? ""
        return [["u", "\(scheme)://\(host)\(port)\(startPath)"], ["method", "POST"], ["p", receiver]]
    }

    /// The end line, or nil for any other line (a timestamp may lead it).
    static func parse(_ line: String) -> Pulled? {
        guard let r = line.range(of: pulledMarker) else { return nil }
        if r.lowerBound != line.startIndex, !line[line.index(before: r.lowerBound)].isWhitespace { return nil }
        var fields: [String: String] = [:]
        for part in line[r.lowerBound...].split(separator: " ") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { fields[String(kv[0])] = String(kv[1]) }
        }
        guard let peer = fields["peer"], peer.hasPrefix("npub1"), peer.count == 63,
              let got = fields["got"].flatMap({ Int($0) }) else { return nil }
        return Pulled(peer: peer, got: got, error: fields["error"] ?? "")
    }

    /// The paired desktops (a Mac or a box, `.mac`) that get a rank pull:
    /// not one this device copied from (its catch-up brings the rank) and
    /// not the one a first copy is pending with.
    static func peers(_ devices: [MeshDevice], copied: [String: Int], pending: String?) -> [String] {
        devices.filter { $0.role == .mac && copied[$0.npub] == nil && $0.npub != pending }.map(\.npub)
    }

    /// Of those, the ones due now: never pulled since the app started, or
    /// last pulled `MeshRankNudge.recheckEvery` ago (the nudge brings a new
    /// rank sooner).
    static func due(_ devices: [MeshDevice], copied: [String: Int], pending: String?,
                    pulledAt: [String: Int], now: Int) -> [String] {
        peers(devices, copied: copied, pending: pending).filter {
            guard let at = pulledAt[$0] else { return true }
            return now - at >= Int(MeshRankNudge.recheckEvery)
        }
    }

    /// A pull cut short (lost link, stopped) is due again at once.
    static func cutShort(_ error: String) -> Bool { MeshCopyV2.Record.cutShort.contains(error) }
}
