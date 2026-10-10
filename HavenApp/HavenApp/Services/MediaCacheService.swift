import Foundation
import SwiftUI
import CryptoKit
import AVFoundation
import CoreMedia
import Combine

extension Notification.Name {
    static let mediaNotFoundChanged = Notification.Name("MediaCacheServiceNotFoundChanged")
}

class MediaCacheService: ObservableObject, @unchecked Sendable {
    static let shared = MediaCacheService()

    // Cache for temporary playback URLs (symlinks)
    private var playableURLs: [URL: URL] = [:]
    private let playableLock = NSLock()

    private let cacheDirectory: URL
    private let thumbnailDirectory: URL
    private var inFlightDownloads: [String: [CheckedContinuation<Data?, Never>]] = [:]
    /// Queued-or-running download operations by cache filename, so a view can
    /// re-rank a transfer it no longer (or now) needs. Guarded by downloadLock.
    private var downloadOperations: [String: Operation] = [:]
    private let downloadLock = NSLock()

    // In-memory decoded image cache (NSCache auto-evicts under memory pressure)
    private let imageCache: NSCache<NSURL, PlatformImage> = {
        let cache = NSCache<NSURL, PlatformImage>()
        cache.countLimit = 150
        // Feed photos decode at up to 800 px (~2 MB each), so 40 MB held only
        // ~20 and scrolling back re-decoded from disk with a spinner.
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    // In-memory thumbnail cache (keyed by url hash). Disk cache backs this.
    // NSCache auto-evicts under memory pressure and enforces count/cost limits.
    private let thumbnailMemoryCache: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.countLimit = 150
        cache.totalCostLimit = 30 * 1024 * 1024 // 30 MB
        return cache
    }()
    private let thumbnailCacheLock = NSLock()
    // Per-url in-flight thumbnail jobs to coalesce parallel requests
    private var inFlightThumbnails: [String: [CheckedContinuation<PlatformImage?, Never>]] = [:]

    let downloadQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MediaCacheDownloadQueue"
        queue.maxConcurrentOperationCount = 4
        return queue
    }()

    /// Videos download on their own lane: a video holds its slot for the whole
    /// file, and on the shared queue two or three of them starved every photo.
    private let videoDownloadQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MediaCacheVideoDownloadQueue"
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    // Throttling for CPU-intensive thumbnail generation
    let thumbnailQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MediaCacheThumbnailQueue"
        queue.maxConcurrentOperationCount = 2 // Limit concurrent AVAssetImageGenerator instances
        return queue
    }()

    private var _blossomDirectory: URL
    private let blossomLock = NSLock()

    private var blossomDirectory: URL {
        blossomLock.lock()
        defer { blossomLock.unlock() }
        return _blossomDirectory
    }

    // Thread-safe copy of local host for non-isolated access
    private var localHost: String = ""
    private let hostLock = NSLock()

    // User-flagged 404 URLs (persisted to UserDefaults). Filtering uses this set to
    // route flagged items to the dedicated 404 bucket in the viewer.
    // Keyed by URL with the date it was flagged: entries expire after
    // notFoundMaxAge and the map is capped, so a media-heavy feed can't
    // grow UserDefaults (deserialized in full on every launch) forever.
    private var notFoundURLs: [String: Date] = [:]
    private let notFoundLock = NSLock()
    private let notFoundDefaultsKey = "MediaCacheService.notFoundURLs"
    private let notFoundMaxAge: TimeInterval = 7 * 24 * 3600
    private let notFoundMaxCount = 500

    /// Mirror of `disableMediaCache`, readable from download threads.
    private var diskCacheDisabled = false
    private let diskCacheLock = NSLock()
    private var configCancellable: AnyCancellable?

    /// Ceiling for the media cache plus thumbnails. Time-based expiry alone
    /// let one week of scrolling fill 1.7 GB; past this, oldest files go first.
    static let maxCacheBytes: Int64 = 500 * 1024 * 1024

    #if !os(iOS)
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    #endif

    private init() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("Application Support directory unavailable")
        }
        let havenAppSupport = appSupport.appendingPathComponent("Haven", isDirectory: true)
        let dbDir = havenAppSupport.appendingPathComponent("haven_database", isDirectory: true)
        self.cacheDirectory = dbDir.appendingPathComponent("cache")
        self.thumbnailDirectory = dbDir.appendingPathComponent("thumbnails")
        self._blossomDirectory = dbDir.appendingPathComponent("blossom")

        createCacheDirectory()

        let cutoff = Date().addingTimeInterval(-notFoundMaxAge)
        if let stored = UserDefaults.standard.dictionary(forKey: notFoundDefaultsKey) as? [String: Date] {
            notFoundURLs = stored.filter { $0.value > cutoff }
        } else if let legacy = UserDefaults.standard.array(forKey: notFoundDefaultsKey) as? [String] {
            // Migrate the old un-dated [String] format; stamp with now so
            // existing entries age out on the normal schedule.
            let now = Date()
            notFoundURLs = Dictionary(uniqueKeysWithValues: legacy.map { ($0, now) })
        }
        // Re-persist so expiry and the legacy-format migration stick.
        UserDefaults.standard.set(notFoundURLs, forKey: notFoundDefaultsKey)

        // Respond to memory pressure by purging in-memory caches
        #if os(iOS)
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleMemoryPressure()
        }
        // A suspended app never receives memory warnings — it just sits at its full
        // resident size and is the first thing iOS jetsams under pressure. Drop the
        // heavy full-res image cache (and video buffers) when backgrounding so the
        // suspended footprint is much smaller; both reload from the disk cache on
        // return. Thumbnails are kept so the feed still scrolls instantly on resume.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleBackgrounding()
            DispatchQueue.global(qos: .utility).async {
                self?.trimToSizeLimit()
            }
        }
        #else
        // macOS: observe process info memory pressure via a background source
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            self?.handleMemoryPressure()
        }
        source.resume()
        self.memoryPressureSource = source
        #endif

        // Evict expired cache files on launch (read config on main, evict on background)
        DispatchQueue.main.async { [weak self] in
            let ttlDays = ConfigService.shared.config.cacheTTLDays
            self?.configCancellable = ConfigService.shared.$config
                .map(\.disableMediaCache)
                .removeDuplicates()
                .sink { disabled in
                    guard let self else { return }
                    self.diskCacheLock.withLock { self.diskCacheDisabled = disabled }
                }
            DispatchQueue.global(qos: .utility).async {
                self?.evictExpiredFiles(ttlDays: ttlDays)
                self?.trimToSizeLimit()
            }
        }

        // Drop playback/thumbnail symlinks that point into a previous app
        // container (iOS moves the container on every install and keeps tmp/).
        // They can never be opened, and left in place they block re-creation.
        let liveRoot = dbDir
        DispatchQueue.global(qos: .utility).async {
            let removed = PlayableLinks.purgeStale(in: FileManager.default.temporaryDirectory, liveRoot: liveRoot)
            if removed > 0 {
                Task { @MainActor in
                    RelayProcessManager.shared.addLog("Media: removed \(removed) stale playable links from a previous install", level: "INFO")
                }
            }
        }
    }

    // MARK: - In-Memory Image Cache

    func cachedImage(for url: URL) -> PlatformImage? {
        return imageCache.object(forKey: url as NSURL)
    }

    func cacheImage(_ image: PlatformImage, for url: URL) {
        imageCache.setObject(image, forKey: url as NSURL, cost: Self.decodedCost(of: image))
    }

    /// Decoded-bitmap cost in bytes, from real pixel dimensions. NSImage.size
    /// is in points and honors DPI metadata — a 300-dpi photo under-reports by
    /// ~17×, which let the 40 MB totalCostLimit admit hundreds of MB of
    /// decoded bitmaps before evicting anything.
    static func decodedCost(of image: PlatformImage) -> Int {
        #if os(macOS)
        var pixels = 0
        for rep in image.representations {
            pixels = max(pixels, rep.pixelsWide * rep.pixelsHigh)
        }
        if pixels == 0 {
            pixels = Int(image.size.width * image.size.height)
        }
        return pixels * 4
        #else
        return Int(image.size.width * image.scale * image.size.height * image.scale) * 4
        #endif
    }

    private func handleMemoryPressure() {
        imageCache.removeAllObjects()
        thumbnailMemoryCache.removeAllObjects()
        VideoPlayerCache.shared.evictAll()
        #if DEBUG
        print("MediaCacheService: Purged in-memory caches due to memory pressure")
        #endif
    }

    /// Shrink the suspended-app footprint: drop the large full-res image cache and
    /// video buffers, but keep the small thumbnail cache so the feed scrolls
    /// instantly when the user returns. Everything dropped reloads from disk.
    private func handleBackgrounding() {
        imageCache.removeAllObjects()
        VideoPlayerCache.shared.evictAll()
        #if DEBUG
        print("MediaCacheService: Dropped full-res image/video caches on backgrounding")
        #endif
    }

    // MARK: - 404 Tracking

    func isKnown404(url: URL) -> Bool {
        notFoundLock.lock()
        defer { notFoundLock.unlock() }
        return notFoundURLs[url.absoluteString] != nil
    }

    func known404Set() -> Set<String> {
        notFoundLock.lock()
        defer { notFoundLock.unlock() }
        return Set(notFoundURLs.keys)
    }

    func markNotFound(url: URL) {
        notFoundLock.lock()
        let inserted = notFoundURLs.updateValue(Date(), forKey: url.absoluteString) == nil
        if notFoundURLs.count > notFoundMaxCount {
            // Drop the oldest entries to stay within the cap
            let sorted = notFoundURLs.sorted { $0.value < $1.value }
            for (key, _) in sorted.prefix(notFoundURLs.count - notFoundMaxCount) {
                notFoundURLs.removeValue(forKey: key)
            }
        }
        let snapshot = notFoundURLs
        notFoundLock.unlock()
        guard inserted else { return }
        UserDefaults.standard.set(snapshot, forKey: notFoundDefaultsKey)
        NotificationCenter.default.post(name: .mediaNotFoundChanged, object: url)
    }

    func unmarkNotFound(url: URL) {
        notFoundLock.lock()
        let removed = notFoundURLs.removeValue(forKey: url.absoluteString) != nil
        let snapshot = notFoundURLs
        notFoundLock.unlock()
        guard removed else { return }
        UserDefaults.standard.set(snapshot, forKey: notFoundDefaultsKey)
        NotificationCenter.default.post(name: .mediaNotFoundChanged, object: url)
    }

    private func createCacheDirectory() {
        if !FileManager.default.fileExists(atPath: cacheDirectory.path) {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
        if !FileManager.default.fileExists(atPath: thumbnailDirectory.path) {
            try? FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        }
    }

    func cachePath(for url: URL) -> URL {
        let filename = hash(url: url)
        return cacheDirectory.appendingPathComponent(filename)
    }

    func isCached(url: URL) -> Bool {
        let path = cachePath(for: url)
        return FileManager.default.fileExists(atPath: path.path)
    }

    private var isDiskCacheDisabled: Bool {
        diskCacheLock.withLock { diskCacheDisabled }
    }

    func saveToCache(url: URL, data: Data) {
        guard !isDiskCacheDisabled else { return }
        // Guard: Don't cache extremely small files which are likely error messages/404 pages
        guard data.count > 100 else {
            #if DEBUG
            print("MediaCacheService: Skipping cache for \(url.absoluteString) - data too small (\(data.count) bytes)")
            #endif
            return
        }

        let path = cachePath(for: url)
        do {
            try data.write(to: path)
            #if DEBUG
            print("MediaCacheService: Cached \(url.lastPathComponent) to \(path.path)")
            #endif
        } catch {
            Task { @MainActor in RelayProcessManager.shared.addLog("MediaCache: Failed to cache \(url.lastPathComponent): \(error.localizedDescription)", level: "WARN") }
        }
    }

    func loadFromCache(url: URL) -> Data? {
        if let localURL = internalLocalFileURL(for: url) {
            return try? Data(contentsOf: localURL)
        }
        return nil
    }

    /// Internal version that resolves file paths even for local relay URLs.
    /// Used for components like AVAsset thumbnail generation which can handle raw files.
    ///
    /// Files named by a Blossom content hash are integrity-checked before being
    /// returned: a truncated/corrupt local copy (e.g. from an interrupted blob
    /// write) would otherwise shadow a perfectly healthy remote URL forever.
    func internalLocalFileURL(for url: URL) -> URL? {
        let blobHash = Self.blossomHash(in: url)

        // 1. Local relay media-tab URLs may point at files in Blossom by their
        // exact filename, not only by a bare sha256 hash. Resolve those directly
        // so AVFoundation does not have to stream through localhost on iOS.
        if isLocalURL(url), let localBlossomURL = blossomFile(named: url.lastPathComponent) {
            if let blobHash {
                return verifiedHashNamedFile(localBlossomURL, expectedHash: blobHash)
            }
            return localBlossomURL
        }

        // 2. Try to find if it's a local Blossom file we already have by hash.
        if let blobHash,
           let localBlossomURL = blossomFile(forHash: blobHash, extensionHint: url.pathExtension),
           let verified = verifiedHashNamedFile(localBlossomURL, expectedHash: blobHash) {
            return verified
        }

        // 3. Try the general cache
        let path = cachePath(for: url)
        if FileManager.default.fileExists(atPath: path.path) {
            // Blossom-hash cache entries are keyed (and named) by the blob's
            // content hash, so they can be verified too. URL-keyed entries can't.
            if let blobHash {
                return verifiedHashNamedFile(path, expectedHash: blobHash)
            }
            return path
        }

        return nil
    }

    // MARK: - Hash-Named File Integrity

    /// Verification verdicts keyed by path+size+mtime — a rewritten file re-verifies.
    private var integrityVerdicts: [String: Bool] = [:]
    private let integrityLock = NSLock()
    /// Files above this size are trusted without hashing; the failed-player remote
    /// fallback in VideoPlayerCache still heals them if they turn out corrupt.
    private static let integrityMaxHashBytes: UInt64 = 64 * 1024 * 1024

    /// Extracts a 64-hex Blossom content hash from the URL's last path component, if present.
    static func blossomHash(in url: URL) -> String? {
        let last = url.lastPathComponent
        let pattern = #"^([a-f0-9]{64})(\.[a-z0-9]+)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let ns = last as NSString
        guard let match = regex.firstMatch(in: last, options: [], range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range(at: 1)).lowercased()
    }

    /// Returns `fileURL` only if its content actually hashes to `expectedHash`
    /// (memoized per launch). A mismatching file is discarded — deleted from the
    /// cache, or quarantined with a `.corrupt` suffix in the Blossom store — so
    /// callers fall through to the healthy remote URL and the copy can heal.
    private func verifiedHashNamedFile(_ fileURL: URL, expectedHash: String) -> URL? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.resolvingSymlinksInPath().path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return nil }
        if size == 0 {
            discardCorruptFile(fileURL)
            return nil
        }
        if size > Self.integrityMaxHashBytes { return fileURL }

        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(fileURL.path)|\(size)|\(mtime)"
        integrityLock.lock()
        let cached = integrityVerdicts[key]
        integrityLock.unlock()
        if let cached { return cached ? fileURL : nil }

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1 << 20)
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let ok = digest == expectedHash

        integrityLock.lock()
        integrityVerdicts[key] = ok
        integrityLock.unlock()

        if !ok {
            #if DEBUG
            print("MediaCacheService: corrupt local copy of \(expectedHash.prefix(8))… (got \(digest.prefix(8))…), discarding")
            #endif
            Task { @MainActor in
                RelayProcessManager.shared.addLog("MediaCache: local copy of blob \(expectedHash.prefix(8))… is corrupt — using remote copy", level: "WARN")
            }
            discardCorruptFile(fileURL)
            return nil
        }
        return fileURL
    }

    /// Drops the disposable cached copy of a URL (used when a local copy failed
    /// to play so the next fetch re-downloads from the source).
    func discardCachedCopy(for url: URL) {
        let path = cachePath(for: url)
        try? FileManager.default.removeItem(at: path)
    }

    /// Cache entries are disposable and get deleted; Blossom blobs are relay data,
    /// so they're quarantined under a `.corrupt` suffix instead — HEAD /<hash>
    /// stops claiming the blob exists and a later re-mirror can heal it.
    private func discardCorruptFile(_ fileURL: URL) {
        if fileURL.path.hasPrefix(blossomDirectory.path) {
            let quarantined = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: quarantined)
            try? FileManager.default.moveItem(at: fileURL, to: quarantined)
        } else {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func blossomFile(named filename: String) -> URL? {
        guard !filename.isEmpty, filename != ".", filename != ".." else { return nil }
        let fileURL = blossomDirectory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    /// Returns true if a file with the given SHA256 hash exists in the local blossom directory.
    func isInLocalBlossom(hash: String) -> Bool {
        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { return false }
        return blossomFile(forHash: hash, extensionHint: "") != nil
    }

    private func blossomFile(forHash hash: String, extensionHint: String) -> URL? {
        if let exact = blossomFile(named: hash) {
            return exact
        }

        if !extensionHint.isEmpty, let withExtension = blossomFile(named: "\(hash).\(extensionHint)") {
            return withExtension
        }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: blossomDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return contents.first { $0.lastPathComponent.hasPrefix("\(hash).") && $0.pathExtension != "corrupt" }
    }

    /// Ensures the local file has a proper extension for AVFoundation playback.
    /// If the file is extensionless (Blossom), creates a temporary symlink with the inferred
    /// extension (from the source URL or `extensionHint`, defaulting to `.mp4`).
    func preparePlayableURL(for url: URL, extensionHint: String? = nil) -> URL? {
        guard let localURL = internalLocalFileURL(for: url) else { return nil }

        let resolvedExt = inferContainerExtension(sourceURL: url, localURL: localURL, mimeHint: extensionHint)

        // If it already has a usable extension, we're good
        if !localURL.pathExtension.isEmpty {
            return localURL
        }

        playableLock.lock()
        defer { playableLock.unlock() }

        // Same-process fast path: a link we made earlier this launch. Verified
        // with lstat semantics — never trust `fileExists` on a symlink here.
        if let existingInfo = playableURLs[localURL],
           case .liveLink(let dest) = PlayableLinks.inspect(existingInfo), dest == localURL.path {
            return existingInfo
        }

        let tempDir = FileManager.default.temporaryDirectory
        let symlinkName = localURL.lastPathComponent + "." + resolvedExt
        let symlinkURL = tempDir.appendingPathComponent(symlinkName)

        do {
            // Replaces a dangling link left behind by a previous app container
            // (every iOS reinstall moves the container but carries tmp/ along)
            // instead of failing with EEXIST on it. See PlayableLinks.
            let outcome = try PlayableLinks.ensureLink(at: symlinkURL, to: localURL)
            playableURLs[localURL] = symlinkURL
            #if DEBUG
            print("MediaCacheService: playable symlink \(outcome) at \(symlinkURL.path)")
            #endif
            if outcome == .replaced {
                Task { @MainActor in
                    RelayProcessManager.shared.addLog("Media: replaced stale playable link \(symlinkName)", level: "INFO")
                }
            }
            return symlinkURL
        } catch {
            #if DEBUG
            print("MediaCacheService: Failed to create symlink: \(error)")
            #endif
            Task { @MainActor in
                RelayProcessManager.shared.addLog("Media: playable link failed for \(symlinkName): \(error.localizedDescription)", level: "WARN")
            }
            // Returning the bare extensionless file would make AVFoundation fail
            // with -11828 "Cannot Open" — let callers fall back to the remote URL.
            return nil
        }
    }

    /// Decides what container extension to use for a symlink. Order of preference:
    /// 1. mimeHint (mime type string OR a plain extension)
    /// 2. source URL pathExtension
    /// 3. local URL pathExtension (when present)
    /// 4. fallback `mp4`
    private func inferContainerExtension(sourceURL: URL, localURL: URL, mimeHint: String?) -> String {
        if let hint = mimeHint?.lowercased(), !hint.isEmpty {
            if hint.contains("webm") { return "webm" }
            if hint.contains("quicktime") || hint.contains("mov") { return "mov" }
            if hint.contains("m4v") { return "m4v" }
            if hint.contains("hevc") || hint.contains("h265") { return "mp4" }
            if hint.contains("mp4") || hint.contains("mpeg") { return "mp4" }
            // If caller passed a bare extension like "mov"
            if hint.count <= 5 && !hint.contains("/") { return hint }
        }
        let srcExt = sourceURL.pathExtension.lowercased()
        if !srcExt.isEmpty { return srcExt }
        let localExt = localURL.pathExtension.lowercased()
        if !localExt.isEmpty { return localExt }
        return "mp4"
    }

    /// - Parameter priority: Rank among queued downloads. On-screen media uses
    ///   the default; feed prefetch passes `.low` so it never delays what the
    ///   user is looking at. A later, higher-priority request for the same URL
    ///   promotes the queued transfer.
    func fetchData(url: URL, priority: Operation.QueuePriority = .normal) async -> Data? {
        // Bypass cache for local relay Blossom URLs to avoid redundant storage and preserve MIME handling
        if isLocalURL(url) {
            do {
                let (data, response) = try await TLSSkipSession.shared.data(from: url)
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    return data
                }
            } catch {
                #if DEBUG
                print("MediaCacheService: Failed to fetch local URL \(url.absoluteString): \(error.localizedDescription)")
                #endif
            }
            return nil
        }

        let filename = hash(url: url)
        // A blob already in the vault is never downloaded into the cache too.
        // Exact-name lookups only: no directory scan on the fetch path.
        if let blobHash = Self.blossomHash(in: url),
           let vaultFile = blossomFile(named: blobHash) ?? blossomFile(named: "\(blobHash).\(url.pathExtension)"),
           let verified = verifiedHashNamedFile(vaultFile, expectedHash: blobHash),
           let vaultData = cachedFileData(at: verified) {
            return vaultData
        }
        if let cachedData = cachedFileData(at: cacheDirectory.appendingPathComponent(filename)) {
            return cachedData
        }

        return await withCheckedContinuation { continuation in
            downloadLock.lock()
            if var waiters = inFlightDownloads[filename] {
                waiters.append(continuation)
                inFlightDownloads[filename] = waiters
                if let op = downloadOperations[filename], op.queuePriority.rawValue < priority.rawValue {
                    op.queuePriority = priority
                }
                downloadLock.unlock()
            } else {
                inFlightDownloads[filename] = [continuation]
                downloadLock.unlock()

                #if DEBUG
                print("MediaCacheService: Starting download for \(filename) (URL: \(url.absoluteString))")
                #endif
                // Stream to disk via downloadTask — a dataTask buffers the whole
                // body in RAM, which for videos means hundreds of MB per fetch.
                // Run on the bounded downloadQueue (the operation blocks its slot
                // until the transfer finishes) so a fast scroll through a
                // video-heavy feed can't stack unbounded concurrent downloads.
                let operation = BlockOperation { [weak self] in
                    guard let self = self else { return }
                    let semaphore = DispatchSemaphore(value: 0)
                    var result: Data?
                    let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, _ in
                        defer { semaphore.signal() }
                        guard let self = self, let tempURL = tempURL,
                              let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                            return
                        }
                        // The temp file is deleted when this handler returns, so
                        // adopt it into the cache here.
                        result = self.adoptDownloadedFile(tempURL, sourceURL: url)
                    }
                    task.resume()
                    semaphore.wait()

                    self.downloadLock.lock()
                    let waiters = self.inFlightDownloads[filename] ?? []
                    self.inFlightDownloads.removeValue(forKey: filename)
                    self.downloadOperations.removeValue(forKey: filename)
                    self.downloadLock.unlock()
                    for waiter in waiters {
                        waiter.resume(returning: result)
                    }
                }
                operation.queuePriority = priority
                downloadLock.lock()
                downloadOperations[filename] = operation
                downloadLock.unlock()
                let isVideo = MediaKindResolver.cachedKind(for: url) == .video
                (isVideo ? videoDownloadQueue : downloadQueue).addOperation(operation)
            }
        }
    }

    /// Sends a not-yet-started download to the back of the line when its view
    /// scrolls away (or forward again when it returns). The transfer is kept,
    /// not cancelled, so scrolling back still finds it cached.
    func setDownloadPriority(_ priority: Operation.QueuePriority, for url: URL) {
        let filename = hash(url: url)
        downloadLock.lock()
        downloadOperations[filename]?.queuePriority = priority
        downloadLock.unlock()
    }

    /// Moves a completed downloadTask temp file into the cache and returns its
    /// contents. Mirrors saveToCache's tiny-body guard: likely error pages are
    /// returned to the caller but never cached.
    private func adoptDownloadedFile(_ tempURL: URL, sourceURL: URL) -> Data? {
        let fm = FileManager.default
        let size = ((try? fm.attributesOfItem(atPath: tempURL.path))?[.size] as? NSNumber)?.intValue ?? 0
        guard !isDiskCacheDisabled else {
            return try? Data(contentsOf: tempURL)
        }
        guard size > 100 else {
            #if DEBUG
            print("MediaCacheService: Skipping cache for \(sourceURL.absoluteString) - data too small (\(size) bytes)")
            #endif
            return try? Data(contentsOf: tempURL)
        }

        let path = cachePath(for: sourceURL)
        do {
            if fm.fileExists(atPath: path.path) {
                try fm.removeItem(at: path)
            }
            try fm.moveItem(at: tempURL, to: path)
            #if DEBUG
            print("MediaCacheService: Cached \(sourceURL.lastPathComponent) to \(path.path)")
            #endif
        } catch {
            Task { @MainActor in RelayProcessManager.shared.addLog("MediaCache: Failed to cache \(sourceURL.lastPathComponent): \(error.localizedDescription)", level: "WARN") }
            // Must read fully: the temp file vanishes when the completion
            // handler returns, so a mapped Data would dangle.
            return try? Data(contentsOf: tempURL)
        }
        return cachedFileData(at: path)
    }

    /// Reads a cache file, memory-mapping large ones so a cached video returns
    /// file-backed (evictable) pages instead of hundreds of MB of dirty heap.
    private func cachedFileData(at path: URL) -> Data? {
        let size = ((try? FileManager.default.attributesOfItem(atPath: path.path))?[.size] as? NSNumber)?.intValue
        guard let size = size else { return nil }
        if size > 8 << 20 {
            return try? Data(contentsOf: path, options: .mappedIfSafe)
        }
        return try? Data(contentsOf: path)
    }

    // MARK: - Video Thumbnails

    /// Returns a thumbnail synchronously if we have one in memory or on disk. Cheap; safe
    /// to call from view init or onAppear before async work kicks off.
    func cachedThumbnail(for url: URL) -> PlatformImage? {
        let key = hash(url: url)
        let nsKey = key as NSString
        if let image = thumbnailMemoryCache.object(forKey: nsKey) {
            return image
        }

        let diskPath = thumbnailDiskPath(for: key)
        guard FileManager.default.fileExists(atPath: diskPath.path),
              let data = try? Data(contentsOf: diskPath),
              let image = PlatformImage(data: data) else {
            return nil
        }

        thumbnailMemoryCache.setObject(image, forKey: nsKey, cost: Self.decodedCost(of: image))
        return image
    }

    /// Generates (or fetches from cache) a thumbnail for the given video URL.
    /// Surefire pipeline:
    /// 1. Check memory + disk caches.
    /// 2. Ensure a local file exists (download remote if necessary).
    /// 3. Build a properly-extensioned local file URL so AVFoundation accepts the container.
    /// 4. Try several time points with loose tolerance; first success wins.
    /// 5. Persist to memory + disk so subsequent renders are instant.
    /// - Parameter allowFullDownload: When `true` (default) a remote video that
    ///   isn't cached is downloaded in full before the frame is extracted. Pass
    ///   `false` from condensed/thumbnail contexts so a tiny preview never pulls an
    ///   entire video over the network — the frame is then extracted directly from
    ///   the remote asset via byte-range requests instead.
    func generateThumbnail(for url: URL, mimeType: String? = nil, allowFullDownload: Bool = true) async -> PlatformImage? {
        if let cached = cachedThumbnail(for: url) {
            return cached
        }

        let key = hash(url: url)

        return await withCheckedContinuation { (continuation: CheckedContinuation<PlatformImage?, Never>) in
            downloadLock.lock()
            if inFlightThumbnails[key] != nil {
                // Already running — join the waiter list and let the leader broadcast.
                inFlightThumbnails[key]?.append(continuation)
                downloadLock.unlock()
                return
            }
            // We're the leader. Reserve the slot and kick off the job.
            inFlightThumbnails[key] = []
            downloadLock.unlock()

            Task.detached(priority: .utility) { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }
                await self.runThumbnailJob(url: url, key: key, mimeType: mimeType, allowFullDownload: allowFullDownload, leader: continuation)
            }
        }
    }

    private func runThumbnailJob(url: URL, key: String, mimeType: String?, allowFullDownload: Bool, leader: CheckedContinuation<PlatformImage?, Never>) async {
        // 1. Ensure the file is on disk. For remote URLs that aren't cached, pull them
        // down — but only when the caller permits a full download. Condensed/thumbnail
        // contexts pass allowFullDownload:false so generating a small preview never
        // autoloads an entire video; renderThumbnail then extracts the frame directly
        // from the remote asset via byte-range requests.
        if allowFullDownload, internalLocalFileURL(for: url) == nil, !isLocalURL(url) {
            _ = await fetchData(url: url)
        }

        // 2. Run AVAssetImageGenerator on the throttled queue.
        let image: PlatformImage? = await withCheckedContinuation { (inner: CheckedContinuation<PlatformImage?, Never>) in
            let op = BlockOperation { [weak self] in
                Task {
                    let result = await self?.renderThumbnail(url: url, mimeType: mimeType)
                    inner.resume(returning: result)
                }
            }
            self.thumbnailQueue.addOperation(op)
        }

        // 3. Persist + broadcast
        if let image = image {
            thumbnailMemoryCache.setObject(image, forKey: key as NSString, cost: Self.decodedCost(of: image))
            saveThumbnailToDisk(image, key: key)
        }

        let waiters = downloadLock.withLock {
            let w = inFlightThumbnails[key] ?? []
            inFlightThumbnails.removeValue(forKey: key)
            return w
        }

        leader.resume(returning: image)
        for waiter in waiters {
            waiter.resume(returning: image)
        }
    }

    /// Performs the actual AVFoundation work. Runs on the throttled thumbnail queue.
    private func renderThumbnail(url: URL, mimeType: String?) async -> PlatformImage? {
        // Walk the same source ladder playback uses (verified local file →
        // remote with known/sniffed MIME → remote container guesses), so a
        // corrupt local copy or a mislabeling server can't kill thumbnails.
        let candidates = VideoPlaybackService.shared.resolveCandidates(for: url, mimeHint: mimeType)
        for candidate in candidates {
            #if DEBUG
            print("MediaCacheService: renderThumbnail url=\(url.absoluteString) trying=\(candidate.label)")
            #endif
            if let image = await extractFrame(from: candidate.assetURL, options: candidate.assetOptions, sourceURL: url) {
                return image
            }
        }

        // Last resort: if the local file has no extension and we somehow used the wrong one,
        // try one more symlink with a different extension permutation.
        if let local = self.internalLocalFileURL(for: url), local.pathExtension.isEmpty {
            for alt in ["mp4", "mov", "m4v", "webm"] {
                if let symlink = self.makeOneOffSymlink(for: local, extension: alt) {
                    let altAsset = AVURLAsset(url: symlink)
                    let altGen = AVAssetImageGenerator(asset: altAsset)
                    altGen.appliesPreferredTrackTransform = true
                    altGen.maximumSize = CGSize(width: 600, height: 600)
                    altGen.requestedTimeToleranceBefore = CMTime(seconds: 5, preferredTimescale: 600)
                    altGen.requestedTimeToleranceAfter = CMTime(seconds: 5, preferredTimescale: 600)
                    if let cg = try? altGen.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil) {
                        #if os(macOS)
                        return NSImage(cgImage: cg, size: NSZeroSize)
                        #else
                        return UIImage(cgImage: cg)
                        #endif
                    }
                }
            }
        }

        #if DEBUG
        print("MediaCacheService: Thumbnail generation exhausted all fallbacks for \(url.lastPathComponent)")
        #endif
        return nil
    }

    /// Tries several time points against one asset URL; first extractable frame wins.
    private func extractFrame(from playableURL: URL, options: [String: Any] = [:], sourceURL: URL) async -> PlatformImage? {
        var assetOptions: [String: Any] = options
        assetOptions[AVURLAssetPreferPreciseDurationAndTimingKey] = false
        let asset = AVURLAsset(url: playableURL, options: assetOptions)

        // Times to try, in order. First reachable keyframe wins.
        var times: [CMTime] = [
            CMTime(seconds: 0.0, preferredTimescale: 600),
            CMTime(seconds: 0.5, preferredTimescale: 600),
            CMTime(seconds: 1.0, preferredTimescale: 600),
            CMTime(seconds: 3.0, preferredTimescale: 600),
        ]
        // Add a duration-relative target as a last resort (in case the head is unreadable).
        let duration = try? await asset.load(.duration)
        if let duration = duration, duration.isValid && !duration.isIndefinite && duration.value > 0, let seconds = Double(duration.seconds) as Double? {
            if seconds > 5 {
                times.append(CMTime(seconds: min(seconds * 0.1, 10), preferredTimescale: 600))
            }
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 600)
        // Loose tolerance: take whatever frame is closest. Strict tolerance is the #1 reason
        // generation fails on videos without keyframes at the exact requested time.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 5, preferredTimescale: 600)

        for time in times {
            do {
                let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
                #if os(macOS)
                return NSImage(cgImage: cgImage, size: NSZeroSize)
                #else
                return UIImage(cgImage: cgImage)
                #endif
            } catch {
                #if DEBUG
                print("MediaCacheService: thumb attempt at \(time.seconds)s failed for \(sourceURL.lastPathComponent): \(error.localizedDescription)")
                #endif
                continue
            }
        }
        return nil
    }

    /// Gives an extensionless blob an alternate container extension for a
    /// thumbnail retry. Deterministic name (`<blob>.<ext>`) so the link is
    /// reused across launches and swept by PlayableLinks.purgeStale — the old
    /// `thumb_<uuid>` scheme leaked one link per attempt, forever.
    private func makeOneOffSymlink(for localURL: URL, extension ext: String) -> URL? {
        let linkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(localURL.lastPathComponent + "." + ext)
        do {
            try PlayableLinks.ensureLink(at: linkURL, to: localURL)
            return linkURL
        } catch {
            return nil
        }
    }

    private func thumbnailDiskPath(for key: String) -> URL {
        return thumbnailDirectory.appendingPathComponent("\(key).jpg")
    }

    // MARK: - Avatar Thumbnails

    /// Where the small copy of a profile picture lives. Avatars keep only this
    /// copy on disk, not the original (often several MB for a picture drawn
    /// a few dozen points wide). Its own name, so it is never mistaken for
    /// the original or for a video thumbnail of the same URL.
    private func avatarThumbnailPath(for url: URL, maxPixel: Int) -> URL {
        thumbnailDirectory.appendingPathComponent("avatar-\(maxPixel)-\(hash(url: url))")
    }

    func avatarThumbnailData(for url: URL, maxPixel: Int) -> Data? {
        try? Data(contentsOf: avatarThumbnailPath(for: url, maxPixel: maxPixel))
    }

    func hasAvatarThumbnail(for url: URL, maxPixel: Int) -> Bool {
        FileManager.default.fileExists(atPath: avatarThumbnailPath(for: url, maxPixel: maxPixel).path)
    }

    func saveAvatarThumbnail(_ data: Data, for url: URL, maxPixel: Int) {
        guard !isDiskCacheDisabled else { return }
        try? data.write(to: avatarThumbnailPath(for: url, maxPixel: maxPixel), options: .atomic)
    }

    private func saveThumbnailToDisk(_ image: PlatformImage, key: String) {
        let path = thumbnailDiskPath(for: key)
        #if os(macOS)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            return
        }
        try? data.write(to: path)
        #else
        guard let data = image.jpegData(compressionQuality: 0.7) else { return }
        try? data.write(to: path)
        #endif
    }

    func updateLocalHost(_ host: String) {
        hostLock.lock()
        defer { hostLock.unlock() }
        self.localHost = host.lowercased()
        #if DEBUG
        print("MediaCacheService: Updated local host to \(self.localHost)")
        #endif
    }

    func updateBlossomDirectory(_ directory: URL) {
        blossomLock.lock()
        defer { blossomLock.unlock() }
        self._blossomDirectory = directory
        #if DEBUG
        print("MediaCacheService: Updated blossom directory to \(directory.path)")
        #endif
    }

    private func isLocalURL(_ url: URL) -> Bool {
        hostLock.lock()
        let sanitized = self.localHost
        hostLock.unlock()

        let host = url.host?.lowercased() ?? ""

        // Match against localhost, 127.0.0.1
        if host == "localhost" || host == "127.0.0.1" {
            return true
        }

        if sanitized.isEmpty { return false }

        // Split by colon to ignore port for comparison
        let sanitizedHost = sanitized.split(separator: ":").first.map(String.init) ?? sanitized

        return host == sanitizedHost || host.hasSuffix("." + sanitizedHost)
    }

    /// Where this file lives as far as the phone is concerned. A file stored
    /// in the vault counts as on the phone even when it is shown through a
    /// Blossom server's URL — the gallery promotes items to a mirror URL.
    func getSource(for url: URL) -> MediaSource {
        if isLocalURL(url) {
            return .blossom
        } else if let hash = Self.blossomHash(in: url), isInLocalBlossom(hash: hash) {
            return .blossom
        } else if isCached(url: url) {
            return .cached
        } else {
            return .remote
        }
    }

    private func hash(url: URL) -> String {
        // Optimization: If the URL contains a 64-char Blossom hash, use it directly as the cache key.
        // This aligns with how the Go relay stores files and allows different URLs for the same
        // content (e.g. extensioned vs non-extensioned) to share the cache.
        if let blobHash = Self.blossomHash(in: url) {
            return blobHash
        }

        let inputData = Data(url.absoluteString.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// What `clearCache()` did, so the UI can say it.
    struct ClearCacheResult: Sendable {
        let bytesFreed: Int64
        let filesRemoved: Int
        let filesFailed: Int
    }

    /// Bytes held by temporary copies: the media cache and its thumbnails.
    /// The vault (Blossom store) is not counted — clearing never touches it.
    func cacheSizeBytes() -> Int64 {
        var total: Int64 = 0
        for dir in [cacheDirectory, thumbnailDirectory] {
            guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { continue }
            for case let fileURL as URL in walker {
                guard let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true else { continue }
                total += Int64(values.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    /// Clears the media cache, its thumbnails and the decoded images held in
    /// memory, while preserving Blossom data. Keeps going past a file it
    /// cannot remove, and reports what it did. Posts `.havenMediaCacheCleared`
    /// so open views re-read where each file lives.
    @discardableResult
    func clearCache() -> ClearCacheResult {
        let fm = FileManager.default
        let sizeBefore = cacheSizeBytes()
        var removed = 0
        var failed = 0
        for dir in [cacheDirectory, thumbnailDirectory] {
            let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for fileURL in contents {
                // The thumbnails directory sits beside the cache, never inside
                // it, but skip it by name in case an old install nested it.
                if dir == cacheDirectory && fileURL.lastPathComponent == "thumbnails" { continue }
                do {
                    try fm.removeItem(at: fileURL)
                    removed += 1
                } catch {
                    failed += 1
                    Task { @MainActor in RelayProcessManager.shared.addLog("MediaCache: could not remove \(fileURL.lastPathComponent): \(error.localizedDescription)", level: "ERROR") }
                }
            }
        }
        imageCache.removeAllObjects()
        thumbnailMemoryCache.removeAllObjects()
        let freed = max(0, sizeBefore - cacheSizeBytes())
        Task { @MainActor in
            RelayProcessManager.shared.addLog("MediaCache: cleared \(removed) files, \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)) freed, \(failed) failed (Blossom data preserved)")
            NotificationCenter.default.post(name: .havenMediaCacheCleared, object: nil)
        }
        return ClearCacheResult(bytesFreed: freed, filesRemoved: removed, filesFailed: failed)
    }

    /// Removes cached files older than the given TTL.
    /// Called automatically on launch. Skips Blossom data.
    func evictExpiredFiles(ttlDays: Int) {
        guard ttlDays > 0 else { return } // 0 = never expire
        let cutoff = Date().addingTimeInterval(-Double(ttlDays) * 86400)
        let fm = FileManager.default
        var evictedCount = 0

        for dir in [cacheDirectory, thumbnailDirectory] {
            guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for fileURL in contents {
                guard let vals = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modified = vals.contentModificationDate,
                      modified < cutoff else { continue }
                try? fm.removeItem(at: fileURL)
                evictedCount += 1
            }
        }

        if evictedCount > 0 {
            thumbnailMemoryCache.removeAllObjects()
            #if DEBUG
            print("MediaCacheService: Evicted \(evictedCount) expired files (TTL: \(ttlDays) days)")
            #endif
        }
    }

    /// Deletes the oldest cached files until the cache and thumbnails fit
    /// under `maxCacheBytes`. Runs on launch and on backgrounding. Skips Blossom data.
    func trimToSizeLimit(maxBytes: Int64 = MediaCacheService.maxCacheBytes) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
        var files: [(url: URL, size: Int64, modified: Date)] = []
        var total: Int64 = 0
        for dir in [cacheDirectory, thumbnailDirectory] {
            guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { continue }
            for fileURL in contents {
                guard let vals = try? fileURL.resourceValues(forKeys: Set(keys)),
                      vals.isRegularFile == true else { continue }
                let size = Int64(vals.totalFileAllocatedSize ?? 0)
                files.append((fileURL, size, vals.contentModificationDate ?? .distantPast))
                total += size
            }
        }
        guard total > maxBytes else { return }

        let before = total
        var removed = 0
        for file in files.sorted(by: { $0.modified < $1.modified }) {
            guard total > maxBytes else { break }
            if (try? fm.removeItem(at: file.url)) != nil {
                total -= file.size
                removed += 1
            }
        }
        thumbnailMemoryCache.removeAllObjects()
        let freed = before - total
        Task { @MainActor in
            RelayProcessManager.shared.addLog("MediaCache: over size limit, removed \(removed) oldest files, \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)) freed")
        }
    }

    enum MediaSource: String {
        case blossom = "On phone"
        case cached = "Temporary copy"
        case remote = "Link only"

        var isLocal: Bool {
            return self == .blossom
        }

        var color: Color {
            switch self {
            case .blossom: return .green
            case .cached: return .blue
            case .remote: return .orange
            }
        }

        var icon: String {
            switch self {
            case .blossom: return "server.rack"
            case .cached: return "archivebox.fill"
            case .remote: return "globe"
            }
        }
    }

}
