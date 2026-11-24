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
        case objectList = "object[]"
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
        "desktop_vaults": .objectList,
    ]
    static let wotDepthRange = 0...3

    private static let secretMarkers = ["nsec1", "ncryptsec1", "nostr+walletconnect:", "bunker:"]

    // MARK: Export (this app's config → the contract keys)

    /// The allowlisted keys for `config`. A home vault or Mac on the mesh is
    /// this device's own media server, never sent.
    static func keys(_ config: HavenConfig, previousVaults: [Any]? = nil,
                     ownNpub: String? = HavenConfig.storedOwnMeshNpub,
                     now: Int64 = Int64(Date().timeIntervalSince1970)) -> [String: Any] {
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
            "desktop_vaults": vaultRecords(config, previous: vaultEntries(previousVaults), ownNpub: ownNpub, now: now),
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
    static func differs(_ config: HavenConfig, from fileKeys: [String: Any]?,
                        ownNpub: String? = HavenConfig.storedOwnMeshNpub,
                        now: Int64 = Int64(Date().timeIntervalSince1970)) -> Bool {
        guard let fileKeys else { return true }
        let previous = fileKeys["desktop_vaults"] as? [Any]
        let mine = keys(config, previousVaults: previous, ownNpub: ownNpub, now: now)
        let applied = apply(fileKeys, to: config, ownNpub: ownNpub)
        return !(NSDictionary(dictionary: mine).isEqual(to: keys(applied, previousVaults: previous, ownNpub: ownNpub, now: now)))
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
    static func apply(_ keys: [String: Any], to config: HavenConfig,
                      ownNpub: String? = HavenConfig.storedOwnMeshNpub) -> HavenConfig {
        var c = config
        if let v = keys["desktop_vaults"] as? [Any] { c = applyVaults(vaultEntries(v), to: c, ownNpub: ownNpub) }
        if let v = keys["feed_layouts"] as? [String: String] { c.feedLayoutModes = cleanLayouts(v) }
        if let v = bool(keys["zaps_only"]) { c.zapsOnlyMode = v }
        if let v = bool(keys["auto_load_new_posts"]) { c.autoLoadNewPosts = v }
        if let v = bool(keys["new_posts_pill"]) { c.showNewPostsPill = v }
        if let v = int(keys["wot_depth"]) {
            // The file's value is the first account's: the others keep theirs.
            var first = c.reach(for: c.ownerNpub)
            first.depth = v
            c.setReach(first, for: c.ownerNpub)
        }
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
        case .objectList: return vaultsOK(v)
        }
    }

    // JSONSerialization hands back NSNumber for both bools and numbers.

    private static func isBoolNumber(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }

    static func bool(_ v: Any?) -> Bool? {
        guard let n = v as? NSNumber, isBoolNumber(n) else { return nil }
        return n.boolValue
    }

    static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, !isBoolNumber(n) else { return nil }
        return n.doubleValue
    }

    /// A whole number (1.0 counts, 1.5 doesn't).
    static func int(_ v: Any?) -> Int? {
        guard let d = number(v), d == d.rounded(), abs(d) < 1e15 else { return nil }
        return Int(d)
    }
}

// MARK: - The Desktop Vault list (`desktop_vaults`, Desktop Vaults P10)

/// PLANS/NV_DESKTOP_VAULTS_PLAN.md §2.6 and contract §5: each Vault's
/// addresses, name, kind and order, with an `updatedAt` per Vault and
/// tombstones for deletes, merged per Vault id (`settings-vault-merge-cases.json`).
/// The stamps and tombstones live only in the file: export compares this
/// device's list with the file's to date what changed here. Nothing here
/// reads or writes My Devices, so a copied Vault can never pair (§2.6).
/// Android twin: `CopySettings.kt`.
extension CopySettings {
    static let vaultsMax = 32
    static let vaultTombDays: Int64 = 90
    static let vaultFields: [String: String] = ["id": "string", "name": "string?", "kind": "string?",
                                                "meshNpub": "npub?", "httpsURL": "https?",
                                                "order": "int", "updatedAt": "int"]
    static let tombFields: [String: String] = ["id": "string", "deletedAt": "int"]

    typealias VaultEntry = [String: Any]

    static func vaultEntries(_ list: [Any]?) -> [VaultEntry] { (list ?? []).compactMap { $0 as? VaultEntry } }

    static func isTomb(_ e: VaultEntry) -> Bool { e["deletedAt"] != nil }

    /// A Vault's `updatedAt`, or a tombstone's `deletedAt`.
    static func stamp(_ e: VaultEntry) -> Int64 { Int64(number(e["deletedAt"] ?? e["updatedAt"]) ?? 0) }

    /// The field-by-field check of the `object[]` type.
    static func vaultsOK(_ v: Any) -> Bool {
        guard let list = v as? [Any] else { return false }
        var seen = Set<String>()
        var vaults = 0
        for x in list {
            guard let e = x as? VaultEntry else { return false }
            let fields = isTomb(e) ? tombFields : vaultFields
            if !isTomb(e) { vaults += 1 }
            guard e.keys.allSatisfy({ fields[$0] != nil }) else { return false }
            for (k, t) in fields {
                guard let value = e[k] else {
                    if t.hasSuffix("?") { continue }
                    return false
                }
                let str = value as? String
                switch t.replacingOccurrences(of: "?", with: "") {
                case "string": guard let str, k != "id" || !str.isEmpty else { return false }
                case "npub": guard str?.hasPrefix("npub1") == true else { return false }
                case "https": guard str?.hasPrefix("https://") == true else { return false }
                default:
                    guard let n = number(value), n == n.rounded(), n >= (k == "order" ? 0 : 1), n < 1e15
                    else { return false }
                }
            }
            if !isTomb(e), e["meshNpub"] == nil, e["httpsURL"] == nil { return false }
            guard let id = e["id"] as? String, seen.insert(id).inserted else { return false }
        }
        return vaults <= vaultsMax
    }

    /// Per Vault id, the newer stamp wins; a tie keeps mine, and a tombstone
    /// removes a Vault only when newer. Tombstones past 90 days are dropped.
    /// Vaults by (order, id), then tombstones by id. The engine's
    /// copyVaultsMerge, held to the same fixture.
    static func mergeVaults(_ mine: [VaultEntry], _ theirs: [VaultEntry], now: Int64) -> [VaultEntry] {
        var byID: [String: VaultEntry] = [:]
        var ids: [String] = []
        for e in mine { if let id = e["id"] as? String { if byID[id] == nil { ids.append(id) }; byID[id] = e } }
        for t in theirs {
            guard let id = t["id"] as? String else { continue }
            guard let m = byID[id] else { byID[id] = t; ids.append(id); continue }
            if stamp(t) > stamp(m) || (stamp(t) == stamp(m) && isTomb(m) && !isTomb(t)) { byID[id] = t }
        }
        let oldest = now - vaultTombDays * 86_400
        let kept = ids.compactMap { byID[$0] }.filter { !isTomb($0) || stamp($0) >= oldest }
        let vaults = kept.filter { !isTomb($0) }.sorted {
            let a = int($0["order"]) ?? 0, b = int($1["order"]) ?? 0
            return a != b ? a < b : ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "")
        }
        let tombs = kept.filter(isTomb).sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
        return vaults + tombs
    }

    private static func record(_ v: DesktopVault) -> VaultEntry {
        var e: VaultEntry = ["id": v.id, "name": v.name, "kind": v.kind.rawValue, "order": v.order]
        if let m = v.meshNpub { e["meshNpub"] = m }
        if let h = v.httpsURL { e["httpsURL"] = h }
        return e
    }

    private static func sameFields(_ a: VaultEntry, _ b: VaultEntry) -> Bool {
        var a = a, b = b
        a["updatedAt"] = nil
        b["updatedAt"] = nil
        return NSDictionary(dictionary: a).isEqual(to: b)
    }

    /// This device's Vault list as file entries, dated against `previous`
    /// (the file's): an unchanged Vault keeps its stamp, a changed or new one
    /// is dated `now`, and one deleted here becomes a tombstone. Left as the
    /// file has it, never deleted: this device's own entry (§2.6), and a
    /// mesh address this device isn't paired with, which it can't hold
    /// (DesktopVaultsLogic.followingDevices) and so never removed. Order is
    /// kept unless the Vaults were reordered here.
    static func vaultRecords(_ config: HavenConfig, previous: [VaultEntry], ownNpub: String?,
                             now: Int64) -> [Any] {
        let local = DesktopVaultsLogic.ordered(config.desktopVaultsInEffect(ownNpub: ownNpub))
        let paired = Set(config.meshDevices.map(\.npub))
        let prevByID = Dictionary(previous.compactMap { e in (e["id"] as? String).map { ($0, e) } },
                                  uniquingKeysWith: { a, _ in a })
        func heldElsewhere(_ npub: String?) -> Bool {
            guard let npub else { return false }
            return npub == ownNpub || !paired.contains(npub)
        }
        // Order: the file's, unless the Vaults both sides hold were reordered here.
        let prevVaults = previous.filter { !isTomb($0) }
        let prevOrder = prevVaults.sorted { (int($0["order"]) ?? 0, $0["id"] as? String ?? "") < (int($1["order"]) ?? 0, $1["id"] as? String ?? "") }
            .compactMap { $0["id"] as? String }
        let localIDs = local.map(\.id)
        let reordered = prevOrder.filter(localIDs.contains) != localIDs.filter(prevOrder.contains)
        var nextOrder = (prevVaults.compactMap { int($0["order"]) }.max() ?? -1) + 1

        var out: [VaultEntry] = []
        for v in local {
            var e = record(v)
            let prev = prevByID[v.id].flatMap { isTomb($0) ? nil : $0 }
            if v.meshNpub == nil, let carried = prev?["meshNpub"] as? String, heldElsewhere(carried) {
                e["meshNpub"] = carried
            }
            if !reordered {
                if let o = prev.flatMap({ int($0["order"]) }) { e["order"] = o } else { e["order"] = nextOrder; nextOrder += 1 }
            }
            if let prev, sameFields(prev, e) { e["updatedAt"] = prev["updatedAt"] } else { e["updatedAt"] = now }
            out.append(e)
        }
        for p in previous where !localIDs.contains(p["id"] as? String ?? "") {
            if isTomb(p) || heldElsewhere(p["meshNpub"] as? String) && (p["httpsURL"] == nil || p["meshNpub"] as? String == ownNpub) {
                out.append(p)
            } else if let id = p["id"] as? String {
                out.append(["id": id, "deletedAt": now])
            }
        }
        return mergeVaults(out, [], now: now)
    }

    /// `config` with the file's Vault list taken in, per Vault: a newer
    /// Vault replaces or joins this device's, a tombstone removes it, and
    /// this device's own entry is left out. It only ever sets addresses:
    /// My Devices is not touched, so a copied Vault pairs nothing.
    static func applyVaults(_ entries: [VaultEntry], to config: HavenConfig, ownNpub: String?) -> HavenConfig {
        var c = config
        let tombs = Set(entries.filter(isTomb).compactMap { $0["id"] as? String })
        var vaults = c.desktopVaultsInEffect(ownNpub: ownNpub).filter { !tombs.contains($0.id) }
        var removed = c.desktopVaultsRemoved
        for e in entries where !isTomb(e) {
            guard let id = e["id"] as? String else { continue }
            let mesh = e["meshNpub"] as? String
            if let ownNpub, mesh == ownNpub { continue }
            let vault = DesktopVault(id: id, name: e["name"] as? String ?? "",
                                     kind: DesktopVaultKind(rawValue: e["kind"] as? String ?? "") ?? .mac,
                                     meshNpub: mesh, httpsURL: e["httpsURL"] as? String, order: int(e["order"]) ?? 0)
            if let i = vaults.firstIndex(where: { $0.id == id }) { vaults[i] = vault } else { vaults.append(vault) }
            let keys = Set(DesktopVaultsEditing.removedKeys(of: vault))
            removed.removeAll { keys.contains($0) }
        }
        let next = DesktopVaultsLogic.ordered(vaults)
        if next != c.desktopVaults { c.desktopVaults = next }
        if removed != c.desktopVaultsRemoved { c.desktopVaultsRemoved = removed }
        return c
    }
}
