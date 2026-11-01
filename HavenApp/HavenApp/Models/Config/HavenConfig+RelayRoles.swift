import Foundation

extension HavenConfig {
    // MARK: - Relay roles

    /// Where features read when the owner has no read relays.
    static let fallbackRelays = ["wss://relay.primal.net", "wss://relay.damus.io"]

    /// Former default relays that stopped answering: nos.lol and nostr.mom
    /// time out on the handshake, offchain.pub refuses the connection
    /// (checked 2026-10-12). Dropped once from saved lists; see
    /// `droppedDeadRelays`.
    static let deadRelayHosts: Set<String> = ["nos.lol", "nostr.mom", "offchain.pub"]

    static func isDeadRelay(_ url: String) -> Bool {
        deadRelayHosts.contains(relayHost(url))
    }

    /// Drops `deadRelayHosts` from the saved relay lists, once, so a relay the
    /// owner adds back later stays. Blocked relays are left alone. Run after
    /// the Mac's relay list files are read back, or they would restore them.
    mutating func dropDeadRelaysOnce() {
        guard !droppedDeadRelays else { return }
        let defaults = HavenConfig.default
        importSeedRelays = Self.droppingDeadRelays(importSeedRelays, orElse: defaults.importSeedRelays)
        blastrRelays = Self.droppingDeadRelays(blastrRelays, orElse: defaults.blastrRelays)
        feedRelays = Self.droppingDeadRelays(feedRelays, orElse: defaults.feedRelays)
        dmRelays = Self.droppingDeadRelays(dmRelays, orElse: defaults.dmRelays)
        droppedDeadRelays = true
    }

    // MARK: - The owner's own relay list (kind 10002)

    /// Every relay the app has shipped as a read or write default, current
    /// or former, by host. Lists made only of these were never edited.
    static let shippedRelayHosts: Set<String> = [
        "relay.primal.net", "relay.damus.io", "relay.snort.social", "relay.btcforplebs.com",
        "nostr-pub.wellorder.net", "nos.lol", "nostr.mom", "offchain.pub", "relay.nos.social",
        "nostr.wine", "nostr.land", "relay.nostr.build",
    ]

    static func relayHost(_ url: String) -> String {
        var host = normalizedRelayURL(url).lowercased()
        if let scheme = host.range(of: "://") { host = String(host[scheme.upperBound...]) }
        return String(host.prefix { $0 != "/" && $0 != ":" })
    }

    /// True when the read and write lists hold only relays the app shipped
    /// (entries no one else can reach, such as the Mac or this device, don't
    /// count): the owner never set relays of their own here.
    static func relayListsLookUnedited(read: [String], write: [String]) -> Bool {
        (read + write).filter(RelayDraft.listable).allSatisfy { shippedRelayHosts.contains(relayHost($0)) }
    }

    /// Whether a published kind 10002 dated `publishedAt` replaces this
    /// device's read and write lists: it is newer than the last change here,
    /// and any list replaces the starter relays (`relayListUpdatedAt` nil).
    static func adoptsRelayList(localUpdatedAt: Int64?, publishedAt: Int64) -> Bool {
        publishedAt > (localUpdatedAt ?? 0)
    }

    /// Makes the owner's published relay list (kind 10002, parsed into its
    /// read and write relays) this device's, when `adoptsRelayList` says so.
    /// Relays no one else can reach, known-dead ones and blocked ones are
    /// left out, as Settings > Relays would. A side that ends up empty keeps
    /// what it had. Never publishes anything. Returns whether a list changed.
    @discardableResult
    mutating func adoptRelayList(read: [String], write: [String], publishedAt: Int64) -> Bool {
        guard Self.adoptsRelayList(localUpdatedAt: relayListUpdatedAt, publishedAt: publishedAt) else { return false }
        let blocked = Set(blockedRelays.map { Self.normalizedRelayURL($0).lowercased() })
        func usable(_ list: [String]) -> [String] {
            var seen = Set<String>()
            return list.map(Self.normalizedRelayURL).filter {
                RelayDraft.listable($0) && !Self.isDeadRelay($0)
                    && !blocked.contains($0.lowercased()) && seen.insert($0.lowercased()).inserted
            }
        }
        let newRead = usable(read), newWrite = usable(write)
        relayListUpdatedAt = publishedAt
        var changed = false
        if !newRead.isEmpty, newRead != feedRelays { feedRelays = newRead; changed = true }
        if !newWrite.isEmpty, newWrite != blastrRelays { blastrRelays = newWrite; changed = true }
        return changed
    }

    /// `relays` without the dead ones, or `fallback` if nothing else is left.
    static func droppingDeadRelays(_ relays: [String], orElse fallback: [String]) -> [String] {
        let live = relays.filter { !isDeadRelay($0) }
        return live.isEmpty && !relays.isEmpty ? fallback : live
    }

    /// Where the owner's events go when there are no write relays: the
    /// default broadcast list (`blastrRelays`).
    static let fallbackWriteRelays = starterRelays

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
