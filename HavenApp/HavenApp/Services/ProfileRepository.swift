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

    /// The old single-file profile cache; read once, then replaced by
    /// `profileShardsURL`.
    static var profilesURL: URL { havenSupportDir().appendingPathComponent("profiles.json") }
    static var profileShardsURL: URL { havenSupportDir().appendingPathComponent("profiles", isDirectory: true) }
    static var relayListsURL: URL { havenSupportDir().appendingPathComponent("relay_lists.json") }
    static var outboxRelaysURL: URL { havenSupportDir().appendingPathComponent("outbox_relays.json") }
    static var dmRelayListsURL: URL { havenSupportDir().appendingPathComponent("dm_relay_lists.json") }
    static var serverListsURL: URL { havenSupportDir().appendingPathComponent("server_lists.json") }

    // MARK: - Load from Disk

    /// Loads the profile cache: the shard files, or the old single file
    /// before the first save after this change.
    static func loadProfiles() -> [String: FeedProfile] {
        var loaded: [String: CachedProfile] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: profileShardsURL, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let part = try? JSONDecoder().decode([String: CachedProfile].self, from: data) else { continue }
            loaded.merge(part) { _, new in new }
        }
        // The old file is deleted only after every shard is written, so while
        // it is there it is the cache (a first save may have been cut short).
        let shards: ProfileCacheShards
        if let data = try? Data(contentsOf: profilesURL),
           let legacy = try? JSONDecoder().decode([String: FeedProfile].self, from: data) {
            shards = ProfileCacheShards(legacy: legacy.merging(loaded.mapValues(\.p)) { _, new in new })
        } else {
            shards = ProfileCacheShards(loaded: loaded)
        }
        saveQueue.sync { profileShards = shards }
        return shards.previous
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
        // Once: lists cached before PR 999 were kept without their signature
        // checked, so one may name a relay's node as the author's vault. Start
        // over; each author's list comes back, verified, when it is next seen.
        let migratedKey = "serverLists.verifiedOnly.v2"
        if !UserDefaults.standard.bool(forKey: migratedKey) {
            try? FileManager.default.removeItem(at: serverListsURL)
            UserDefaults.standard.removeObject(forKey: "serverListStamps.v1")
            UserDefaults.standard.set(true, forKey: migratedKey)
            return [:]
        }
        guard let data = try? Data(contentsOf: serverListsURL),
              let loaded = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return loaded
    }

    // MARK: - Save to Disk (background queue)

    /// One save per file at a time, newest waiting value wins
    /// (`LatestOnlySave`).
    private static let saveQueue = DispatchQueue(label: "com.haven.profile-cache.save", qos: .utility)

    private static func saver<Value: Encodable>(_ url: @escaping () -> URL) -> LatestOnlySave<Value> {
        LatestOnlySave(queue: saveQueue) { value in
            if let data = try? JSONEncoder().encode(value) { try? data.write(to: url(), options: .atomic) }
        }
    }

    /// Touched only on `saveQueue`.
    private static var profileShards = ProfileCacheShards(loaded: [:])

    private static let profilesSaver = LatestOnlySave<([String: FeedProfile], Set<String>)>(queue: saveQueue) { profiles, keep in
        let now = Int64(Date().timeIntervalSince1970)
        let writes = profileShards.plan(profiles, now: now, keep: keep)
        guard !writes.isEmpty else { return }
        let dir = profileShardsURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (shard, contents) in writes {
            let file = dir.appendingPathComponent("\(shard).json")
            if contents.isEmpty {
                try? FileManager.default.removeItem(at: file)
            } else if let data = try? JSONEncoder().encode(contents) {
                try? data.write(to: file, options: .atomic)
            }
        }
        try? FileManager.default.removeItem(at: profilesURL)
    }
    private static let relayListsSaver: LatestOnlySave<[String: [String]]> = saver { relayListsURL }
    private static let outboxRelaysSaver: LatestOnlySave<[String: [String]]> = saver { outboxRelaysURL }
    private static let dmRelayListsSaver: LatestOnlySave<[String: [String]]> = saver { dmRelayListsURL }
    private static let serverListsSaver: LatestOnlySave<[String: [String]]> = saver { serverListsURL }

    /// Saves the profiles that changed since the last save. `keep` is never
    /// left off disk by the cap (`ProfileCacheShards`).
    static func saveProfiles(_ profiles: [String: FeedProfile], keep: Set<String>) { profilesSaver.save((profiles, keep)) }
    static func saveRelayLists(_ lists: [String: [String]]) { relayListsSaver.save(lists) }
    static func saveOutboxRelays(_ lists: [String: [String]]) { outboxRelaysSaver.save(lists) }
    static func saveDMRelayLists(_ lists: [String: [String]]) { dmRelayListsSaver.save(lists) }
    static func saveServerLists(_ lists: [String: [String]]) { serverListsSaver.save(lists) }

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
