import Foundation
import SwiftUI
import CryptoKit
import AVFoundation
import CoreMedia
import Combine

extension MediaCacheService {
    /// Ensures the local file has a proper extension for AVFoundation playback.
    /// If the file is extensionless (Blossom), creates a temporary symlink with the inferred
    /// extension (from the source URL or `extensionHint`, defaulting to `.mp4`).
    func preparePlayableURL(for url: URL, extensionHint: String? = nil) -> URL? {
        guard let localURL = internalLocalFileURL(for: url) else { return nil }

        let resolvedExt = inferContainerExtension(sourceURL: url, localURL: localURL, mimeHint: extensionHint)

        // If it already has a usable extension, we're good
        if !localURL.pathExtension.isEmpty {
            return localURL
        }

        playableLock.lock()
        defer { playableLock.unlock() }

        // Same-process fast path: a link we made earlier this launch. Verified
        // with lstat semantics — never trust `fileExists` on a symlink here.
        if let existingInfo = playableURLs[localURL],
           case .liveLink(let dest) = PlayableLinks.inspect(existingInfo), dest == localURL.path {
            return existingInfo
        }

        let tempDir = FileManager.default.temporaryDirectory
        let symlinkName = localURL.lastPathComponent + "." + resolvedExt
        let symlinkURL = tempDir.appendingPathComponent(symlinkName)

        do {
            // Replaces a dangling link left behind by a previous app container
            // (every iOS reinstall moves the container but carries tmp/ along)
            // instead of failing with EEXIST on it. See PlayableLinks.
            let outcome = try PlayableLinks.ensureLink(at: symlinkURL, to: localURL)
            playableURLs[localURL] = symlinkURL
            #if DEBUG
            print("MediaCacheService: playable symlink \(outcome) at \(symlinkURL.path)")
            #endif
            if outcome == .replaced {
                Task { @MainActor in
                    RelayProcessManager.shared.addLog("Media: replaced stale playable link \(symlinkName)", level: "INFO")
                }
            }
            return symlinkURL
        } catch {
            #if DEBUG
            print("MediaCacheService: Failed to create symlink: \(error)")
            #endif
            Task { @MainActor in
                RelayProcessManager.shared.addLog("Media: playable link failed for \(symlinkName): \(error.localizedDescription)", level: "WARN")
            }
            // Returning the bare extensionless file would make AVFoundation fail
            // with -11828 "Cannot Open" — let callers fall back to the remote URL.
            return nil
        }
    }

    /// Decides what container extension to use for a symlink. Order of preference:
    /// 1. mimeHint (mime type string OR a plain extension)
    /// 2. source URL pathExtension
    /// 3. local URL pathExtension (when present)
    /// 4. fallback `mp4`
    private func inferContainerExtension(sourceURL: URL, localURL: URL, mimeHint: String?) -> String {
        if let hint = mimeHint?.lowercased(), !hint.isEmpty {
            if hint.contains("webm") { return "webm" }
            if hint.contains("quicktime") || hint.contains("mov") { return "mov" }
            if hint.contains("m4v") { return "m4v" }
            if hint.contains("hevc") || hint.contains("h265") { return "mp4" }
            if hint.contains("mp4") || hint.contains("mpeg") { return "mp4" }
            // If caller passed a bare extension like "mov"
            if hint.count <= 5 && !hint.contains("/") { return hint }
        }
        let srcExt = sourceURL.pathExtension.lowercased()
        if !srcExt.isEmpty { return srcExt }
        let localExt = localURL.pathExtension.lowercased()
        if !localExt.isEmpty { return localExt }
        return "mp4"
    }
}
