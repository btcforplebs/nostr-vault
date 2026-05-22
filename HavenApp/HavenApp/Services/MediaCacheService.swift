import Foundation
import SwiftUI
import CryptoKit
import AVFoundation
import CoreMedia

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
    private let downloadLock = NSLock()

    // In-memory thumbnail cache (keyed by url hash). Disk cache backs this.
    private var thumbnailMemoryCache: [String: PlatformImage] = [:]
    private let thumbnailCacheLock = NSLock()
    // Per-url in-flight thumbnail jobs to coalesce parallel requests
    private var inFlightThumbnails: [String: [CheckedContinuation<PlatformImage?, Never>]] = [:]

    let downloadQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MediaCacheDownloadQueue"
        queue.maxConcurrentOperationCount = 4
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
    private var notFoundURLs: Set<String> = []
    private let notFoundLock = NSLock()
    private let notFoundDefaultsKey = "MediaCacheService.notFoundURLs"


    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let havenAppSupport = appSupport.appendingPathComponent("Haven", isDirectory: true)
        let dbDir = havenAppSupport.appendingPathComponent("haven_database", isDirectory: true)
        self.cacheDirectory = dbDir.appendingPathComponent("cache")
        self.thumbnailDirectory = dbDir.appendingPathComponent("thumbnails")
        self._blossomDirectory = dbDir.appendingPathComponent("blossom")

        createCacheDirectory()

        if let stored = UserDefaults.standard.array(forKey: notFoundDefaultsKey) as? [String] {
            notFoundURLs = Set(stored)
        }
    }

    // MARK: - 404 Tracking

    func isKnown404(url: URL) -> Bool {
        notFoundLock.lock()
        defer { notFoundLock.unlock() }
        return notFoundURLs.contains(url.absoluteString)
    }

    func known404Set() -> Set<String> {
        notFoundLock.lock()
        defer { notFoundLock.unlock() }
        return notFoundURLs
    }

    func markNotFound(url: URL) {
        notFoundLock.lock()
        let inserted = notFoundURLs.insert(url.absoluteString).inserted
        let snapshot = Array(notFoundURLs)
        notFoundLock.unlock()
        guard inserted else { return }
        UserDefaults.standard.set(snapshot, forKey: notFoundDefaultsKey)
        NotificationCenter.default.post(name: .mediaNotFoundChanged, object: url)
    }

    func unmarkNotFound(url: URL) {
        notFoundLock.lock()
        let removed = notFoundURLs.remove(url.absoluteString) != nil
        let snapshot = Array(notFoundURLs)
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

    func saveToCache(url: URL, data: Data) {
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
            #if DEBUG
            print("MediaCacheService: Failed to cache \(url.absoluteString): \(error.localizedDescription)")
            #endif
        }
    }

    func loadFromCache(url: URL) -> Data? {
        if let localURL = internalLocalFileURL(for: url) {
            return try? Data(contentsOf: localURL)
        }
        return nil
    }

    /// Returns a local file:// URL if the media is cached or exists in Blossom.
    /// This is essential for AVFoundation which often fails to play from localhost/127.0.0.1
    /// or requires specific configurations for local network access.
    func localFileURL(for url: URL) -> URL? {
        // Guard: For local relay URLs (including domains), we MUST use HTTP(S) to preserve
        // the MIME type hints provided by the Blossom server. Resolving to file://
        // causes AVFoundation to fail on extensionless hashed files.
        if isLocalURL(url) {
            return nil
        }
        return internalLocalFileURL(for: url)
    }

    /// Internal version that resolves file paths even for local relay URLs.
    /// Used for components like AVAsset thumbnail generation which can handle raw files.
    func internalLocalFileURL(for url: URL) -> URL? {
        // 1. Local relay media-tab URLs may point at files in Blossom by their
        // exact filename, not only by a bare sha256 hash. Resolve those directly
        // so AVFoundation does not have to stream through localhost on iOS.
        if isLocalURL(url), let localBlossomURL = blossomFile(named: url.lastPathComponent) {
            return localBlossomURL
        }

        // 2. Try to find if it's a local Blossom file we already have by hash.
        let hashValue = self.hash(url: url)
        if hashValue.count == 64, let localBlossomURL = blossomFile(forHash: hashValue, extensionHint: url.pathExtension) {
            return localBlossomURL
        }

        // 3. Try the general cache
        let path = cachePath(for: url)
        if FileManager.default.fileExists(atPath: path.path) {
            return path
        }

        return nil
    }

    private func blossomFile(named filename: String) -> URL? {
        guard !filename.isEmpty, filename != ".", filename != ".." else { return nil }
        let fileURL = blossomDirectory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
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

        return contents.first { $0.lastPathComponent.hasPrefix("\(hash).") }
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

        if let existingInfo = playableURLs[localURL], FileManager.default.fileExists(atPath: existingInfo.path) {
            return existingInfo
        }

        // Create a temp symlink with the resolved extension
        let tempDir = FileManager.default.temporaryDirectory
        let symlinkName = localURL.lastPathComponent + "." + resolvedExt
        let symlinkURL = tempDir.appendingPathComponent(symlinkName)

        do {
            // Remove existing if any
            if FileManager.default.fileExists(atPath: symlinkURL.path) {
                try FileManager.default.removeItem(at: symlinkURL)
            }
            try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: localURL)
            playableURLs[localURL] = symlinkURL
            #if DEBUG
            print("MediaCacheService: Created playable symlink at \(symlinkURL.path)")
            #endif
            return symlinkURL
        } catch {
            #if DEBUG
            print("MediaCacheService: Failed to create symlink: \(error)")
            #endif
            return localURL // Fallback to original
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

    func fetchData(url: URL) async -> Data? {
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
        if let cachedData = try? Data(contentsOf: cacheDirectory.appendingPathComponent(filename)) {
            return cachedData
        }

        return await withCheckedContinuation { continuation in
            downloadLock.lock()
            if var waiters = inFlightDownloads[filename] {
                waiters.append(continuation)
                inFlightDownloads[filename] = waiters
                downloadLock.unlock()
            } else {
                inFlightDownloads[filename] = [continuation]
                downloadLock.unlock()

                #if DEBUG
                print("MediaCacheService: Starting download for \(filename) (URL: \(url.absoluteString))")
                #endif
                // Start the actual download
                URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
                    self?.downloadLock.lock()
                    let waiters = self?.inFlightDownloads[filename] ?? []
                    self?.inFlightDownloads.removeValue(forKey: filename)
                    self?.downloadLock.unlock()

                    if let data = data, let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                        self?.saveToCache(url: url, data: data)
                        for waiter in waiters {
                            waiter.resume(returning: data)
                        }
                    } else {
                        for waiter in waiters {
                            waiter.resume(returning: nil)
                        }
                    }
                }.resume()
            }
        }
    }

    // MARK: - Video Thumbnails

    /// Returns a thumbnail synchronously if we have one in memory or on disk. Cheap; safe
    /// to call from view init or onAppear before async work kicks off.
    func cachedThumbnail(for url: URL) -> PlatformImage? {
        let key = hash(url: url)
        thumbnailCacheLock.lock()
        if let image = thumbnailMemoryCache[key] {
            thumbnailCacheLock.unlock()
            return image
        }
        thumbnailCacheLock.unlock()

        let diskPath = thumbnailDiskPath(for: key)
        guard FileManager.default.fileExists(atPath: diskPath.path),
              let data = try? Data(contentsOf: diskPath),
              let image = PlatformImage(data: data) else {
            return nil
        }

        thumbnailCacheLock.lock()
        thumbnailMemoryCache[key] = image
        thumbnailCacheLock.unlock()
        return image
    }

    /// Generates (or fetches from cache) a thumbnail for the given video URL.
    /// Surefire pipeline:
    /// 1. Check memory + disk caches.
    /// 2. Ensure a local file exists (download remote if necessary).
    /// 3. Build a properly-extensioned local file URL so AVFoundation accepts the container.
    /// 4. Try several time points with loose tolerance; first success wins.
    /// 5. Persist to memory + disk so subsequent renders are instant.
    func generateThumbnail(for url: URL, mimeType: String? = nil) async -> PlatformImage? {
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
                await self.runThumbnailJob(url: url, key: key, mimeType: mimeType, leader: continuation)
            }
        }
    }

    private func runThumbnailJob(url: URL, key: String, mimeType: String?, leader: CheckedContinuation<PlatformImage?, Never>) async {
        // 1. Ensure the file is on disk. For remote URLs that aren't cached, pull them down.
        if internalLocalFileURL(for: url) == nil, !isLocalURL(url) {
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
            thumbnailCacheLock.withLock {
                thumbnailMemoryCache[key] = image
            }
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
        // Prefer a local file (Blossom or cache) over hitting HTTPS. AVAssetImageGenerator
        // is far more reliable on a real file than on a remote URL — especially with self-signed certs.
        let playableURL: URL = {
            if let prepared = self.preparePlayableURL(for: url, extensionHint: mimeType) {
                return prepared
            }
            if let local = self.internalLocalFileURL(for: url) {
                return local
            }
            return url
        }()

        #if DEBUG
        print("MediaCacheService: renderThumbnail url=\(url.absoluteString) playable=\(playableURL.absoluteString) isFile=\(playableURL.isFileURL)")
        #endif

        let asset = AVURLAsset(url: playableURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])

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
                print("MediaCacheService: thumb attempt at \(time.seconds)s failed for \(url.lastPathComponent): \(error.localizedDescription)")
                #endif
                continue
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

    private func makeOneOffSymlink(for localURL: URL, extension ext: String) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let symlinkURL = tempDir.appendingPathComponent("thumb_\(UUID().uuidString).\(ext)")
        do {
            try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: localURL)
            return symlinkURL
        } catch {
            return nil
        }
    }

    private func thumbnailDiskPath(for key: String) -> URL {
        return thumbnailDirectory.appendingPathComponent("\(key).jpg")
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

    func getSource(for url: URL) -> MediaSource {
        if isLocalURL(url) {
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
        let last = url.lastPathComponent
        // Check if last component is a 64-char hash, possibly with an extension
        let pattern = #"(^|/)([a-f0-9]{64})(\.[a-z0-9]+)?$"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let ns = last as NSString
            if let match = regex.firstMatch(in: last, options: [], range: NSRange(location: 0, length: ns.length)) {
                // Return just the hash part
                return ns.substring(with: match.range(at: 2)).lowercased()
            }
        }

        let inputData = Data(url.absoluteString.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Clears the media cache directory while preserving Blossom data
    func clearCache() {
        do {
            let cacheContents = try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
            var deletedCount = 0
            for fileURL in cacheContents {
                // Skip the thumbnails directory — we handle it separately so it stays initialized
                if fileURL.lastPathComponent == "thumbnails" { continue }
                try FileManager.default.removeItem(at: fileURL)
                deletedCount += 1
            }
            if let thumbContents = try? FileManager.default.contentsOfDirectory(at: thumbnailDirectory, includingPropertiesForKeys: nil) {
                for fileURL in thumbContents {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
            thumbnailCacheLock.lock()
            thumbnailMemoryCache.removeAll()
            thumbnailCacheLock.unlock()
            #if DEBUG
            print("MediaCacheService: Cleared \(deletedCount) cached files + thumbnails (Blossom data preserved)")
            #endif
        } catch {
            #if DEBUG
            print("MediaCacheService: Failed to clear cache: \(error.localizedDescription)")
            #endif
        }
    }


    enum MediaSource: String {
        case blossom = "Local"
        case cached = "Cached"
        case remote = "Remote"

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
