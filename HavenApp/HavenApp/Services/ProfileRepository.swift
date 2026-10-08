import Foundation

/// Pure profile and relay-list cache operations — load, save, and parse.
/// No Combine, no @Published, no SwiftUI. All file I/O is explicit.
/// Direct translation target for Kotlin (Room DB or DataStore).
enum ProfileRepository {

    // MARK: - File Paths

    private static func havenSupportDir() -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Haven")
        }
        let havenDir = appSupport.appendingPathComponent("Haven", isDirectory: true)
        try? FileManager.default.createDirectory(at: havenDir, withIntermediateDirectories: true)
        return havenDir
    }

    static var profilesURL: URL { havenSupportDir().appendingPathComponent("profiles.json") }
    static var relayListsURL: URL { havenSupportDir().appendingPathComponent("relay_lists.json") }
    static var outboxRelaysURL: URL { havenSupportDir().appendingPathComponent("outbox_relays.json") }
    static var dmRelayListsURL: URL { havenSupportDir().appendingPathComponent("dm_relay_lists.json") }
    static var serverListsURL: URL { havenSupportDir().appendingPathComponent("server_lists.json") }

    // MARK: - Load from Disk

    static func loadProfiles() -> [String: FeedProfile] {
        guard let data = try? Data(contentsOf: profilesURL),
              let loaded = try? JSONDecoder().decode([String: FeedProfile].self, from: data) else { return [:] }
        return loaded
    }

    static func loadRelayLists() -> [String: [String]] {
        guard let data = try? Data(contentsOf: relayListsURL),
              let loaded = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return loaded
    }

    static func loadOutboxRelays() -> [String: [String]] {
        guard let data = try? Data(contentsOf: outboxRelaysURL),
              let loaded = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return loaded
    }

    static func loadDMRelayLists() -> [String: [String]] {
        guard let data = try? Data(contentsOf: dmRelayListsURL),
              let loaded = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return loaded
    }

    static func loadServerLists() -> [String: [String]] {
        guard let data = try? Data(contentsOf: serverListsURL),
              let loaded = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return loaded
    }

    // MARK: - Save to Disk (background queue)

    static func saveProfiles(_ profiles: [String: FeedProfile]) {
        let copy = profiles
        DispatchQueue.global(qos: .utility).async {
            let dir = havenSupportDir()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(copy) {
                try? data.write(to: profilesURL)
            }
        }
    }

    static func saveRelayLists(_ lists: [String: [String]]) {
        let copy = lists
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(copy) { try? data.write(to: relayListsURL) }
        }
    }

    static func saveOutboxRelays(_ lists: [String: [String]]) {
        let copy = lists
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(copy) { try? data.write(to: outboxRelaysURL) }
        }
    }

    static func saveDMRelayLists(_ lists: [String: [String]]) {
        let copy = lists
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(copy) { try? data.write(to: dmRelayListsURL) }
        }
    }

    static func saveServerLists(_ lists: [String: [String]]) {
        let copy = lists
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(copy) { try? data.write(to: serverListsURL) }
        }
    }

    // MARK: - Event Parsing (pure functions)

    /// Parses Kind 0 (Metadata) event content into profile field updates.
    /// Returns the updated profile and whether any field actually changed,
    /// or nil if the content isn't valid JSON.
    static func parseMetadataContent(
        _ content: String,
        pubkey: String,
        existingProfile: FeedProfile?,
        createdAt: Int64? = nil
    ) -> (profile: FeedProfile, changed: Bool)? {
        if let createdAt, let existing = existingProfile?.metadataCreatedAt, existing > createdAt {
            return nil
        }
        guard let metadata = try? JSONSerialization.jsonObject(
            with: content.data(using: .utf8) ?? Data()
        ) as? [String: Any] else { return nil }

        let name = metadata["name"] as? String
        let displayName = metadata["display_name"] as? String
        let picture = (metadata["picture"] as? String).flatMap { URL(string: $0) }
        let banner = (metadata["banner"] as? String).flatMap { URL(string: $0) }
        let nip05 = metadata["nip05"] as? String
        let about = metadata["about"] as? String
        let lud16 = metadata["lud16"] as? String
        let lud06 = metadata["lud06"] as? String
        let website = metadata["website"] as? String

        var profile = existingProfile ?? FeedProfile(pubkey: pubkey)
        var changed = false

        if profile.name != name { profile.name = name; changed = true }
        if profile.displayName != displayName { profile.displayName = displayName; changed = true }
        if profile.pictureURL != picture { profile.pictureURL = picture; changed = true }
        if profile.bannerURL != banner { profile.bannerURL = banner; changed = true }
        if profile.nip05 != nip05 { profile.nip05 = nip05; changed = true }
        if profile.about != about { profile.about = about; changed = true }
        if profile.lud16 != lud16 { profile.lud16 = lud16; changed = true }
        if profile.lud06 != lud06 { profile.lud06 = lud06; changed = true }
        if profile.website != website { profile.website = website; changed = true }
        if let createdAt { profile.metadataCreatedAt = createdAt }

        return (profile, changed)
    }

    /// Parses Kind 10002 (Relay List Metadata / NIP-65) tags into inbox and write relay lists.
    /// Tags: ["r", relay_url, "read" | "write"], no marker = both.
    static func parseRelayListTags(_ tags: [[String]]) -> (inbox: [String], write: [String]) {
        var inbox: [String] = []
        var write: [String] = []
        for tag in tags {
            guard tag.count >= 2, tag[0] == "r" else { continue }
            let marker = tag.count >= 3 ? tag[2] : ""
            if marker == "read" || marker == "" { inbox.append(tag[1]) }
            if marker == "write" || marker == "" { write.append(tag[1]) }
        }
        return (inbox, write)
    }

    /// Parses Kind 10050 (NIP-17 DM Relay List) tags into relay URLs.
    /// NIP-17 tags are ["relay", relay_url]. ["r", relay_url] is also read
    /// because older Nostr Vault builds published that shape.
    static func parseDMRelayListTags(_ tags: [[String]]) -> [String] {
        var seen = Set<String>()
        return tags.compactMap { tag in
            guard tag.count >= 2, tag[0] == "relay" || tag[0] == "r" else { return nil }
            return seen.insert(tag[1]).inserted ? tag[1] : nil
        }
    }

    /// Parses Kind 10063 (BUD-03 User Server List) tags into Blossom server URLs.
    /// Tags: ["server", url].
    static func parseServerListTags(_ tags: [[String]]) -> [String] {
        tags.compactMap { tag in
            tag.count >= 2 && tag[0] == "server" ? tag[1] : nil
        }
    }

    /// Parses Kind 10000 (Mute List) p-tags into blocked hex pubkeys.
    static func parseMuteListPTags(_ tags: [[String]]) -> [String] {
        tags.compactMap { tag in
            tag.count >= 2 && tag[0] == "p" ? tag[1] : nil
        }
    }

    /// Converts hex pubkeys to npub strings for mute list storage.
    static func hexKeysToNpubs(_ hexKeys: [String]) -> [String] {
        hexKeys.compactMap { hexKey in
            guard let data = Bech32.hexToData(hexKey) else { return nil }
            return Bech32.encode(hrp: "npub", data: data)
        }
    }
}
