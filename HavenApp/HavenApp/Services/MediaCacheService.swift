import Foundation
import SwiftUI
import CryptoKit
import AVFoundation
import CoreMedia

class MediaCacheService: ObservableObject, @unchecked Sendable {
    static let shared = MediaCacheService()

    // Cache for temporary playback URLs (symlinks)
    private var playableURLs: [URL: URL] = [:]
    private let playableLock = NSLock()

    private let cacheDirectory: URL
    private var inFlightDownloads: [String: [CheckedContinuation<Data?, Never>]] = [:]
    private let downloadLock = NSLock()

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

    private let blossomDirectory: URL

    // Thread-safe copy of local host for non-isolated access
    private var localHost: String = ""
    private let hostLock = NSLock()


    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let havenAppSupport = appSupport.appendingPathComponent("Haven", isDirectory: true)
        let dbDir = havenAppSupport.appendingPathComponent("haven_database", isDirectory: true)
        self.cacheDirectory = dbDir.appendingPathComponent("cache")
        self.blossomDirectory = dbDir.appendingPathComponent("blossom")

        createCacheDirectory()
    }

    private func createCacheDirectory() {
        if !FileManager.default.fileExists(atPath: cacheDirectory.path) {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
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
        // 1. Try to find if it's a local Blossom file we already have
        let hashValue = self.hash(url: url)
        if hashValue.count == 64 {
            let blossomURL = blossomDirectory.appendingPathComponent(hashValue)
            if FileManager.default.fileExists(atPath: blossomURL.path) {
                return blossomURL
            }
        }

        // 2. Try the general cache
        let path = cachePath(for: url)
        if FileManager.default.fileExists(atPath: path.path) {
            return path
        }

        return nil
    }

    /// Ensures the local file has a proper extension for AVFoundation playback.
    /// If the file is extensionless (Blossom), creates a temporary symlink with .mp4 extension.
    func preparePlayableURL(for url: URL) -> URL? {
        guard let localURL = internalLocalFileURL(for: url) else { return nil }

        // If it already has an extension, we're good
        if !localURL.pathExtension.isEmpty {
            return localURL
        }

        playableLock.lock()
        defer { playableLock.unlock() }

        if let existingInfo = playableURLs[localURL], FileManager.default.fileExists(atPath: existingInfo.path) {
            return existingInfo
        }

        // Create a temp symlink with .mp4 extension
        let tempDir = FileManager.default.temporaryDirectory
        let symlinkName = localURL.lastPathComponent + ".mp4"
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

    func generateThumbnail(for url: URL) async -> PlatformImage? {
        // Resolve local file first to see if we can just use it directly
        // This is important for "Local" (Blossom) files where preparePlayableURL might try to make a symlink
        let resolvedURL = self.localFileURL(for: url)

        return await withCheckedContinuation { continuation in
            let operation = BlockOperation {
                // 2. Prepare playable URL (handling symlinks if needed)
                let playableURL = self.preparePlayableURL(for: url) ?? resolvedURL ?? url

                // 3. Generate
                let asset = AVAsset(url: playableURL)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 400, height: 400)

                let time = CMTime(seconds: 0.1, preferredTimescale: 60)

                do {
                     let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
                     let image = PlatformImage(cgImage: cgImage, size: .zero)
                     continuation.resume(returning: image)
                } catch {
                     #if DEBUG
                     print("MediaCacheService: Thumbnail generation failed for \(url.lastPathComponent): \(error)")
                     #endif
                     continuation.resume(returning: nil)
                }
            }

            self.thumbnailQueue.addOperation(operation)
        }
    }

    func updateLocalHost(_ host: String) {
        hostLock.lock()
        defer { hostLock.unlock() }
        self.localHost = host.lowercased()
        #if DEBUG
        print("MediaCacheService: Updated local host to \(self.localHost)")
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
                try FileManager.default.removeItem(at: fileURL)
                deletedCount += 1
            }
            #if DEBUG
            print("MediaCacheService: Cleared \(deletedCount) cached files (Blossom data preserved)")
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
