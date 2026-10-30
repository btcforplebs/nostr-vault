import Foundation
import SwiftUI
import CryptoKit
import AVFoundation
import CoreMedia
import Combine

extension MediaCacheService {
    // MARK: - Video Thumbnails

    /// Returns a thumbnail synchronously if we have one in memory or on disk. Cheap; safe
    /// to call from view init or onAppear before async work kicks off.
    func cachedThumbnail(for url: URL) -> PlatformImage? {
        let key = hash(url: url)
        let nsKey = key as NSString
        if let image = thumbnailMemoryCache.object(forKey: nsKey) {
            return image
        }

        let diskPath = thumbnailDiskPath(for: key)
        guard FileManager.default.fileExists(atPath: diskPath.path),
              let data = try? Data(contentsOf: diskPath),
              let image = PlatformImage(data: data) else {
            return nil
        }

        thumbnailMemoryCache.setObject(image, forKey: nsKey, cost: Self.decodedCost(of: image))
        return image
    }

    /// Generates (or fetches from cache) a thumbnail for the given video URL.
    /// Surefire pipeline:
    /// 1. Check memory + disk caches.
    /// 2. Ensure a local file exists (download remote if necessary).
    /// 3. Build a properly-extensioned local file URL so AVFoundation accepts the container.
    /// 4. Try several time points with loose tolerance; first success wins.
    /// 5. Persist to memory + disk so subsequent renders are instant.
    /// - Parameter allowFullDownload: When `true` (default) a remote video that
    ///   isn't cached is downloaded in full before the frame is extracted. Pass
    ///   `false` from condensed/thumbnail contexts so a tiny preview never pulls an
    ///   entire video over the network — the frame is then extracted directly from
    ///   the remote asset via byte-range requests instead.
    func generateThumbnail(for url: URL, mimeType: String? = nil, allowFullDownload: Bool = true) async -> PlatformImage? {
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
                await self.runThumbnailJob(url: url, key: key, mimeType: mimeType, allowFullDownload: allowFullDownload, leader: continuation)
            }
        }
    }

    private func runThumbnailJob(url: URL, key: String, mimeType: String?, allowFullDownload: Bool, leader: CheckedContinuation<PlatformImage?, Never>) async {
        // 1. Ensure the file is on disk. For remote URLs that aren't cached, pull them
        // down — but only when the caller permits a full download. Condensed/thumbnail
        // contexts pass allowFullDownload:false so generating a small preview never
        // autoloads an entire video; renderThumbnail then extracts the frame directly
        // from the remote asset via byte-range requests.
        // A `blossom:` link has no server to range-read: it is read whole.
        if allowFullDownload || BlossomURI.isURI(url), internalLocalFileURL(for: url) == nil, !isLocalURL(url) {
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
            thumbnailMemoryCache.setObject(image, forKey: key as NSString, cost: Self.decodedCost(of: image))
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
        // Walk the same source ladder playback uses (verified local file →
        // remote with known/sniffed MIME → remote container guesses), so a
        // corrupt local copy or a mislabeling server can't kill thumbnails.
        let candidates = VideoPlaybackService.shared.resolveCandidates(for: url, mimeHint: mimeType)
        for candidate in candidates {
            #if DEBUG
            print("MediaCacheService: renderThumbnail url=\(url.absoluteString) trying=\(candidate.label)")
            #endif
            if let image = await extractFrame(from: candidate.assetURL, options: candidate.assetOptions, sourceURL: url) {
                return image
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

    /// Tries several time points against one asset URL; first extractable frame wins.
    private func extractFrame(from playableURL: URL, options: [String: Any] = [:], sourceURL: URL) async -> PlatformImage? {
        var assetOptions: [String: Any] = options
        assetOptions[AVURLAssetPreferPreciseDurationAndTimingKey] = false
        let asset = AVURLAsset(url: playableURL, options: assetOptions)

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
                print("MediaCacheService: thumb attempt at \(time.seconds)s failed for \(sourceURL.lastPathComponent): \(error.localizedDescription)")
                #endif
                continue
            }
        }
        return nil
    }

    /// Gives an extensionless blob an alternate container extension for a
    /// thumbnail retry. Deterministic name (`<blob>.<ext>`) so the link is
    /// reused across launches and swept by PlayableLinks.purgeStale — the old
    /// `thumb_<uuid>` scheme leaked one link per attempt, forever.
    private func makeOneOffSymlink(for localURL: URL, extension ext: String) -> URL? {
        let linkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(localURL.lastPathComponent + "." + ext)
        do {
            try PlayableLinks.ensureLink(at: linkURL, to: localURL)
            return linkURL
        } catch {
            return nil
        }
    }

    private func thumbnailDiskPath(for key: String) -> URL {
        return thumbnailDirectory.appendingPathComponent("\(key).jpg")
    }

    // MARK: - Avatar Thumbnails

    /// Where the small copy of a profile picture lives. Avatars keep only this
    /// copy on disk, not the original (often several MB for a picture drawn
    /// a few dozen points wide). Its own name, so it is never mistaken for
    /// the original or for a video thumbnail of the same URL.
    private func avatarThumbnailPath(for url: URL, maxPixel: Int) -> URL {
        thumbnailDirectory.appendingPathComponent("avatar-\(maxPixel)-\(hash(url: url))")
    }

    func avatarThumbnailData(for url: URL, maxPixel: Int) -> Data? {
        try? Data(contentsOf: avatarThumbnailPath(for: url, maxPixel: maxPixel))
    }

    func hasAvatarThumbnail(for url: URL, maxPixel: Int) -> Bool {
        FileManager.default.fileExists(atPath: avatarThumbnailPath(for: url, maxPixel: maxPixel).path)
    }

    func saveAvatarThumbnail(_ data: Data, for url: URL, maxPixel: Int) {
        guard !isDiskCacheDisabled else { return }
        try? data.write(to: avatarThumbnailPath(for: url, maxPixel: maxPixel), options: .atomic)
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
}
