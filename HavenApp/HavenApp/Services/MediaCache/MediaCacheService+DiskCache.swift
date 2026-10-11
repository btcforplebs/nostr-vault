import Foundation
import SwiftUI
import CryptoKit
import AVFoundation
import CoreMedia
import Combine

extension MediaCacheService {
    func createCacheDirectory() {
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

    var isDiskCacheDisabled: Bool {
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
}
