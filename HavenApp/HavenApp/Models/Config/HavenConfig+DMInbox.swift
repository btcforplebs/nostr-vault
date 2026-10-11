import Foundation

extension HavenConfig {
    // MARK: - DM Inbox (NIP-17)

    /// The owner's always-on Haven inbox as a DM relay, or "" when there is
    /// none. On iOS that is the Mac relay; on a Mac it is this relay itself,
    /// once it has a public address. Only a wss:// address counts: the list it
    /// joins is published for other people, and a plain ws:// LAN address is
    /// unreachable to them.
    var ownHavenDMInboxURL: String {
        #if os(macOS)
        guard !isLocal, !Self.isPrivateNetworkHost(sanitizedRelayURL) else { return "" }
        return Self.normalizedRelayURL(nostrURL + "/inbox")
        #else
        let base = macRelayNormalizedBase
        guard !base.isEmpty else { return "" }
        let typed = macRelayURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if typed.hasPrefix("ws://") || typed.hasPrefix("http://") { return "" }
        // A home-network address typed without a scheme would otherwise be
        // published to everyone as wss://…, put first, and be undeliverable.
        if Self.isPrivateNetworkHost(base) { return "" }
        return Self.normalizedRelayURL("wss://\(base)/inbox")
        #endif
    }

    /// True for an address only this network can reach: loopback, private
    /// and link-local IPv4/IPv6 ranges, CGNAT (Tailscale's 100.64.0.0/10),
    /// `localhost`, `.local`, and bare names with no dot. `hostPort` may carry
    /// a port and a path ("192.168.1.20:3355/x").
    static func isPrivateNetworkHost(_ hostPort: String) -> Bool {
        var host = hostPort.lowercased()
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        if host.hasPrefix("[") {
            // [IPv6]:port
            host = String(host.dropFirst().prefix { $0 != "]" })
        } else if host.filter({ $0 == ":" }).count == 1, let colon = host.firstIndex(of: ":") {
            host = String(host[..<colon])
        }
        while host.hasSuffix(".") { host = String(host.dropLast()) }
        if host.hasPrefix("::ffff:") {
            // IPv4-mapped IPv6: judge the IPv4 address it carries.
            let v4 = String(host.dropFirst("::ffff:".count))
            if v4.contains(".") { return isPrivateNetworkHost(v4) }
        }
        if host.isEmpty || host == "localhost" { return true }
        // Home-network names, plus Tailscale MagicDNS: a .ts.net name only
        // reaches outsiders through Funnel, so it can't be relied on.
        for suffix in [".localhost", ".local", ".lan", ".home.arpa", ".internal", ".ts.net"] where host.hasSuffix(suffix) {
            return true
        }
        if host.contains(":") {
            // IPv6: loopback, unspecified, unique-local fc00::/7, link-local fe80::/10
            return host == "::1" || host == "::" || host.hasPrefix("fc") || host.hasPrefix("fd")
                || host.hasPrefix("fe8") || host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb")
        }
        let octets = host.split(separator: ".").map { Int($0) }
        if octets.count == 4, octets.allSatisfy({ $0 != nil }) {
            let o = octets.map { $0! }
            switch (o[0], o[1]) {
            case (10, _), (127, _), (0, _): return true
            case (172, 16...31), (192, 168), (169, 254): return true
            case (100, 64...127): return true
            default: return false
            }
        }
        return !host.contains(".")
    }

    /// The one DM inbox list: where other people send this account's DMs,
    /// where this account's own sent copies go, and where every device reads
    /// DMs from. The owner's Haven inbox comes first, then `dmRelays`.
    var dmInboxRelays: [String] {
        Self.mergedDMInboxRelays(havenInbox: ownHavenDMInboxURL, dmRelays: dmRelays)
    }

    static func mergedDMInboxRelays(havenInbox: String, dmRelays: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for raw in [havenInbox] + dmRelays {
            let url = normalizedRelayURL(raw)
            guard !url.isEmpty, seen.insert(url.lowercased()).inserted else { continue }
            result.append(url)
        }
        return result
    }

    /// Whether the active account (as a hex pubkey) moving from `previous` to
    /// `current` is a switch the app should react to. No account to an
    /// account is setup finishing, not a switch.
    static func isAccountSwitch(from previous: String, to current: String) -> Bool {
        !previous.isEmpty && previous != current
    }

    /// Trims whitespace and trailing slashes so the same relay typed two ways
    /// compares equal.
    static func normalizedRelayURL(_ raw: String) -> String {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url = String(url.dropLast()) }
        return url
    }

    /// What launch should do with the DM inbox list, given this device's list
    /// and the newest one published for the account.
    enum DMInboxSyncAction: Equatable {
        /// Take the published list (and its timestamp) as this device's own.
        case adopt
        /// Publish this device's list: nothing is published, or ours is newer.
        case publish
        /// Already in step.
        case none
    }

    /// `published` is the newest kind 10050 found (nil = none found);
    /// `publishedAt` its created_at. `local` is this device's merged list.
    static func dmInboxSyncAction(local: [String], localUpdatedAt: Int64?,
                                  published: [String]?, publishedAt: Int64?) -> DMInboxSyncAction {
        guard let published, let publishedAt else {
            // Nothing found. For a list that was never set that means no list
            // is published, so publish one. A device that has synced before
            // more likely just couldn't reach the relays this launch, and
            // publishing would overwrite a newer list it never saw.
            return localUpdatedAt == nil ? .publish : .none
        }
        let localAt = localUpdatedAt ?? 0
        if publishedAt > localAt { return .adopt }
        if localAt > publishedAt { return .publish }
        // Compared as sets: two devices that order the same relays differently
        // must not keep republishing over each other (each publish can ask the
        // signer app for an approval).
        let same = Set(local.map { normalizedRelayURL($0).lowercased() }) == Set(published.map { normalizedRelayURL($0).lowercased() })
        return same ? .none : .publish
    }
}
