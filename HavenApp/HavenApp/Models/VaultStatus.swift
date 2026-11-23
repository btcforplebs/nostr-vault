import Foundation

/// What the desktop Vault's trust ranking, distant posts and rank hand-off
/// are doing: the engine's status read (`haven-go/vault_status.go`), from
/// `VaultStatusC` on the Mac, and over the mesh on a phone
/// (`GET /copy/v2/sync/status`, docs/MESH_COPY_V2_CONTRACT.md §6.7).
/// Times are Unix seconds, 0 for never.
struct VaultStatus: Decodable, Equatable {
    var version: Int
    var at: Int64
    /// "running", "paused", "idle" or "off".
    var state: String
    /// When paused: "app" (window open, or Run in background off) or "busy".
    var pausedWhy: String?
    var accounts: [Account]

    struct Account: Decodable, Equatable {
        var account: String
        var running: Bool
        var ring: Int?
        var ringDone: Int?
        var ringTotal: Int?
        var listsRead: Int?
        var refresh: Bool?
        var cut: Bool?
        var finishedAt: Int64
        var capped: Bool?
        var result: Result?
        var distantAtBar: Int
        var distantFetchAt: Int64?
        var distantFetchPeople: Int?
        var distantFetchNew: Int?
        var handoffs: [Handoff]
    }

    struct Result: Decodable, Equatable {
        var builtAt: Int64
        var people: Int
        var maxHop: Int
        var rings: [Int]?
        /// distantByShown[s]: distant connections whose score rounds down to s.
        var distantByShown: [Int]
        var viewBar: Double

        /// Distant connections at or over `bar` (whole steps, as the slider).
        func distant(atBar bar: Double) -> Int {
            let from = max(0, min(100, Int(bar.rounded(.up))))
            guard from < distantByShown.count else { return 0 }
            return distantByShown[from...].reduce(0, +)
        }
    }

    struct Handoff: Decodable, Equatable {
        /// The device's mesh key, hex.
        var device: String
        var role: String?
        /// The name the desktop's My Devices gives it; nil when it has none.
        var name: String?
        var tookAt: Int64?
        var builtAt: Int64?
        var checkedAt: Int64
    }

    static func decode(_ data: Data) -> VaultStatus? {
        try? JSONDecoder().decode(VaultStatus.self, from: data)
    }

    /// The status for `accountHex`, or the first account when it is not ranked here.
    func account(_ accountHex: String) -> Account? {
        accounts.first { $0.account == accountHex.lowercased() } ?? accounts.first
    }
}

/// The words the status screens show, kept apart from the views so the
/// Mac card and the phones' "Your desktop Vault" say the same thing.
enum VaultStatusText {
    /// "Ranking your web", "Paused while the window is open", "Idle".
    static func headline(_ s: VaultStatus) -> String {
        switch s.state {
        case "running": return "Ranking your web"
        case "paused":
            return s.pausedWhy == "busy" ? "Paused while an import or copy runs" : "Paused while the window is open"
        case "off": return "Trust ranking is off here"
        default: return "Idle"
        }
    }

    /// The paused line's how-to, for the "app" reason.
    static func pausedHint(_ s: VaultStatus) -> String? {
        guard s.state == "paused", s.pausedWhy != "busy" else { return nil }
        return "It runs when the window is closed and Run in background is on."
    }

    /// "Ring 3 · 412 of 1,980 lists" while running, or a cut pass's place.
    static func progress(_ a: VaultStatus.Account) -> String? {
        guard let ring = a.ring, ring > 0 else { return nil }
        var line = "Ring \(ring)"
        if let done = a.ringDone, let total = a.ringTotal, total > 0 {
            line += " · \(done.formatted()) of \(total.formatted()) lists"
        } else if let done = a.ringDone, done > 0 {
            line += " · \(done.formatted()) lists read"
        }
        if a.running, let read = a.listsRead, read > 0 {
            line += " · \(read.formatted()) read this run"
        } else if !a.running, a.cut == true {
            line += " · waiting to go on"
        }
        return line
    }

    /// "Finished 2 h ago · 78,855 people ranked", or "Not finished yet".
    static func finished(_ a: VaultStatus.Account, now: Date) -> String {
        guard a.finishedAt > 0 else {
            return a.result == nil ? "No ranking yet" : "Not finished since the last change"
        }
        var line = "Finished \(ago(a.finishedAt, now: now))"
        if let r = a.result { line += " · \(r.people.formatted()) \(r.people == 1 ? "person" : "people") ranked" }
        if a.capped == true { line += " · stopped at the size cap" }
        return line
    }

    /// "87 distant connections at your bar (55)".
    static func distant(_ a: VaultStatus.Account, bar: Double?) -> String? {
        guard let r = a.result else { return nil }
        let used = bar ?? r.viewBar
        let n = r.distant(atBar: used)
        return "\(n.formatted()) distant \(n == 1 ? "connection" : "connections") at your bar (\(Int(used.rounded())))"
    }

    /// "Distant posts fetched 12 min ago · 34 new from 500 people".
    static func distantFetch(_ a: VaultStatus.Account, now: Date) -> String {
        guard let at = a.distantFetchAt, at > 0 else { return "Distant posts not fetched yet" }
        let fresh = a.distantFetchNew ?? 0
        let people = a.distantFetchPeople ?? 0
        return "Distant posts fetched \(ago(at, now: now)) · \(fresh.formatted()) new from \(people.formatted()) \(people == 1 ? "person" : "people")"
    }

    /// "Took the ranking 3 h ago", "Up to date, checked 5 min ago", "Never took it".
    static func handoff(_ h: VaultStatus.Handoff, now: Date) -> String {
        guard let took = h.tookAt, took > 0 else { return "Hasn't taken the ranking yet" }
        return "Took it \(ago(took, now: now))"
    }

    /// "just now", "12 min ago", "3 h ago", "2 days ago".
    static func ago(_ unix: Int64, now: Date) -> String {
        let secs = max(0, Int(now.timeIntervalSince1970) - Int(unix))
        switch secs {
        case ..<60: return "just now"
        case ..<3600: return "\(secs / 60) min ago"
        case ..<86_400: return "\(secs / 3600) h ago"
        default:
            let days = secs / 86_400
            return days == 1 ? "1 day ago" : "\(days) days ago"
        }
    }
}
