import Foundation
import Combine

extension DMService {
    func loadConversations() {
        let fileURL = cacheFileURL()

        // Legacy migration: the old shared cache contained messages from ALL accounts.
        // Instead of moving the entire file (which mixes accounts), delete it and let
        // each account re-fetch its own messages from relays on next connect.
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let legacy = legacyCacheFileURL()
            if FileManager.default.fileExists(atPath: legacy.path) {
                try? FileManager.default.removeItem(at: legacy)
            }
        }

        if let data = try? Data(contentsOf: unreadableFileURL()),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            unreadableGiftWrapIds = Set(ids)
            seenGiftWrapIds.formUnion(unreadableGiftWrapIds)
        }

        guard let data = try? Data(contentsOf: fileURL) else { return }
        conversations = (try? JSONDecoder().decode([DMConversation].self, from: data)) ?? []

        // Seed seenGiftWrapIds from cached messages to prevent duplicates on reconnect
        for conversation in conversations {
            for message in conversation.messages {
                seenGiftWrapIds.insert(message.id)
            }
        }
    }

    func saveUnreadableGiftWrapIds() {
        guard let data = try? JSONEncoder().encode(Array(unreadableGiftWrapIds)) else { return }
        try? data.write(to: unreadableFileURL())
    }

    /// Beside the conversation cache, same per-account suffix.
    private func unreadableFileURL() -> URL {
        let cache = cacheFileURL()
        let name = cache.lastPathComponent.replacingOccurrences(of: "dm_cache", with: "dm_unreadable")
        return cache.deletingLastPathComponent().appendingPathComponent(name)
    }

    func saveConversations() {
        let fileURL = cacheFileURL()
        guard let data = try? JSONEncoder().encode(conversations) else { return }
        try? data.write(to: fileURL)
    }

    private func cacheFileURL(forPubkey pubkey: String? = nil) -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Haven")
        }
        let havenDir = appSupport.appendingPathComponent("Haven", isDirectory: true)
        try? FileManager.default.createDirectory(at: havenDir, withIntermediateDirectories: true)
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
