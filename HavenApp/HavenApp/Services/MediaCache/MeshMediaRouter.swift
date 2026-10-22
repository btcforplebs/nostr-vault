import Foundation
import CryptoKit

/// Reads a note's photo from its author's own vault over the FIPS mesh (NIP-F1).
///
/// A vault on the mesh lists `fipsmesh://<npub>/` in its owner's kind 10063.
/// A photo is found by its sha256: the `.fips` URL's path
/// (`http://<npub>.fips/<sha>.<ext>`), any Blossom-style path, or the note's
/// note's own `imeta x`. The read goes only to a vault the author of the note
/// being drawn lists in their own 10063, never to whoever first mentioned a
/// blob or to a node a `.fips` URL merely names, or anyone could pull readers
/// to their node. Only authors the owner follows (or the owner) are dialled:
/// dialling shows the vault this device's address.
///
/// The vault is trusted no more than any other server: the whole body is read,
/// capped, and hashed before any of it is used. Wrong bytes drop that vault for
/// the session. The same rules as Android's `FipsMediaRouter` /
/// `FipsMeshInterceptor`.
actor MeshMediaRouter {
    struct Reply: Sendable {
        var status: Int
        /// nil when the body was over the cap: nothing kept, nothing hashed.
        var data: Data?
    }

    struct Dependencies: Sendable {
        /// Whether a read of this author's (hex) media may go over the mesh.
        var mayDial: @Sendable (String) async -> Bool
        /// The author's newest 10063 server list, nil if none was seen yet.
        var serverList: @Sendable (String) async -> [String]?
        /// Ask relays for the author's 10063.
        var requestServerList: @Sendable (String) async -> Void
        /// A loopback base whose requests reach this mesh npub's vault, or nil.
        var ingress: @Sendable (String) async -> URL?
        /// A plain GET of the full body (no Range), capped at `maxBytes`;
        /// nil when the connection failed.
        var get: @Sendable (URL, Int) async -> Reply?
        var now: @Sendable () -> Date = { Date() }
        var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    }

    /// The most a mesh read keeps. Bigger blobs come from the URL.
    static let maxBytes = 32 << 20
    /// A failed dial is not retried for this long, so a dead vault costs one wait.
    static let ingressRetry: TimeInterval = 30
    /// A missing 10063 is asked for again after this long.
    static let requestRetry: TimeInterval = 5 * 60
    /// How long a read waits for a 10063 it has just asked for.
    static let listWait: Duration = .seconds(6)
    static let listPoll: Duration = .milliseconds(500)

    private let deps: Dependencies
    private var ingressCache: [String: (base: URL?, at: Date)] = [:]
    private var ingressInFlight: [String: Task<URL?, Never>] = [:]
    private var distrusted: Set<String> = []
    private var requested: [String: Date] = [:]

    init(_ deps: Dependencies) {
        self.deps = deps
    }

    // MARK: - Pure rules

    /// Where a photo's bytes can come from, worked out from the URL alone.
    struct Plan: Equatable {
        var sha256: String
        /// The vault a `.fips` URL names; nil means the author's 10063 decides.
        /// Either way the vault must be one the author lists.
        var hostNpub: String?
        /// The hash is the URL's own (its path), so bytes that match it are
        /// that URL's bytes for every note. A hash from a note's `imeta` only
        /// speaks for that note: its bytes are kept under the hash, never the URL.
        var hashFromPath: Bool = true
        /// A `.fips` URL is only reachable over the mesh (or a FIPS daemon),
        /// so the mesh goes first. Any other URL is tried as usual first.
        var meshFirst: Bool { hostNpub != nil }
    }

    /// nil when the photo names no hash: nothing the mesh could check.
    static func plan(url: URL, imetaSha256: String?) -> Plan? {
        let host = meshNpub(inHost: url.host)
        // A path hash is what the URL itself names; the imeta hash only
        // speaks for URLs that carry none.
        if let sha = sha256(inPath: url) { return Plan(sha256: sha, hostNpub: host) }
        guard let sha = normalizedSha256(imetaSha256) else { return nil }
        return Plan(sha256: sha, hostNpub: host, hashFromPath: false)
    }

    /// The disk and image cache key for bytes found by a note's `imeta` hash:
    /// the hash itself, so they never stand in for the URL in another note.
    static func blobCacheKey(sha256: String) -> URL {
        URL(string: "fipsmesh-blob:\(sha256)")!
    }

    /// Each media URL's `x` in a note's own `imeta` tags (NIP-92), by URL string.
    static func imetaSha256s(tags: [[String]]) -> [String: String] {
        var hashes: [String: String] = [:]
        for tag in tags where tag.first == "imeta" {
            var url: String?, sha: String?
            for field in tag.dropFirst() {
                if field.hasPrefix("url ") { url = field.dropFirst(4).trimmingCharacters(in: .whitespaces) }
                if field.hasPrefix("x ") { sha = normalizedSha256(field.dropFirst(2).trimmingCharacters(in: .whitespaces)) }
            }
            if let url, let sha { hashes[url] = sha }
        }
        return hashes
    }

    /// `<npub>.fips` exactly (any case), or nil.
    static func meshNpub(inHost host: String?) -> String? {
        guard let host = host?.lowercased(), host.hasSuffix(".fips") else { return nil }
        return HomeVaultLogic.meshNpub(fromEntry: "fipsmesh://\(host.dropLast(5))/")
    }

    /// The sha256 a Blossom-style path ends in: `/<sha>` or `/<sha>.<ext>`.
    static func sha256(inPath url: URL) -> String? {
        let last = url.lastPathComponent.lowercased()
        guard last.range(of: #"^[0-9a-f]{64}(\.[a-z0-9]{1,8})?$"#, options: .regularExpression) != nil else { return nil }
        return String(last.prefix(64))
    }

    static func normalizedSha256(_ value: String?) -> String? {
        guard let value = value?.lowercased(),
              value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    /// The vault a read may dial: the one a `.fips` URL names only when the
    /// author lists it, else the author's first listed vault.
    static func vault(for plan: Plan, serverList list: [String]) -> String? {
        let listed = HomeVaultLogic.meshEntries(serverList: list, excluding: nil)
        guard let host = plan.hostNpub else { return listed.first }
        return listed.contains(host) ? host : nil
    }

    static func hashMatches(_ data: Data, sha256: String) -> Bool {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == sha256
    }

    // MARK: - Reading

    /// The photo's bytes from the author's vault, checked against its hash,
    /// or nil (not followed, no vault listed, unreachable, wrong bytes).
    /// `onLookup` runs once the author is known to be one the mesh may be
    /// asked about, before the wait for their list or the dial: the moment a
    /// photo starts "Loading over FIPS…", as on the web.
    func read(plan: Plan, author: String, onLookup: (@Sendable () async -> Void)? = nil) async -> Data? {
        guard await deps.mayDial(author) else { return nil }
        await onLookup?()
        guard let list = await serverList(of: author),
              // A `.fips` URL may name any node; only the author's own signed
              // list says which are theirs.
              let npub = Self.vault(for: plan, serverList: list)
        else { return nil }
        guard !distrusted.contains(npub), let base = await ingressBase(npub) else { return nil }
        guard let reply = await deps.get(base.appendingPathComponent(plan.sha256), Self.maxBytes) else {
            // The node restarted or the vault went away: dial again, but not
            // once per photo.
            ingressCache[npub] = (nil, deps.now())
            return nil
        }
        // Honestly missing, or honestly too big (a video): the vault keeps its standing.
        guard reply.status == 200, let data = reply.data else { return nil }
        guard Self.hashMatches(data, sha256: plan.sha256) else {
            // Wrong bytes are not a passing fault.
            distrusted.insert(npub)
            ingressCache[npub] = nil
            return nil
        }
        return data
    }

    /// The author's 10063. One never seen is asked for, and a read that just
    /// asked waits a few seconds for it, so the first photo of a newly
    /// followed author still loads by scrolling.
    private func serverList(of author: String) async -> [String]? {
        if let list = await deps.serverList(author) { return list }
        let now = deps.now()
        if let last = requested[author], now.timeIntervalSince(last) < Self.requestRetry { return nil }
        requested[author] = now
        await deps.requestServerList(author)
        var waited: Duration = .zero
        while waited < Self.listWait {
            await deps.sleep(Self.listPoll)
            waited += Self.listPoll
            if let list = await deps.serverList(author) { return list }
        }
        return nil
    }

    /// One dial per vault at a time; every photo from it shares the answer.
    private func ingressBase(_ npub: String) async -> URL? {
        if let cached = ingressCache[npub] {
            if let base = cached.base { return base }
            if deps.now().timeIntervalSince(cached.at) < Self.ingressRetry { return nil }
        }
        if let running = ingressInFlight[npub] { return await running.value }
        let dial = deps.ingress
        let task = Task { await dial(npub) }
        ingressInFlight[npub] = task
        let base = await task.value
        ingressInFlight[npub] = nil
        // A vault distrusted while this dial ran stays dropped.
        if !distrusted.contains(npub) { ingressCache[npub] = (base, deps.now()) }
        return base
    }
}

/// What a photo or video shows in its place while it isn't drawn: the web's
/// `MeshBox` (web-vault MediaImage.jsx), same words.
enum MeshMediaPhase: Equatable, Sendable {
    /// The usual load from the URL; nothing to say yet.
    case loading
    /// The URL failed (or is a `.fips` link) and the author's vault is being
    /// asked over the mesh.
    case meshLookup
    /// The mesh was asked and gave up.
    case unreached
    /// A `.fips` link the mesh may not be asked about (author not followed).
    case notReachable
    /// The URL failed and there was no mesh to ask.
    case notFound

    /// The phase a load that came back empty ends in.
    static func failed(after phase: MeshMediaPhase, meshOnly: Bool) -> MeshMediaPhase {
        if phase == .meshLookup { return .unreached }
        return meshOnly ? .notReachable : .notFound
    }

    var isFailure: Bool { self == .unreached || self == .notReachable || self == .notFound }

    func text(video: Bool = false) -> String? {
        switch self {
        case .loading: return nil
        case .meshLookup: return video ? "Loading video over FIPS…" : "Loading image over FIPS…"
        case .unreached: return "Couldn't reach the owner's vault"
        case .notReachable: return video ? "Video not reachable" : "Photo not reachable"
        case .notFound: return video ? "Video not found" : "Photo not found"
        }
    }
}
