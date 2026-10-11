import SwiftUI
import AVKit
import AVFoundation

// MARK: - VideoPlayerCache

/// LRU storage for the app's live AVPlayers. Construction, MIME resolution,
/// failure recovery, looping, and audio policy all live in
/// `VideoPlaybackService` — this class only stores and evicts.
class VideoPlayerCache: ObservableObject {
    static let shared = VideoPlayerCache()
    private var cache: [URL: AVPlayer] = [:]
    private var accessOrder: [URL] = []
    private let limit = 3
    private let lock = NSLock()

    /// Tracks which video URL is currently being viewed full-screen so we don't pause it when the feed cell goes off-screen
    @Published var activeFullScreenURL: URL? = nil

    /// Evicts all cached players (called on memory pressure).
    func evictAll() {
        lock.lock()
        let entries = cache
        cache.removeAll()
        accessOrder.removeAll()
        lock.unlock()

        for (url, player) in entries {
            player.pause()
            VideoPlaybackService.shared.invalidateLadder(for: url)
        }
    }

    /// Returns the cached player (refreshing its LRU position), or nil.
    func storedPlayer(for url: URL) -> AVPlayer? {
        lock.lock()
        defer { lock.unlock() }
        guard let player = cache[url] else { return nil }
        if let index = accessOrder.firstIndex(of: url) {
            accessOrder.remove(at: index)
        }
        accessOrder.append(url)
        return player
    }

    /// Stores a newly built player, evicting the LRU entry when over the limit —
    /// but never the full-screen/PiP video, which must keep playing while feed
    /// cells create players underneath it.
    func store(_ player: AVPlayer, for url: URL) {
        var evicted: (URL, AVPlayer)?

        lock.lock()
        cache[url] = player
        accessOrder.removeAll { $0 == url }
        accessOrder.append(url)
        if cache.count > limit,
           let oldest = accessOrder.first(where: { $0 != activeFullScreenURL && $0 != url }) {
            accessOrder.removeAll { $0 == oldest }
            if let oldPlayer = cache.removeValue(forKey: oldest) {
                evicted = (oldest, oldPlayer)
            }
        }
        lock.unlock()

        if let (oldURL, oldPlayer) = evicted {
            oldPlayer.pause()
            VideoPlaybackService.shared.invalidateLadder(for: oldURL)
        }
    }

    /// Removes one player (its ladder is invalidated by the service).
    func removePlayer(for url: URL) {
        lock.lock()
        let player = cache.removeValue(forKey: url)
        accessOrder.removeAll { $0 == url }
        lock.unlock()
        player?.pause()
    }
}
