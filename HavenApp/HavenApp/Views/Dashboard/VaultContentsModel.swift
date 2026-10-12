import SwiftUI

/// Loads the dashboard's "In your vault" section: event counts from the
/// vault's relays, the media files the gallery lists, and the media cache.
@MainActor
final class VaultContentsModel: ObservableObject {
    /// The media files, by type: the files the Vault tab's media grid lists.
    struct Media: Equatable {
        struct Bucket: Identifiable, Equatable {
            let title: String
            let icon: String
            var count = 0
            var size: Int64 = 0
            var id: String { title }
        }
        let buckets: [Bucket]
        var count: Int { buckets.reduce(0) { $0 + $1.count } }
        var size: Int64 { buckets.reduce(0) { $0 + $1.size } }
    }

    @Published private(set) var contents: VaultContents?
    @Published private(set) var isCounting = false
    /// The last count did not get an answer from every relay.
    @Published private(set) var countFailed = false
    @Published private(set) var media: Media?
    @Published private(set) var cache: StatsService.CacheBreakdown?

    func load(owner: String, relayManager: RelayProcessManager, configService: ConfigService, statsService: StatsService) async {
        async let files: Void = loadFiles(relayManager: relayManager, configService: configService, statsService: statsService)
        if relayManager.isRunning && !owner.isEmpty {
            isCounting = true
            let fresh = await Self.count(owner: owner, port: configService.config.relayPort)
            // A partial answer would undercount; keep what is shown.
            if let fresh { contents = fresh }
            countFailed = fresh == nil
            isCounting = false
        }
        await files
    }

    func loadFiles(relayManager: RelayProcessManager, configService: ConfigService, statsService: StatsService) async {
        let relayDir = configService.relayDataDir
        let blossomDir = relayDir.appendingPathComponent(configService.config.blossomPath)
        let (media, cache) = await Task.detached(priority: .userInitiated) {
            (Self.scanMedia(in: blossomDir, relayManager: relayManager),
             statsService.calculateCacheBreakdown(relayDir: relayDir))
        }.value
        self.media = media
        self.cache = cache
    }

    // MARK: Media

    /// The same files the media grid lists (`MediaGalleryView.loadLocalMedia`):
    /// everything in the Blossom folder but hidden files and the lock file,
    /// typed by their bytes.
    nonisolated private static func scanMedia(in dir: URL, relayManager: RelayProcessManager) -> Media {
        var images = Media.Bucket(title: "Images", icon: "photo.fill")
        var videos = Media.Bucket(title: "Videos", icon: "video.fill")
        var audio = Media.Bucket(title: "Audio", icon: "waveform")
        var other = Media.Bucket(title: "Other", icon: "doc.fill")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])) ?? []
        for file in files {
            let name = file.lastPathComponent
            if name.hasPrefix(".") || name == "LOCK" { continue }
            let size = Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
            let mime = relayManager.resolveMime(claim: nil, proof: relayManager.detectMimeFromBytes(for: file))
            if mime.hasPrefix("image/") { images.count += 1; images.size += size }
            else if mime.hasPrefix("video/") { videos.count += 1; videos.size += size }
            else if mime.hasPrefix("audio/") { audio.count += 1; audio.size += size }
            else { other.count += 1; other.size += size }
        }
        return Media(buckets: [images, videos, audio, other])
    }

    // MARK: Counting

    /// The vault's relays. The feed cache is left out: it holds other
    /// people's notes for the feed, and does not answer COUNT.
    private static func relayURLs(port: Int) -> [URL] {
        #if os(macOS)
        let base = "ws://127.0.0.1:\(port)"
        #else
        let base = "wss://127.0.0.1:\(port)"
        #endif
        guard let url = URL(string: base) else { return [] }
        return [url, url.appendingPathComponent("inbox"), url.appendingPathComponent("private"), url.appendingPathComponent("chat")]
    }

    /// Every count the section shows, summed over the vault's relays. Nil
    /// unless every relay answered every question.
    private static func count(owner: String, port: Int) async -> VaultContents? {
        var filters: [String: [String: Any]] = ["total": [:]]
        for kind in VaultContents.countedKinds {
            filters["k\(kind)"] = ["kinds": [kind]]
        }
        for group in VaultContents.groups where group.countsYours {
            filters["y-\(group.id)"] = ["kinds": group.kinds, "authors": [owner]]
        }
        let urls = relayURLs(port: port)
        guard !urls.isEmpty else { return nil }

        var sums: [String: Int] = [:]
        var complete = true
        await withTaskGroup(of: [String: Int]?.self) { group in
            for url in urls {
                group.addTask { await RelayCounter.count(filters, at: url) }
            }
            for await answer in group {
                guard let answer else { complete = false; continue }
                for (key, value) in answer { sums[key, default: 0] += value }
            }
        }
        guard complete else { return nil }

        var byKind: [Int: Int] = [:]
        var yours: [String: Int] = [:]
        for (key, value) in sums {
            if key.hasPrefix("k"), let kind = Int(key.dropFirst()) { byKind[kind] = value }
            if key.hasPrefix("y-") { yours[String(key.dropFirst(2))] = value }
        }
        return VaultContents(total: sums["total"] ?? 0, byKind: byKind, yours: yours)
    }
}
