import Foundation
import CryptoKit

/// Reads an `htree://` photo (HtreeLink): upload.iris.to, then the author's
/// kind 10063 list, then this account's media servers and the new-account
/// defaults, each asked for the encrypted blob by its hash. The first blob
/// that checks, decrypts, checks again and is a picture lands in the media
/// cache, decrypted, under the link, where every photo, thumbnail and viewer
/// path already looks. A link no server can serve is remembered for
/// `retryAfter`, so a feed full of it costs one try. Twin of BlossomURIFetcher.
actor HtreeFetcher {
    static let shared = HtreeFetcher()

    static let maxServers = 8
    static let retryAfter: TimeInterval = 120
    static let listWait: Duration = .seconds(4)

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        config.urlCache = nil
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    private var inFlight: [String: Task<URL?, Never>] = [:]
    private var verified: Set<String> = []
    private var failedAt: [String: Date] = [:]
    private var noteAuthors: [String: String] = [:]

    /// Remember who posted these links, so the author's server list is used
    /// wherever the photo is drawn.
    nonisolated static func register(_ urls: [URL], author: String) {
        let hashes = urls.compactMap { HtreeLink($0)?.blobHash }
        guard !hashes.isEmpty else { return }
        Task { await shared.noteAuthors(hashes, author) }
    }

    private func noteAuthors(_ hashes: [String], _ author: String) {
        for hash in hashes where noteAuthors[hash] == nil { noteAuthors[hash] = author }
    }

    /// The decrypted, checked photo for `link` on disk, fetching it if
    /// needed; nil when no server had the right blob.
    func file(for link: HtreeLink, url: URL, author: String?) async -> URL? {
        let path = MediaCacheService.shared.cachePath(for: url)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path.path) {
            let stamp = "\(path.path)|\(attrs[.size] ?? 0)|\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
            if verified.contains(stamp) { return path }
            if let data = try? Data(contentsOf: path), Self.hex(SHA256.hash(data: data)) == link.sha256 {
                verified.insert(stamp)
                return path
            }
            try? FileManager.default.removeItem(at: path)
        }
        // Same blob with a different key is a different file: key by both.
        let key = "\(link.blobHash)|\(link.sha256)"
        if let failed = failedAt[key], Date().timeIntervalSince(failed) < Self.retryAfter { return nil }
        if let running = inFlight[key] { return await running.value }

        let author = author ?? noteAuthors[link.blobHash]
        let task = Task { await Self.download(link, author: author, to: path) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        failedAt[key] = result == nil ? Date() : nil
        return result
    }

    /// Iris first: every htree photo seen so far is there, so the author's
    /// list is only looked up (and waited for) on a miss (Tron, web #2508).
    private static func download(_ link: HtreeLink, author: String?, to path: URL) async -> URL? {
        let iris = link.candidates(authorServers: [], ownServers: [])
        if let file = await firstMatch(link, in: iris, to: path) { return file }
        var authorServers: [String] = []
        if let author { authorServers = await serverList(author) }
        let ours = await MainActor.run { ConfigService.shared.config.blossomMirrors }
        let rest = link.candidates(authorServers: authorServers, ownServers: ours + HavenConfig.newAccountBlossomMirrors)
            .filter { !iris.contains($0) }
        if let file = await firstMatch(link, in: Array(rest.prefix(maxServers - iris.count)), to: path) { return file }
        print("htree: \(link.blobHash.prefix(8)) unavailable on \(iris.count + min(rest.count, maxServers - iris.count)) servers")
        return nil
    }

    private static func firstMatch(_ link: HtreeLink, in urls: [URL], to path: URL) async -> URL? {
        for url in urls {
            guard let blob = await get(url), let photo = link.open(blob) else {
                print("htree: \(link.blobHash.prefix(8)) not on \(url.host ?? "?")")
                continue
            }
            try? FileManager.default.removeItem(at: path)
            guard (try? photo.data.write(to: path, options: .atomic)) != nil else { return nil }
            // print reaches relay.log, the file pulled off a device.
            print("htree: read \(link.blobHash.prefix(8)) from \(url.host ?? "?") (\(photo.data.count) bytes, \(photo.mime))")
            return path
        }
        return nil
    }

    /// The body, or nil past `HtreeLink.maxBlobBytes`: read as it arrives
    /// and cut off there, whatever Content-Length says.
    private static func get(_ url: URL) async -> Data? {
        guard let (bytes, response) = try? await session.bytes(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              response.expectedContentLength <= Int64(HtreeLink.maxBlobBytes)
        else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > HtreeLink.maxBlobBytes { return nil }
            }
        } catch { return nil }
        return data
    }

    private static func serverList(_ author: String) async -> [String] {
        if let list = await MainActor.run(body: { NostrService.shared.serverLists[author] }) { return list }
        await MainActor.run { NostrService.shared.fetchMissingProfiles(for: [author], force: true) }
        let deadline = ContinuousClock.now + listWait
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(500))
            if let list = await MainActor.run(body: { NostrService.shared.serverLists[author] }) { return list }
        }
        return []
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// A server that passed the https check could redirect to a home-network
    /// host; no redirect is followed.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }
}

extension MediaCacheService {
    /// An `htree://` photo's decrypted bytes; nil when no server had them.
    func fetchHtree(_ url: URL, author: String?) async -> Data? {
        guard let file = await htreeFile(url, author: author) else { return nil }
        return try? Data(contentsOf: file)
    }

    /// An `htree://` photo's decrypted, checked file, for viewers, thumbnails and Save to Vault.
    func htreeFile(_ url: URL, author: String?) async -> URL? {
        guard let link = HtreeLink(url) else { return nil }
        // Already in the vault (saved, or the same photo from a Blossom link) or the cache, checked by hash.
        if let local = internalLocalFileURL(for: url) { return local }
        return await HtreeFetcher.shared.file(for: link, url: url, author: author)
    }
}
