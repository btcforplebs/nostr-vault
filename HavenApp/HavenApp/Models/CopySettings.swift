import Foundation

/// The settings that travel with the mesh copy and stay synced after it
/// (docs/MESH_COPY_V2_CONTRACT.md §5, `settings-allowlist.json`,
/// `settings-refuse-cases.json`). Only the allowlisted keys, mapped from this
/// app's config: never a key, an NWC string, the mesh key, My Devices, the
/// device name or the home vault choice. Android's twin is `CopySettings.kt`.
///
/// The file is `copy-settings.json` in the relay root (`haven_database/`, the
/// folder that holds `.env`). The app writes it whenever a listed setting
/// changes; the engine writes the catch-up's winner there, and the app
/// applies that. Pure Foundation so MediaLogicTests reads the fixtures.
enum CopySettings {
    static let fileName = "copy-settings.json"
    /// A file dated further ahead than this is refused.
    static let futureSlack: Int64 = 600

    /// Compact View's layout, retired 11/11. A linked device on an older
    /// build may still send it; it reads (and is sent on) as expanded.
    static let retiredLayout = "condensed"

    static func cleanLayouts(_ layouts: [String: String]) -> [String: String] {
        layouts.mapValues { $0 == retiredLayout ? FeedLayoutMode.expanded.rawValue : $0 }
    }

    /// Whether a file still holds the retired layout, so it is written over
    /// with the clean one.
    static func holdsRetiredLayout(_ keys: [String: Any]) -> Bool {
        (keys["feed_layouts"] as? [String: String])?.values.contains(retiredLayout) ?? false
    }

    enum ValueType: String {
        case bool, int
        case strings = "string[]"
        case objectString = "object<string>"
        case objectBool = "object<bool>"
    }

    /// settings-allowlist.json, key for key (a test checks they match).
    static let allowlist: [String: ValueType] = [
        "feed_layouts": .objectString,
        "zaps_only": .bool,
        "auto_load_new_posts": .bool,
        "new_posts_pill": .bool,
        "wot_depth": .int,
        "blocked_relays": .strings,
        "dm_relays": .strings,
        "media_servers": .strings,
        "notifications": .objectBool,
    ]
    static let wotDepthRange = 0...3

    private static let secretMarkers = ["nsec1", "ncryptsec1", "nostr+walletconnect:", "bunker:"]

    // MARK: Export (this app's config → the contract keys)

    /// The allowlisted keys for `config`. A home vault or Mac on the mesh is
    /// this device's own media server, never sent.
    static func keys(_ config: HavenConfig) -> [String: Any] {
        let prefs = config.notificationPrefsPerAccount[config.ownerNpub] ?? NotificationPreferences()
        return [
            "feed_layouts": cleanLayouts(config.feedLayoutModes),
            "zaps_only": config.zapsOnlyMode,
            "auto_load_new_posts": config.autoLoadNewPosts,
            "new_posts_pill": config.showNewPostsPill,
            "wot_depth": RelayAccessLimits.clampedFollowDistance(config.chatRelayWotDepth),
            "blocked_relays": config.blockedRelays,
            "dm_relays": config.dmRelays,
            "media_servers": config.blossomMirrors.filter { !onMesh($0) },
            "notifications": [
                "mentions": prefs.mentions, "replies": prefs.replies, "dms": prefs.dms, "zaps": prefs.zaps,
                "reactions": prefs.reactions, "reposts": prefs.reposts, "follows": prefs.follows,
            ],
        ]
    }

    /// The whole file: `{v:1, updated_at, keys}`, sorted for a stable diff.
    static func fileData(keys: [String: Any], updatedAt: Int64) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["v": 1, "updated_at": updatedAt, "keys": keys],
                                    options: [.sortedKeys])
    }

    /// Whether this device's settings differ from the file's (so the app
    /// writes a new file dated now): true when applying the file would change
    /// something here. A file may hold only some keys (or some notification
    /// switches), so the raw key maps are not compared: applying the engine's
    /// winner and saving must not make a newer file of its own.
    static func differs(_ config: HavenConfig, from fileKeys: [String: Any]?) -> Bool {
        guard let fileKeys else { return true }
        let mine = keys(config)
        return !(NSDictionary(dictionary: mine).isEqual(to: keys(apply(fileKeys, to: config))))
    }

    /// A media server on the mesh (`fipsmesh://…` or a `.fips` host).
    static func onMesh(_ url: String) -> Bool {
        let lower = url.lowercased()
        if lower.hasPrefix("fipsmesh://") { return true }
        return URL(string: lower)?.host?.hasSuffix(".fips") == true
    }

    // MARK: Apply (a checked file → this app's config)

    /// `config` with every key in `keys` applied; a key the file lacks keeps
    /// this device's value. Call only with keys `check` passed.
    static func apply(_ keys: [String: Any], to config: HavenConfig) -> HavenConfig {
        var c = config
        if let v = keys["feed_layouts"] as? [String: String] { c.feedLayoutModes = cleanLayouts(v) }
        if let v = bool(keys["zaps_only"]) { c.zapsOnlyMode = v }
        if let v = bool(keys["auto_load_new_posts"]) { c.autoLoadNewPosts = v }
        if let v = bool(keys["new_posts_pill"]) { c.showNewPostsPill = v }
        if let v = int(keys["wot_depth"]) { c.chatRelayWotDepth = RelayAccessLimits.clampedFollowDistance(v) }
        if let v = keys["blocked_relays"] as? [String] { c.blockedRelays = v }
        if let v = keys["dm_relays"] as? [String] { c.dmRelays = v }
        if let v = keys["media_servers"] as? [String] {
            // This device's own mesh servers stay: they are never in the file.
            var out: [String] = []
            for u in v + config.blossomMirrors.filter(onMesh) where !out.contains(u) { out.append(u) }
            c.blossomMirrors = out
        }
        if let n = keys["notifications"] as? [String: Any] {
            var p = c.notificationPrefsPerAccount[c.ownerNpub] ?? NotificationPreferences()
            func on(_ k: String, _ now: Bool) -> Bool { bool(n[k]) ?? now }
            p.mentions = on("mentions", p.mentions)
            p.replies = on("replies", p.replies)
            p.dms = on("dms", p.dms)
            p.zaps = on("zaps", p.zaps)
            p.reactions = on("reactions", p.reactions)
            p.reposts = on("reposts", p.reposts)
            p.follows = on("follows", p.follows)
            c.notificationPrefsPerAccount[c.ownerNpub] = p
        }
        return c
    }

    // MARK: The refuse check (the engine's, again here before writing or applying)

    struct Checked {
        let updatedAt: Int64
        let keys: [String: Any]
    }

    enum Refusal: String {
        case badVersion = "bad_version"
        case unknownKey = "unknown_key"
        case badType = "bad_type"
        case secretValue = "secret_value"
    }

    /// The checked file, or why it may not be written or applied. Secrets
    /// are looked for first, in the whole file.
    static func check(_ data: Data, now: Int64) -> Result<Checked, RefusalError> {
        guard let whole = try? JSONSerialization.jsonObject(with: data) else { return .failure(.init(.badVersion)) }
        if secretAnywhere(whole) { return .failure(.init(.secretValue)) }
        guard let o = whole as? [String: Any],
              let v = int(o["v"]), v == 1,
              let at = number(o["updated_at"]), at <= Double(now + futureSlack),
              let keys = o["keys"] as? [String: Any] else { return .failure(.init(.badVersion)) }
        for (k, value) in keys {
            guard let type = allowlist[k] else { return .failure(.init(.unknownKey)) }
            guard typeOK(type, value) else { return .failure(.init(.badType)) }
        }
        return .success(Checked(updatedAt: Int64(at), keys: keys))
    }

    struct RefusalError: Error, Equatable {
        let reason: Refusal
        init(_ reason: Refusal) { self.reason = reason }
    }

    static func secretString(_ s: String) -> Bool {
        let lower = s.lowercased()
        if secretMarkers.contains(where: { lower.contains($0) }) { return true }
        var run = 0
        for ch in s.unicodeScalars {
            run = ch.properties.isASCIIHexDigit ? run + 1 : 0
            if run >= 64 { return true }
        }
        return false
    }

    private static func secretAnywhere(_ v: Any) -> Bool {
        switch v {
        case let s as String: return secretString(s)
        case let a as [Any]: return a.contains(where: secretAnywhere)
        case let o as [String: Any]: return o.contains { secretString($0.key) || secretAnywhere($0.value) }
        default: return false
        }
    }

    private static func typeOK(_ t: ValueType, _ v: Any) -> Bool {
        switch t {
        case .bool: return bool(v) != nil
        case .int: return int(v).map(wotDepthRange.contains) ?? false
        case .strings: return (v as? [Any])?.allSatisfy { $0 is String } ?? false
        case .objectString: return (v as? [String: Any])?.values.allSatisfy { $0 is String } ?? false
        case .objectBool: return (v as? [String: Any])?.values.allSatisfy { bool($0) != nil } ?? false
        }
    }

    // JSONSerialization hands back NSNumber for both bools and numbers.

    private static func isBoolNumber(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }

    private static func bool(_ v: Any?) -> Bool? {
        guard let n = v as? NSNumber, isBoolNumber(n) else { return nil }
        return n.boolValue
    }

    private static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, !isBoolNumber(n) else { return nil }
        return n.doubleValue
    }

    /// A whole number (1.0 counts, 1.5 doesn't).
    private static func int(_ v: Any?) -> Int? {
        guard let d = number(v), d == d.rounded(), abs(d) < 1e15 else { return nil }
        return Int(d)
    }
}
