import Foundation
import CryptoKit

/// Reads a note's photo from its author's own vault over the FIPS mesh (NIP-F1).
///
/// A vault on the mesh lists `fipsmesh://<npub>/` in its owner's kind 10063.
/// A photo is found by its sha256: the `.fips` URL's path
/// (`http://<npub>.fips/<sha>.<ext>`), any Blossom-style path, or the note's
/// `imeta x`. The read goes only to the author of the note being drawn, never
/// to whoever first mentioned a blob, or anyone could post someone else's URL
/// and pull readers to their node. Only authors the owner follows (or the
/// owner) are dialled: dialling shows the vault this device's address.
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
        var hostNpub: String?
        /// A `.fips` URL is only reachable over the mesh (or a FIPS daemon),
        /// so the mesh goes first. Any other URL is tried as usual first.
        var meshFirst: Bool { hostNpub != nil }
    }

    /// nil when the photo names no hash: nothing the mesh could check.
    static func plan(url: URL, imetaSha256: String?) -> Plan? {
        let host = meshNpub(inHost: url.host)
        // A path hash is what the URL itself names; the imeta hash only
        // speaks for URLs that carry none.
        guard let sha = sha256(inPath: url) ?? normalizedSha256(imetaSha256) else { return nil }
        return Plan(sha256: sha, hostNpub: host)
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

    /// The first vault an author lists in their 10063.
    static func meshNpub(inServerList list: [String]) -> String? {
        list.lazy.compactMap(HomeVaultLogic.meshNpub(fromEntry:)).first
    }

    static func hashMatches(_ data: Data, sha256: String) -> Bool {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == sha256
    }

    // MARK: - Reading

    /// The photo's bytes from the author's vault, checked against its hash,
    /// or nil (not followed, no vault listed, unreachable, wrong bytes).
    func read(plan: Plan, author: String) async -> Data? {
        guard await deps.mayDial(author) else { return nil }
        let npub: String
        if let host = plan.hostNpub {
            // The author picked this vault for this blob.
            npub = host
        } else if let listed = await listedVault(of: author) {
            npub = listed
        } else {
            return nil
        }
        guard !distrusted.contains(npub), let base = await ingressBase(npub) else { return nil }
        guard let reply = await deps.get(base.appendingPathComponent(plan.sha256), Self.maxBytes) else {
            // The node restarted or the vault went away: dial again next time.
            ingressCache[npub] = nil
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

    /// The author's listed vault. A 10063 never seen is asked for, and a read
    /// that just asked waits a few seconds for it, so the first photo of a
    /// newly followed author still loads by scrolling.
    private func listedVault(of author: String) async -> String? {
        if let list = await deps.serverList(author) { return Self.meshNpub(inServerList: list) }
        let now = deps.now()
        if let last = requested[author], now.timeIntervalSince(last) < Self.requestRetry { return nil }
        requested[author] = now
        await deps.requestServerList(author)
        var waited: Duration = .zero
        while waited < Self.listWait {
            await deps.sleep(Self.listPoll)
            waited += Self.listPoll
            if let list = await deps.serverList(author) { return Self.meshNpub(inServerList: list) }
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
