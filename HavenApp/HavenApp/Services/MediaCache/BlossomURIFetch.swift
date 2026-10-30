import Foundation

/// Reads a BUD-10 `blossom:` link's file: the link's `xs` servers, then the
/// author's kind 10063 list, then this account's media servers and the
/// new-account defaults. Each answer is hashed before it is kept; the first
/// one that matches lands in the media cache under the link's sha256, where
/// every photo, thumbnail and player path already looks. A link no server
/// can serve is remembered for `retryAfter`, so a feed full of it costs one try.
actor BlossomURIFetcher {
    static let shared = BlossomURIFetcher()

    /// Servers one link may ask from its own hints, and again from the
    /// author's list and ours together.
    static let maxServers = 5
    /// The most one file may be. Bigger answers are dropped unread.
    static let maxBytes: Int64 = 512 << 20
    /// A link that failed everywhere is not asked again before this.
    static let retryAfter: TimeInterval = 120
    /// How long a read waits for an author's 10063 it has just asked for.
    static let listWait: Duration = .seconds(4)

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 300
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private var inFlight: [String: Task<URL?, Never>] = [:]
    /// Cached files already hashed this launch, by path, size and mtime.
    private var verified: Set<String> = []
    private var failedAt: [String: Date] = [:]
    /// Note authors by sha256, for links without `as`.
    private var noteAuthors: [String: String] = [:]

    /// Remember who posted these links, so a link without `as` can still use
    /// its author's server list wherever it is drawn.
    nonisolated static func register(_ urls: [URL], author: String) {
        let hashes = urls.compactMap { BlossomURI($0)?.sha256 }
        guard !hashes.isEmpty else { return }
        Task { await shared.noteAuthors(hashes, author) }
    }

    private func noteAuthors(_ hashes: [String], _ author: String) {
        for hash in hashes where noteAuthors[hash] == nil { noteAuthors[hash] = author }
    }

    /// The verified local file for `uri`, downloading it if needed; nil when
    /// no server had the right bytes.
    func file(for uri: BlossomURI, link: URL, author: String?) async -> URL? {
        let cache = MediaCacheService.shared
        let path = cache.cachePath(for: link)
        // Any https download of `…/<sha256>` shares this file, so it is
        // hashed before it stands in for the link.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path.path) {
            let stamp = "\(path.path)|\(attrs[.size] ?? 0)|\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
            if verified.contains(stamp) { return path }
            if uri.matches(file: path) { verified.insert(stamp); return path }
            try? FileManager.default.removeItem(at: path)
        }
        if let failed = failedAt[uri.sha256], Date().timeIntervalSince(failed) < Self.retryAfter { return nil }
        if let running = inFlight[uri.sha256] { return await running.value }

        let author = uri.author ?? author ?? noteAuthors[uri.sha256]
        let task = Task { await Self.download(uri, author: author, to: path) }
        inFlight[uri.sha256] = task
        let result = await task.value
        inFlight[uri.sha256] = nil
        if result == nil { failedAt[uri.sha256] = Date() } else { failedAt[uri.sha256] = nil }
        return result
    }

    /// The link's own servers first; the author's list is only looked up
    /// (and waited for) when none of them had the file.
    private static func download(_ uri: BlossomURI, author: String?, to path: URL) async -> URL? {
        let own = uri.candidates(authorServers: [], fallbackServers: [])
        if let file = await firstMatch(uri, in: Array(own.prefix(maxServers)), to: path) { return file }
        var authorServers: [String] = []
        if let author { authorServers = await serverList(author) }
        let ours = await MainActor.run { ConfigService.shared.config.blossomMirrors }
        let rest = uri.candidates(authorServers: authorServers,
                                  fallbackServers: ours + HavenConfig.newAccountBlossomMirrors)
            .filter { !own.contains($0) }
        if let file = await firstMatch(uri, in: Array(rest.prefix(maxServers)), to: path) { return file }
        print("Blossom: \(uri.sha256.prefix(8)) unavailable on \(min(own.count, maxServers) + min(rest.count, maxServers)) servers")
        return nil
    }

    /// GETs `/<sha256>.<ext>` from each in turn; the first whole body that
    /// hashes to the link moves into the cache at `path`.
    private static func firstMatch(_ uri: BlossomURI, in urls: [URL], to path: URL) async -> URL? {
        for url in urls {
            guard let (temp, response) = try? await session.download(from: url) else { continue }
            defer { try? FileManager.default.removeItem(at: temp) }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let size = (try? temp.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                  Int64(size) <= maxBytes,
                  uri.matches(file: temp)
            else {
                print("Blossom: \(uri.sha256.prefix(8)) not on \(url.host ?? "?")")
                continue
            }
            try? FileManager.default.removeItem(at: path)
            guard (try? FileManager.default.moveItem(at: temp, to: path)) != nil else { return nil }
            // print reaches relay.log, the file pulled off a device.
            print("Blossom: read \(uri.sha256.prefix(8)) from \(url.host ?? "?") (\(size) bytes)")
            return path
        }
        return nil
    }

    /// The author's newest 10063 servers, asking relays once and waiting
    /// briefly when none has been seen yet.
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
}

extension MediaCacheService {
    /// A `blossom:` link's bytes, checked against its hash; nil when no
    /// server had them.
    func fetchBlossomURI(_ url: URL, author: String?) async -> Data? {
        guard let file = await blossomURIFile(url, author: author) else { return nil }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return try? Data(contentsOf: file, options: size > 8 << 20 ? .mappedIfSafe : [])
    }

    /// A `blossom:` link's verified file, for players and thumbnails.
    func blossomURIFile(_ url: URL, author: String?) async -> URL? {
        guard let uri = BlossomURI(url) else { return nil }
        return await BlossomURIFetcher.shared.file(for: uri, link: url, author: author)
    }
}
