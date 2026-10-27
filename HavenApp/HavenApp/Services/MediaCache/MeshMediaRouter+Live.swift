import Foundation
import SwiftUI

extension MeshMediaRouter {
    static let shared = MeshMediaRouter(.live)
}

extension MeshMediaRouter.Dependencies {
    /// The app's follows, 10063 cache and mesh engine. On the Mac the engine
    /// runs only while its Mesh switch is on; otherwise every read falls
    /// through to the URL.
    static var live: Self {
        Self(
            mayDial: { author in
                await MainActor.run {
                    FeedService.shared.followedPubkeySet.contains(author)
                        || author == NostrService.shared.activeHexPubkey
                }
            },
            serverList: { author in
                await MainActor.run { NostrService.shared.serverLists[author] }
            },
            requestServerList: { author in
                await MainActor.run { NostrService.shared.fetchMissingProfiles(for: [author], force: true) }
            },
            ingress: { npub in
                #if os(iOS)
                return await FipsMeshService.shared.ingressURL(meshNpub: npub)
                #else
                return await MacFipsMeshService.shared.ingressURL(meshNpub: npub)
                #endif
            },
            get: { url, maxBytes in await MeshMediaGet.get(url, maxBytes: maxBytes) }
        )
    }
}

/// A whole-blob GET over a loopback mesh ingress, capped while it streams:
/// the moment a body passes `maxBytes` the transfer is cancelled, so a vault
/// that never stops sending costs at most `maxBytes`, in memory or on disk.
private enum MeshMediaGet {
    static let configuration: URLSessionConfiguration = {
        let config = URLSessionConfiguration.ephemeral
        // A quiet vault gives up like a slow server; a big photo may still trickle in.
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 120
        config.urlCache = nil
        return config
    }()

    static func get(_ url: URL, maxBytes: Int) async -> MeshMediaRouter.Reply? {
        // A Range answer could never match the hash: plain GET, all of it.
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let collector = CappedCollector(maxBytes: maxBytes)
        let session = URLSession(configuration: configuration, delegate: collector, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                collector.start(task, continuation)
            }
        } onCancel: {
            collector.cancel(task)
        }
    }
}

/// Collects one body, cancelling the transfer past its cap.
private final class CappedCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maxBytes: Int
    private let lock = NSLock()
    private var data = Data()
    private var status = 0
    private var oversized = false
    private var cancelled = false
    private var continuation: CheckedContinuation<MeshMediaRouter.Reply?, Never>?

    init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }

    func start(_ task: URLSessionDataTask, _ continuation: CheckedContinuation<MeshMediaRouter.Reply?, Never>) {
        let alreadyCancelled = lock.withLock { () -> Bool in
            if !cancelled { self.continuation = continuation }
            return cancelled
        }
        // Cancelled before it began: a task that never runs never completes.
        if alreadyCancelled { continuation.resume(returning: nil) } else { task.resume() }
    }

    func cancel(_ task: URLSessionDataTask) {
        lock.withLock { cancelled = true }
        task.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let declared = response.expectedContentLength
        lock.withLock {
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if declared > Int64(maxBytes) { oversized = true }
        }
        completionHandler(declared > Int64(maxBytes) ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        let over = lock.withLock { () -> Bool in
            guard !oversized else { return true }
            if data.count + chunk.count > maxBytes {
                oversized = true
                data = Data()
                return true
            }
            data.append(chunk)
            return false
        }
        if over { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (reply, continuation) = lock.withLock { () -> (MeshMediaRouter.Reply?, CheckedContinuation<MeshMediaRouter.Reply?, Never>?) in
            defer { self.continuation = nil }
            // Over the cap: an honest answer, nothing kept.
            if oversized { return (.init(status: status, data: nil), self.continuation) }
            if error != nil { return (nil, self.continuation) }
            return (.init(status: status, data: data), self.continuation)
        }
        continuation?.resume(returning: reply)
    }
}

extension MediaCacheService {
    /// `fetchData`, plus the note author's own vault on the FIPS mesh (NIP-F1).
    /// A `.fips` photo is read over the mesh first; any other photo with a
    /// known hash only when its URL fails. Returns the bytes and the key they
    /// are cached under: the URL when its own path names the hash, else the
    /// hash, so a note's `imeta` can never put its bytes under someone else's URL.
    ///
    /// `onLookup` runs on the main actor when the mesh is about to be asked,
    /// so the view can say "Loading image over FIPS…" as the web does.
    func fetchData(url: URL, meshAuthor: String?, imetaSha256: String?,
                   onLookup: (@MainActor @Sendable () -> Void)? = nil) async -> (data: Data, cacheKey: URL)? {
        guard let author = meshAuthor,
              let plan = MeshMediaRouter.plan(url: url, imetaSha256: imetaSha256)
        else { return await fetchData(url: url).map { ($0, url) } }
        let lookup: (@Sendable () async -> Void)? = onLookup.map { report in { @Sendable in await report() } }

        let key = plan.hashFromPath ? url : MeshMediaRouter.blobCacheKey(sha256: plan.sha256)
        if !plan.hashFromPath, let cached = loadMeshCached(key) { return (cached, key) }

        if plan.meshFirst {
            if plan.hashFromPath, let cached = loadMeshCached(url) { return (cached, url) }
            if let data = await readOverMesh(plan: plan, author: author, key: key, onLookup: lookup) { return (data, key) }
            return await fetchFipsURL(url, plan: plan).map { ($0, url) }
        }
        if let data = await fetchData(url: url) { return (data, url) }
        return await readOverMesh(plan: plan, author: author, key: key, onLookup: lookup).map { ($0, key) }
    }

    /// A cached copy the mesh path may stand on. Hash-named files are
    /// re-hashed on load only up to the integrity limit, and a plain download
    /// of any `https://…/<sha>` lands in the same file, so a copy too big to
    /// be a mesh read is treated as absent rather than trusted unchecked.
    private func loadMeshCached(_ key: URL) -> Data? {
        guard let file = internalLocalFileURL(for: key),
              let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size <= MeshMediaRouter.maxBytes
        else { return nil }
        return try? Data(contentsOf: file)
    }

    /// True for a `.fips` URL on iOS, where only the mesh engine can reach it:
    /// there is no FIPS daemon, so a plain fetch would only send the vault's
    /// npub to DNS and take whatever a resolver answers. `FipsHostBlocker`
    /// enforces it for `URLSession.shared` and the media session; loaders
    /// outside those (`AsyncImage`, AVFoundation, other sessions) check it
    /// themselves.
    static func isMeshOnly(_ url: URL) -> Bool {
        #if os(iOS)
        return MeshMediaRouter.meshNpub(inHost: url.host) != nil
        #else
        return false
        #endif
    }

    /// `url`, or nil when only the mesh could reach it: for loaders, such as
    /// `AsyncImage`, that go to the network themselves.
    static func offMeshURL(_ url: URL?) -> URL? {
        guard let url, !isMeshOnly(url) else { return nil }
        return url
    }

    /// A `.fips` URL outside the mesh engine. The iPhone has no FIPS daemon,
    /// so there it would only leak the vault's npub to DNS and fetch whatever a
    /// resolver answers: skipped. A Mac may run a daemon; there the bytes must
    /// match the hash the URL names, and wrong ones leave the cache.
    private func fetchFipsURL(_ url: URL, plan: MeshMediaRouter.Plan) async -> Data? {
        #if os(iOS)
        return nil
        #else
        guard plan.hashFromPath, let data = await fetchData(url: url) else { return nil }
        guard MeshMediaRouter.hashMatches(data, sha256: plan.sha256) else {
            try? FileManager.default.removeItem(at: cachePath(for: url))
            return nil
        }
        return data
        #endif
    }

    /// A video the player could not get from its URL, read whole from the
    /// note author's vault on the mesh (up to `MeshMediaRouter.maxBytes`),
    /// checked against its hash: the local file to play, or nil. Mesh only:
    /// the URL already failed, and a big video must never be pulled into
    /// memory by a plain download here.
    func meshVideoFile(url: URL, note: MeshMediaNote?,
                       onLookup: (@MainActor @Sendable () -> Void)? = nil) async -> URL? {
        guard let note,
              let plan = MeshMediaRouter.plan(url: url, imetaSha256: note.imetaSha256[url.absoluteString])
        else { return nil }
        let key = plan.hashFromPath ? url : MeshMediaRouter.blobCacheKey(sha256: plan.sha256)
        let hint = url.pathExtension.isEmpty ? nil : url.pathExtension
        if !plan.hashFromPath, loadMeshCached(key) != nil { return preparePlayableURL(for: key, extensionHint: hint) }
        let lookup: (@Sendable () async -> Void)? = onLookup.map { report in { @Sendable in await report() } }
        guard await readOverMesh(plan: plan, author: note.author, key: key, onLookup: lookup) != nil else { return nil }
        return preparePlayableURL(for: key, extensionHint: hint)
    }

    private func readOverMesh(plan: MeshMediaRouter.Plan, author: String, key: URL,
                              onLookup: (@Sendable () async -> Void)? = nil) async -> Data? {
        guard let data = await MeshMediaRouter.shared.read(plan: plan, author: author, onLookup: onLookup) else { return nil }
        // print reaches relay.log, the file pulled off a device.
        print("FipsMesh: read \(plan.sha256.prefix(8)) over the mesh (\(data.count) bytes)")
        saveToCache(url: key, data: data)
        return data
    }
}

/// Fails every request to a mesh-only `.fips` host before it reaches DNS:
/// one chokepoint for `URLSession.shared` (registered at launch) and
/// `MediaSessionService` (in its `protocolClasses`). Sessions built from
/// their own configuration and AVFoundation do not pass through it.
final class FipsHostBlocker: URLProtocol {
    private static let installed: Void = { URLProtocol.registerClass(FipsHostBlocker.self) }()

    static func install() { _ = installed }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url.map(MediaCacheService.isMeshOnly) ?? false
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
    }

    override func stopLoading() {}
}

// MARK: - Which note a photo belongs to

/// The note whose media is drawn below: its author (hex), the only one whose
/// listed vault a photo may be read from over the mesh, and the hashes its
/// own `imeta` tags declare.
struct MeshMediaNote: Equatable {
    var author: String
    var imetaSha256: [String: String]

    init(author: String, tags: [[String]]) {
        self.author = author
        self.imetaSha256 = MeshMediaRouter.imetaSha256s(tags: tags)
    }
}

/// The note whose photo was just tapped open. The full-screen viewer is
/// presented from the feed, outside the note's environment, so it picks the
/// note up here; only for a moment, so a later open never inherits it.
@MainActor
enum MeshMediaTap {
    private static var last: (note: MeshMediaNote?, at: Date)?

    static func opened(_ note: MeshMediaNote?) { last = (note, Date()) }

    static var note: MeshMediaNote? {
        guard let last, Date().timeIntervalSince(last.at) < 3 else { return nil }
        return last.note
    }
}

private struct MeshMediaNoteKey: EnvironmentKey {
    static let defaultValue: MeshMediaNote? = nil
}

extension EnvironmentValues {
    /// nil keeps media off the mesh.
    var meshMediaNote: MeshMediaNote? {
        get { self[MeshMediaNoteKey.self] }
        set { self[MeshMediaNoteKey.self] = newValue }
    }
}

extension View {
    /// Let the photos below be read from `pubkey`'s vault on the FIPS mesh,
    /// checked against the hashes in this note's own `tags`.
    func meshMediaNote(author pubkey: String, tags: [[String]]) -> some View {
        environment(\.meshMediaNote, MeshMediaNote(author: pubkey, tags: tags))
    }

    /// The same for a gallery item: its note's author and tags, or nothing
    /// (off the mesh) when the item has no known author.
    func meshMediaNote(for item: MediaItem) -> some View {
        environment(\.meshMediaNote, item.pubkey.map { MeshMediaNote(author: $0, tags: item.tags ?? []) })
    }
}
