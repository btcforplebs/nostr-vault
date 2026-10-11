import Foundation

extension HavenConfig {
    // MARK: - Relay roles

    /// Where features read when the owner has no read relays.
    static let fallbackRelays = ["wss://relay.primal.net", "wss://nos.lol"]

    /// Where the owner's events go when there are no write relays: the
    /// default broadcast list (`blastrRelays`).
    static let fallbackWriteRelays = ["wss://relay.btcforplebs.com", "wss://relay.damus.io", "wss://relay.snort.social"]

    /// The relays features read other people's events from: the feed relays
    /// (Mac relay first), or `fallbackRelays` when there are none. Ask this
    /// rather than building a list per feature.
    var readRelays: [String] {
        let relays = activeFeedRelays
        return relays.isEmpty ? Self.fallbackRelays : relays
    }

    /// The relays the owner's events are sent to: the broadcast relays (Mac
    /// relay first), or `fallbackWriteRelays` when there are none.
    var writeRelays: [String] {
        let relays = activeBlastrRelays
        return relays.isEmpty ? Self.fallbackWriteRelays : relays
    }

    /// The owner's own relays others can reach: the Haven domain (unless it is
    /// this device only) and the Mac relay.
    var ownPublicRelays: [String] {
        var relays: [String] = []
        if !isLocal { relays.append("wss://\(sanitizedRelayURL)") }
        relays.append(macRelayWssURL)
        return relays
    }

    /// NIP-65 kind 10002 tags: the relay list other clients use for this
    /// account. It is the grid's Read and Write columns, so the world sees
    /// what the owner actually uses.
    var publicRelayListTags: [[String]] {
        Self.publicRelayListTags(ownRelays: ownPublicRelays, read: feedRelays, write: blastrRelays)
    }

    /// The owner's own relays go first with no marker, which NIP-65 reads as
    /// both read and write, so they always stay in Write. Then each relay in
    /// both lists has no marker, and one in only one list is marked "read" or
    /// "write". Only wss:// relays others can reach are listed, once each.
    static func publicRelayListTags(ownRelays: [String], read: [String], write: [String]) -> [[String]] {
        func key(_ url: String) -> String { url.lowercased() }
        func publishable(_ raw: String) -> String? {
            let url = normalizedRelayURL(raw)
            guard url.lowercased().hasPrefix("wss://") else { return nil }
            let hostPort = String(url.dropFirst("wss://".count))
            guard !hostPort.isEmpty, !isPrivateNetworkHost(hostPort) else { return nil }
            return url
        }
        let readKeys = Set(read.compactMap(publishable).map(key))
        let writeKeys = Set(write.compactMap(publishable).map(key))
        var seen = Set<String>()
        var tags: [[String]] = []
        for url in ownRelays.compactMap(publishable) where seen.insert(key(url)).inserted {
            tags.append(["r", url])
        }
        for url in (read + write).compactMap(publishable) where seen.insert(key(url)).inserted {
            switch (readKeys.contains(key(url)), writeKeys.contains(key(url))) {
            case (true, true): tags.append(["r", url])
            case (true, false): tags.append(["r", url, "read"])
            default: tags.append(["r", url, "write"])
            }
        }
        return tags
    }
}
