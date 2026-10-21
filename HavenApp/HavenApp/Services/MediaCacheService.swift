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
    var playableURLs: [URL: URL] = [:]
    let playableLock = NSLock()

    let cacheDirectory: URL
    let thumbnailDirectory: URL
    var inFlightDownloads: [String: [CheckedContinuation<Data?, Never>]] = [:]
    /// Queued-or-running download operations by cache filename, so a view can
    /// re-rank a transfer it no longer (or now) needs. Guarded by downloadLock.
    var downloadOperations: [String: Operation] = [:]
    let downloadLock = NSLock()

    // In-memory decoded image cache (NSCache auto-evicts under memory pressure)
    let imageCache: NSCache<NSURL, PlatformImage> = {
        let cache = NSCache<NSURL, PlatformImage>()
        cache.countLimit = 150
        // Feed photos decode at up to 800 px (~2 MB each), so 40 MB held only
        // ~20 and scrolling back re-decoded from disk with a spinner.
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    // In-memory thumbnail cache (keyed by url hash). Disk cache backs this.
    // NSCache auto-evicts under memory pressure and enforces count/cost limits.
    let thumbnailMemoryCache: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.countLimit = 150
        cache.totalCostLimit = 30 * 1024 * 1024 // 30 MB
        return cache
    }()
    private let thumbnailCacheLock = NSLock()
    // Per-url in-flight thumbnail jobs to coalesce parallel requests
    var inFlightThumbnails: [String: [CheckedContinuation<PlatformImage?, Never>]] = [:]

    let downloadQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MediaCacheDownloadQueue"
        queue.maxConcurrentOperationCount = 4
        return queue
    }()

    /// Videos download on their own lane: a video holds its slot for the whole
    /// file, and on the shared queue two or three of them starved every photo.
    let videoDownloadQueue: OperationQueue = {
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

    var _blossomDirectory: URL
    let blossomLock = NSLock()

    var blossomDirectory: URL {
        blossomLock.lock()
        defer { blossomLock.unlock() }
        return _blossomDirectory
    }

    // Thread-safe copy of local host for non-isolated access
    var localHost: String = ""
    let hostLock = NSLock()

    // User-flagged 404 URLs (persisted to UserDefaults). Filtering uses this set to
    // route flagged items to the dedicated 404 bucket in the viewer.
    // Keyed by URL with the date it was flagged: entries expire after
    // notFoundMaxAge and the map is capped, so a media-heavy feed can't
    // grow UserDefaults (deserialized in full on every launch) forever.
    var notFoundURLs: [String: Date] = [:]
    let notFoundLock = NSLock()
    let notFoundDefaultsKey = "MediaCacheService.notFoundURLs"
    private let notFoundMaxAge: TimeInterval = 7 * 24 * 3600
    let notFoundMaxCount = 500

    /// Mirror of `disableMediaCache`, readable from download threads.
    var diskCacheDisabled = false
    let diskCacheLock = NSLock()
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

    // MARK: - Hash-Named File Integrity

    /// Verification verdicts keyed by path+size+mtime — a rewritten file re-verifies.
    var integrityVerdicts: [String: Bool] = [:]
    let integrityLock = NSLock()
    /// Files above this size are trusted without hashing; the failed-player remote
    /// fallback in VideoPlayerCache still heals them if they turn out corrupt.
    static let integrityMaxHashBytes: UInt64 = 64 * 1024 * 1024
}
