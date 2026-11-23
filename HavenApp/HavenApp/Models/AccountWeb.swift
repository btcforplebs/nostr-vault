import Foundation

/// The relay's `wot_links.json`, parsed whole: its sorted follows and, for
/// everyone in the web, which of those follows follow them (indexes into
/// `follows`). `TrustLinks.bridges` reads one entry out of the bytes; the
/// account web needs them all.
struct TrustLinksIndex: Decodable, Equatable, Sendable {
    let follows: [String]
    let links: [String: [Int]]

    static func parse(_ data: Data) -> TrustLinksIndex? {
        try? JSONDecoder().decode(TrustLinksIndex.self, from: data)
    }
}

/// What the account web needs besides the graph: who "you" are on this
/// device and the bar the relay counts against.
struct AccountWebScope: Equatable, Sendable {
    /// Every account on this device (owner, open account, added accounts).
    var owners: Set<String>
    /// Min Followers: how many of your follows must follow someone.
    var minFollowers: Int
    /// The open account's follow list has really loaded. Until it has, the
    /// follows can read empty or short, so the shared web is used as before.
    var followsKnown: Bool
}

/// One account's web (Logen 2026-11-13). The relay builds a single web from
/// every account on the device: all their follows pooled, and the
/// Min Followers count taken across the pool. So someone one follow of the
/// open account plus two follows of another account got in, and read as three
/// hops out from the account on screen. This narrows the relay's web to the
/// open account: you and your accounts, your follows, and anyone at least
/// `minFollowers` of your own follows follow. No engine change: the relay's
/// web still decides who may write to the inbox.
enum AccountWeb {
    /// The relay's cap on a new account's widened web (`thin_web.go`).
    static let newAccountWebCap = 1000

    static func web(saved: Set<String>, follows: Set<String>, links: TrustLinksIndex?, depth: Int?,
                    scope: AccountWebScope) -> Set<String> {
        let shared = TrustMap.web(saved: saved, follows: follows)
        let bar = max(scope.minFollowers, 1)
        // Keep the shared web where this can't tell who is yours: no graph
        // yet (that is just the follows already), the follow list still
        // loading.
        guard !saved.isEmpty, scope.followsKnown else { return shared }
        var web = follows.union(scope.owners)
        switch depth {
        case 2:
            // You and your follows; the relay pooled every account's follows.
            return web
        case 3:
            // An older relay or an unreadable file (no links): keep the shared web.
            guard let links else { return shared }
            let counts = vouchCounts(links: links, follows: follows, excluding: web)
            guard follows.count >= bar else {
                // Fewer follows than the bar: the relay widens a new account's
                // web to its follows' follows (newAccountWeb). Do the same from
                // this account's own follows, not the pool's: anyone one of
                // them follows, most followed first, capped like the relay.
                return web.union(widened(counts).prefix(newAccountWebCap))
            }
            for (pubkey, counted) in counts where counted >= bar {
                web.insert(pubkey)
            }
            return web
        default:
            return shared
        }
    }

    /// For everyone in `links` outside `excluding`: how many of `follows`
    /// follow them. Only those at least one follow follows.
    static func vouchCounts(links: TrustLinksIndex, follows: Set<String>,
                            excluding: Set<String>) -> [String: Int] {
        let mine = links.follows.map { follows.contains($0) }
        var counts: [String: Int] = [:]
        // The relay sorts each entry, so a repeat sits next to itself.
        for (pubkey, from) in links.links where !excluding.contains(pubkey) {
            var counted = 0, previous = -1
            for index in from where index != previous && mine.indices.contains(index) {
                previous = index
                if mine[index] { counted += 1 }
            }
            if counted > 0 { counts[pubkey] = counted }
        }
        return counts
    }

    /// Most followed first, ties by key, so the same people win every time.
    static func widened(_ counts: [String: Int]) -> [String] {
        counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }
}

/// `wot_cache.json` and `wot_links.json` read as one thing (Tron 2011
/// must-fix 2). The relay renames the cache into place and only then writes
/// the links, so a read in between gets a new graph with the last build's
/// links, or none. Keying reloads to the cache alone pinned that until the
/// next rebuild, about a day.
enum WotFiles {
    static let pooledCacheName = "wot_cache.json"
    static let accountCachePrefix = "wot_cache_"
    static let accountLinksPrefix = "wot_links_"

    /// The links written with `cacheURL`: `wot_links_<hex>.json` beside an
    /// account's own `wot_cache_<hex>.json`, `wot_links.json` beside the pooled one.
    static func linksURL(beside cacheURL: URL) -> URL {
        let dir = cacheURL.deletingLastPathComponent()
        let name = cacheURL.lastPathComponent
        if name.hasPrefix(accountCachePrefix), name.hasSuffix(".json") {
            let hex = name.dropFirst(accountCachePrefix.count).dropLast(".json".count)
            return dir.appendingPathComponent(accountLinksPrefix + hex + ".json")
        }
        return dir.appendingPathComponent(TrustLinks.fileName)
    }

    /// The cache the feed reads for `owner`, the open account: the relay's
    /// web of that account alone (`wot_cache_<hex>.json`, haven-go
    /// pkg/wot/account_cache.go, same shape as the pooled file), built at its
    /// own Follow Distance and bar. The pooled `wot_cache.json` only while the
    /// account's file is missing (an older relay, or before its first build).
    /// With `reach`, the account's file counts only when it was built at that
    /// level and bar, as the relay's `loadAccountWebs` rules: after a Follow
    /// Distance change the relay gates from the pooled web until its rebuild
    /// lands, and the feed follows it (Tron 2472 low 2).
    /// Android twin: `WotFeedFiles.forAccount`.
    static func feedCacheURL(in dir: URL, owner: String, reach: AccountReach? = nil) -> URL {
        let hex = owner.lowercased()
        if hex.count == 64, hex.allSatisfy(\.isHexDigit) {
            let own = dir.appendingPathComponent(accountCachePrefix + hex + ".json")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: own.path, isDirectory: &isDir), !isDir.boolValue,
               reach.map({ builtAt($0, cacheURL: own) }) ?? true {
                return own
            }
        }
        return dir.appendingPathComponent(pooledCacheName)
    }

    /// The level and bar written in an account's file.
    struct BuiltReach: Decodable, Equatable {
        var depth: Int?
        var minFollowers: Int?
        enum CodingKeys: String, CodingKey { case depth, minFollowers = "min_followers" }
    }

    /// The account's file was built at `reach`, held to what the relay runs
    /// (haven-go `reachOf`: level 1-3, bar 0 or more). A field the file
    /// leaves out is not held against it; an unreadable file is (pooled).
    static func builtAt(_ reach: AccountReach, cacheURL: URL) -> Bool {
        guard let built = builtReach(cacheURL) else { return false }
        if let depth = built.depth, depth != min(max(reach.depth, 1), 3) { return false }
        if let bar = built.minFollowers, bar != max(reach.minFollowers, 0) { return false }
        return true
    }

    /// The file is several MB: parsed once per write, not per stamp check.
    private static let builtMemo = BuiltReachMemo()

    static func builtReach(_ cacheURL: URL) -> BuiltReach? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path)
        guard let modified = attrs?[.modificationDate] as? Date else { return nil }
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
        return builtMemo.value(path: cacheURL.path, modified: modified, size: size) {
            (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(BuiltReach.self, from: $0) }
        }
    }

    /// The cache was the open account's own, not the pooled one.
    static func isAccountCache(_ cacheURL: URL) -> Bool {
        cacheURL.lastPathComponent.hasPrefix(accountCachePrefix)
    }

    static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Changes when either file is rewritten: the later of the two dates.
    /// nil while there is no cache.
    static func stamp(cacheURL: URL) -> Date? {
        guard let cache = modified(cacheURL) else { return nil }
        return max(cache, modified(linksURL(beside: cacheURL)) ?? cache)
    }

    /// The web in memory (`loaded`: the file it came from and that file's
    /// stamp then) is not the one `cacheURL` holds now: another file (an
    /// account switch, or the account's own file appearing or falling back)
    /// or a newer write.
    static func needsRead(loaded: (path: String, modified: Date?)?, cacheURL: URL) -> Bool {
        guard let loaded else { return true }
        return loaded.path != cacheURL.path || loaded.modified != stamp(cacheURL: cacheURL)
    }

    /// The links on disk belong to the cache on disk: written at or after it.
    /// Below depth 3 there are no links to wait for.
    static func linksCurrent(cacheURL: URL, depth: Int?) -> Bool {
        guard (depth ?? 0) >= 3 else { return true }
        guard let cache = modified(cacheURL), let links = modified(linksURL(beside: cacheURL)) else { return false }
        return links >= cache
    }
}

/// One entry: the last account file read, keyed by its path, date and size.
final class BuiltReachMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var key: (path: String, modified: Date, size: Int64)?
    private var value: WotFiles.BuiltReach?

    func value(path: String, modified: Date, size: Int64, read: () -> WotFiles.BuiltReach?) -> WotFiles.BuiltReach? {
        lock.lock()
        defer { lock.unlock() }
        if let key, key.path == path, key.modified == modified, key.size == size { return value }
        let fresh = read()
        key = fresh == nil ? nil : (path, modified, size)
        value = fresh
        return fresh
    }
}

extension AccountWeb {
    /// The web that judges `recipient`, one of this device's accounts: the
    /// open account its own narrowed web (`open`), any other account the
    /// relay's web as saved, which pools every account's follows, as before
    /// the narrowing. Another account's alerts, switcher badge and Vault rows
    /// were judged by the open account's web (the Apple twin of Android 2012
    /// Tron must-fix 2).
    static func trusted(forRecipient recipient: String, active: String, open: () -> Set<String>,
                        pooled: Set<String>) -> Set<String> {
        let recipient = recipient.lowercased()
        return recipient.isEmpty || recipient == active.lowercased() ? open() : pooled
    }
}
