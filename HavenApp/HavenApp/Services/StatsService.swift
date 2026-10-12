import Foundation
import Combine

@MainActor
class StatsService: ObservableObject {
    static let shared = StatsService()
    
    @Published var storageSize: Int64 = 0
    @Published var blossomSize: Int64 = 0
    @Published var cacheSize: Int64 = 0
    @Published var thumbnailSize: Int64 = 0
    @Published var loadedEventsCount: Int = UserDefaults.standard.integer(forKey: "haven.stats.eventCount")
    @Published var isUpdatingCount: Bool = false
    
    private var relayManager = RelayProcessManager.shared
    private var cancellables = Set<AnyCancellable>()

    // Tracking for real-time updates
    private var baseDbCount: Int = 0
    private var baseRelayNotesStored: Int = 0

    init() {
        // Establish baseline from persisted count — the delta observer
        // tracks all changes from here forward.
        baseDbCount = loadedEventsCount
        baseRelayNotesStored = relayManager.eventsStored

        // Observe RelayProcessManager for new incoming events (real-time updates)
        relayManager.$eventsStored
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (newNoteCount: Int) in
                guard let self = self else { return }

                // If eventsStored was reset (e.g. after import),
                // realign the baselines so the diff tracking starts fresh.
                if newNoteCount < self.baseRelayNotesStored {
                    self.baseRelayNotesStored = 0
                    self.baseDbCount = self.loadedEventsCount
                }

                // diff is how many new events came in since we last fetched the DB count
                let diff = newNoteCount - self.baseRelayNotesStored
                if diff >= 0 {
                    let newCount = self.baseDbCount + diff
                    self.loadedEventsCount = newCount
                    UserDefaults.standard.set(newCount, forKey: "haven.stats.eventCount")
                }
            }
            .store(in: &cancellables)
    }
    
    func refreshStats() {
        if isUpdatingCount { return }
        self.isUpdatingCount = true

        Task { @MainActor in
            defer { self.isUpdatingCount = false }

            let relayDir = ConfigService.shared.relayDataDir
            let blossomDir = relayDir.appendingPathComponent("blossom")
            let cacheDir = relayDir.appendingPathComponent("cache")
            let thumbDir = relayDir.appendingPathComponent("thumbnails")

            // Perform heavy I/O in a background task
            let (storage, blossom, cache, thumbnails) = await Task.detached(priority: .userInitiated) {
                let s = self.calculateSize(of: relayDir)
                let b = self.calculateSize(of: blossomDir)
                let c = self.calculateSize(of: cacheDir)
                let t = self.calculateSize(of: thumbDir)
                return (s, b, c, t)
            }.value

            self.storageSize = storage
            self.blossomSize = blossom
            self.cacheSize = cache
            self.thumbnailSize = thumbnails
        }
    }
    
    /// Event counts per kind across the vault's relays, plus the total under
    /// key -1. One socket per relay pipelines every COUNT (`RelayCounter`,
    /// which AUTHs as the owner on /private and /chat). Nil unless every
    /// relay answered every COUNT: a partial sum would undercount. Without
    /// the owner's key the total covers the public routes only.
    func fetchCountsByKind() async -> [Int: Int]? {
        let config = ConfigService.shared.config
        #if os(macOS)
        let baseURLString = "ws://127.0.0.1:\(config.relayPort)"
        #else
        let baseURLString = "wss://127.0.0.1:\(config.relayPort)"
        #endif
        guard let baseURL = URL(string: baseURLString) else { return nil }

        // Watch-only: /private and /chat can't be AUTHed, so count the rest.
        let relayURLs = RelayCountSession.countable([
            baseURL,
            baseURL.appendingPathComponent("inbox"),
            baseURL.appendingPathComponent("private"),
            baseURL.appendingPathComponent("chat")
        ], canSignAsOwner: DMService.shared.canSignAsOwner())

        // Common Nostr kinds to query — covers profile, social, media, lists, long-form, zaps, DMs
        let kindsToQuery = [
            0, 1, 3, 4, 5, 6, 7, 8, 9, 16,
            1059, 1063, 1311, 1808,
            9734, 9735,
            10000, 10001, 10002, 10003, 10005, 10006, 10015, 10030,
            30000, 30001, 30002, 30008, 30009, 30023, 30024, 30030, 30078
        ]
        var filters: [String: [String: Any]] = ["-1": [:]]
        for kind in kindsToQuery {
            filters["\(kind)"] = ["kinds": [kind]]
        }

        var results: [Int: Int] = [:]
        var allEndpointsResponded = true
        await withTaskGroup(of: [String: Int]?.self) { group in
            for url in relayURLs {
                group.addTask { await RelayCounter.count(filters, at: url) }
            }
            for await partial in group {
                guard let partial else { allEndpointsResponded = false; continue }
                for (key, count) in partial {
                    if let kind = Int(key) { results[kind, default: 0] += count }
                }
            }
        }

        guard allEndpointsResponded else {
            #if DEBUG
            print("StatsService: Not all endpoints answered the kind breakdown — couldn't count")
            #endif
            return nil
        }
        return results
    }

    nonisolated private func calculateSize(of url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            // Skip the blossom directory for the main storage count to avoid double counting if desired?
            // "Storage Used" usually implies *total* used by the app.
            // "Media Storage" is a subset.
            // I'll count total for storage, and specific for media.
            if let attributes = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
               let size = attributes.totalFileAllocatedSize {
                total += Int64(size)
            }
        }
        return total
    }
    
    var formattedStorageSize: String {
        ByteCountFormatter.string(fromByteCount: storageSize, countStyle: .file)
    }
    
    var formattedBlossomSize: String {
        ByteCountFormatter.string(fromByteCount: blossomSize, countStyle: .file)
    }
    
    var formattedCacheSize: String {
        ByteCountFormatter.string(fromByteCount: cacheSize + thumbnailSize, countStyle: .file)
    }

    var formattedThumbnailSize: String {
        ByteCountFormatter.string(fromByteCount: thumbnailSize, countStyle: .file)
    }

    struct CacheBreakdown {
        var imageCount: Int = 0
        var imageSize: Int64 = 0
        var videoCount: Int = 0
        var videoSize: Int64 = 0
        var otherCount: Int = 0
        var otherSize: Int64 = 0
        var thumbnailCount: Int = 0
        var thumbnailSize: Int64 = 0
        var oldestFile: Date?
        var newestFile: Date?
    }

    nonisolated func calculateCacheBreakdown(relayDir: URL) -> CacheBreakdown {
        let cacheDir = relayDir.appendingPathComponent("cache")
        let thumbDir = relayDir.appendingPathComponent("thumbnails")

        var breakdown = CacheBreakdown()
        let fm = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey, .contentModificationDateKey]

        if let contents = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: Array(resourceKeys)) {
            for fileURL in contents {
                guard let vals = try? fileURL.resourceValues(forKeys: resourceKeys) else { continue }
                if vals.isDirectory == true { continue }
                let size = Int64(vals.totalFileAllocatedSize ?? 0)
                if let modified = vals.contentModificationDate {
                    if breakdown.oldestFile == nil || modified < breakdown.oldestFile! { breakdown.oldestFile = modified }
                    if breakdown.newestFile == nil || modified > breakdown.newestFile! { breakdown.newestFile = modified }
                }
                switch Self.detectFileType(at: fileURL) {
                case .image:
                    breakdown.imageCount += 1
                    breakdown.imageSize += size
                case .video:
                    breakdown.videoCount += 1
                    breakdown.videoSize += size
                case .other:
                    breakdown.otherCount += 1
                    breakdown.otherSize += size
                }
            }
        }

        if let thumbContents = try? fm.contentsOfDirectory(at: thumbDir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .contentModificationDateKey]) {
            for fileURL in thumbContents {
                guard let vals = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .contentModificationDateKey]) else { continue }
                let size = Int64(vals.totalFileAllocatedSize ?? 0)
                if let modified = vals.contentModificationDate {
                    if breakdown.oldestFile == nil || modified < breakdown.oldestFile! { breakdown.oldestFile = modified }
                    if breakdown.newestFile == nil || modified > breakdown.newestFile! { breakdown.newestFile = modified }
                }
                breakdown.thumbnailCount += 1
                breakdown.thumbnailSize += size
            }
        }

        return breakdown
    }

    private enum CachedFileType { case image, video, other }

    nonisolated private static func detectFileType(at url: URL) -> CachedFileType {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .other }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 12), header.count >= 3 else { return .other }

        // JPEG: FF D8 FF
        if header[0] == 0xFF && header[1] == 0xD8 && header[2] == 0xFF { return .image }
        // PNG: 89 50 4E 47
        if header.count >= 4 && header[0] == 0x89 && header[1] == 0x50 && header[2] == 0x4E && header[3] == 0x47 { return .image }
        // GIF: 47 49 46 38
        if header.count >= 4 && header[0] == 0x47 && header[1] == 0x49 && header[2] == 0x46 && header[3] == 0x38 { return .image }
        // WebP: RIFF....WEBP
        if header.count >= 12 && header[0] == 0x52 && header[1] == 0x49 && header[2] == 0x46 && header[3] == 0x46
            && header[8] == 0x57 && header[9] == 0x45 && header[10] == 0x42 && header[11] == 0x50 { return .image }
        // MP4/MOV: ftyp at offset 4
        if header.count >= 8 && header[4] == 0x66 && header[5] == 0x74 && header[6] == 0x79 && header[7] == 0x70 { return .video }
        // WebM/MKV: 1A 45 DF A3
        if header.count >= 4 && header[0] == 0x1A && header[1] == 0x45 && header[2] == 0xDF && header[3] == 0xA3 { return .video }

        return .other
    }

    func fetchBlobList(for hexPubkey: String) async -> [BlobDescriptor] {
        let config = ConfigService.shared.config
        #if os(macOS)
        let baseURLString = "http://127.0.0.1:\(config.relayPort)"
        let session = URLSession.shared
        #else
        let baseURLString = "https://127.0.0.1:\(config.relayPort)"
        let session = URLSession(configuration: .default, delegate: LocalhostTrustDelegate(), delegateQueue: nil)
        #endif
        guard let url = URL(string: "\(baseURLString)/list/\(hexPubkey)") else { return [] }
        guard let (data, _) = try? await session.data(from: url) else { return [] }
        return (try? JSONDecoder().decode([BlobDescriptor].self, from: data)) ?? []
    }
}
