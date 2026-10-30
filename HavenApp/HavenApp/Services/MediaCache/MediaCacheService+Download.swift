import Foundation
import SwiftUI
import CryptoKit
import AVFoundation
import CoreMedia
import Combine

extension MediaCacheService {
    /// - Parameter priority: Rank among queued downloads. On-screen media uses
    ///   the default; feed prefetch passes `.low` so it never delays what the
    ///   user is looking at. A later, higher-priority request for the same URL
    ///   promotes the queued transfer.
    func fetchData(url: URL, priority: Operation.QueuePriority = .normal) async -> Data? {
        if BlossomURI.isURI(url) { return await fetchBlossomURI(url, author: nil) }
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
        // Prefetch, the viewer and every other fetchData caller: a `.fips`
        // host is reachable only over the mesh (see `isMeshOnly`).
        if Self.isMeshOnly(url) { return nil }

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
}
