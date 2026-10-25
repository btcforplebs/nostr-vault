import Foundation

/// Where the owner's own event goes. NIP-65: an author's notes are read from
/// the write relays in their kind 10002, so those relays decide "Posted". The
/// app's Write relays get the event as well, but no longer count: an account
/// made in another app otherwise showed "Posted" from relay.damus.io while its
/// followers' relays never had it (Android, 2026-10-25). Port of
/// PublishTargets.kt.
enum PublishTargets {
    struct Plan: Equatable {
        /// One of these taking the event is what "Posted" means.
        var confirmed: [String]
        /// Sent to as well, not waited on.
        var alsoSend: [String]
        var all: [String] { confirmed + alsoSend }
    }

    /// `authorWriteRelays` nil or empty (no kind 10002 known) leaves the
    /// app's relays deciding. Loopback relays never count: they always
    /// accept and nobody else can read them.
    static func plan(authorWriteRelays: [String]?, appWriteRelays: [String]) -> Plan {
        let own = clean(authorWriteRelays ?? [])
        let app = clean(appWriteRelays)
        if own.isEmpty { return Plan(confirmed: app, alsoSend: []) }
        let ownKeys = Set(own.map(key))
        return Plan(confirmed: own, alsoSend: app.filter { !ownKeys.contains(key($0)) })
    }

    private static func clean(_ relays: [String]) -> [String] {
        var seen = Set<String>()
        return relays.map(normalized).filter { !$0.isEmpty && !isLoopback($0) && seen.insert(key($0)).inserted }
    }

    private static func normalized(_ url: String) -> String {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while u.hasSuffix("/") { u.removeLast() }
        return u
    }

    private static func key(_ url: String) -> String { normalized(url).lowercased() }

    private static func isLoopback(_ url: String) -> Bool {
        let u = url.lowercased()
        return u.contains("127.0.0.1") || u.contains("localhost") || u.contains("[::1]") || u.contains("0.0.0.0")
    }
}
