import Foundation
import Combine

extension DMService {
    /// Reads this account's DM cache off the main thread, then hands it to
    /// main. Until then saves and gift wraps wait (`cacheLoaded`). The read
    /// queues behind any save still pending, so it always sees the newest file.
    func loadConversations() {
        let fileURL = cacheFileURL()
        let legacyURL = legacyCacheFileURL()
        let unreadableURL = unreadableFileURL()
        cacheLoadGeneration &+= 1
        let load = cacheLoadGeneration
        cacheLoaded = false
        pendingNIP04.removeAll()

        cacheWriter.flushThen { [weak self] in
            // Legacy migration: the old shared cache contained messages from ALL accounts.
            // Instead of moving the entire file (which mixes accounts), delete it and let
            // each account re-fetch its own messages from relays on next connect.
            if !FileManager.default.fileExists(atPath: fileURL.path),
               FileManager.default.fileExists(atPath: legacyURL.path) {
                try? FileManager.default.removeItem(at: legacyURL)
            }

            var unreadable: [String] = []
            if let data = try? Data(contentsOf: unreadableURL),
               let ids = try? JSONDecoder().decode([String].self, from: data) {
                unreadable = ids
            }

            var loaded: [DMConversation] = []
            if let data = try? Data(contentsOf: fileURL) {
                // A cache written before PrivateFile is left out of backups now;
                // its file protection follows on the next save.
                PrivateFile.excludeFromBackup(fileURL)
                loaded = DMCacheFile.decode(data) ?? []
            }

            Task { @MainActor [weak self] in
                self?.applyLoadedCache(loaded, unreadable: unreadable, load: load)
            }
        }
    }

    /// On main: the cache joins whatever arrived while it was read.
    private func applyLoadedCache(_ loaded: [DMConversation], unreadable: [String], load: UInt64) {
        // A newer load (an account switch) owns `conversations` now.
        guard load == cacheLoadGeneration else { return }

        unreadableGiftWrapIds.formUnion(unreadable)
        seenGiftWrapIds.formUnion(unreadableGiftWrapIds)

        let arrived = conversations
        conversations = DMCacheFile.merge(loaded: loaded, live: arrived)

        // Seed seenGiftWrapIds from cached messages to prevent duplicates on reconnect
        var known = Set<String>()
        for conversation in conversations {
            for message in conversation.messages {
                known.insert(message.id)
            }
        }
        seenGiftWrapIds.formUnion(known)
        cacheLoaded = true

        if !arrived.isEmpty { sortConversations() }
        if cacheSaveWanted || !arrived.isEmpty {
            cacheSaveWanted = false
            saveConversations()
            saveUnreadableGiftWrapIds()
        }
        resumeGiftWrapsAfterCacheLoad(known: known.union(unreadableGiftWrapIds))
        let heldNIP04 = pendingNIP04
        pendingNIP04.removeAll()
        for event in heldNIP04 { handleIncomingNIP04(event) }
    }

    func saveUnreadableGiftWrapIds() {
        guard cacheLoaded else { cacheSaveWanted = true; return }
        let ids = Array(unreadableGiftWrapIds)
        cacheWriter.schedule(unreadableFileURL()) { try JSONEncoder().encode(ids) }
    }

    /// Beside the conversation cache, same per-account suffix.
    private func unreadableFileURL() -> URL {
        let cache = cacheFileURL()
        let name = cache.lastPathComponent.replacingOccurrences(of: "dm_cache", with: "dm_unreadable")
        return cache.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// Called for every message, read and send. Takes a snapshot (a copy on
    /// write, nothing is encoded here) and leaves encoding and the write to
    /// `cacheWriter`, which coalesces a burst into one write per file.
    func saveConversations() {
        // The file holds history not in memory yet; writing now would cut it.
        guard cacheLoaded else { cacheSaveWanted = true; return }
        let snapshot = conversations
        cacheWriter.schedule(cacheFileURL()) { try DMCacheFile.encode(snapshot) }
    }

    private func cacheFileURL(forPubkey pubkey: String? = nil) -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Haven")
        }
        // The writer creates the folder; this runs on main for every save.
        let havenDir = appSupport.appendingPathComponent("Haven", isDirectory: true)
        let key = pubkey ?? loadedAccountPubkey
        let suffix = key.isEmpty ? "owner" : String(key.prefix(16))
        return havenDir.appendingPathComponent("dm_cache_\(suffix).json")
    }

    private func legacyCacheFileURL() -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Haven")
        }
        let havenDir = appSupport.appendingPathComponent("Haven", isDirectory: true)
        return havenDir.appendingPathComponent("dm_cache.json")
    }
}
