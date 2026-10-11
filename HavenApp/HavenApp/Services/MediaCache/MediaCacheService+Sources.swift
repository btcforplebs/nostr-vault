import Foundation
import SwiftUI
import CryptoKit
import AVFoundation
import CoreMedia
import Combine

extension MediaCacheService {
    func updateLocalHost(_ host: String) {
        hostLock.lock()
        defer { hostLock.unlock() }
        self.localHost = host.lowercased()
        #if DEBUG
        print("MediaCacheService: Updated local host to \(self.localHost)")
        #endif
    }

    func updateBlossomDirectory(_ directory: URL) {
        blossomLock.lock()
        defer { blossomLock.unlock() }
        self._blossomDirectory = directory
        #if DEBUG
        print("MediaCacheService: Updated blossom directory to \(directory.path)")
        #endif
    }

    func isLocalURL(_ url: URL) -> Bool {
        hostLock.lock()
        let sanitized = self.localHost
        hostLock.unlock()

        let host = url.host?.lowercased() ?? ""

        // Match against localhost, 127.0.0.1
        if host == "localhost" || host == "127.0.0.1" {
            return true
        }

        if sanitized.isEmpty { return false }

        // Split by colon to ignore port for comparison
        let sanitizedHost = sanitized.split(separator: ":").first.map(String.init) ?? sanitized

        return host == sanitizedHost || host.hasSuffix("." + sanitizedHost)
    }

    /// Where this file lives as far as the phone is concerned. A file stored
    /// in the vault counts as on the phone even when it is shown through a
    /// Blossom server's URL — the gallery promotes items to a mirror URL.
    func getSource(for url: URL) -> MediaSource {
        if isLocalURL(url) {
            return .blossom
        } else if let hash = Self.blossomHash(in: url), isInLocalBlossom(hash: hash) {
            return .blossom
        } else if isCached(url: url) {
            return .cached
        } else {
            return .remote
        }
    }

    func hash(url: URL) -> String {
        // Optimization: If the URL contains a 64-char Blossom hash, use it directly as the cache key.
        // This aligns with how the Go relay stores files and allows different URLs for the same
        // content (e.g. extensioned vs non-extensioned) to share the cache.
        if let blobHash = Self.blossomHash(in: url) {
            return blobHash
        }

        let inputData = Data(url.absoluteString.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }

    enum MediaSource: String {
        case blossom = "On phone"
        case cached = "Temporary copy"
        case remote = "Link only"

        var isLocal: Bool {
            return self == .blossom
        }

        var color: Color {
            switch self {
            case .blossom: return .green
            case .cached: return .blue
            case .remote: return .orange
            }
        }

        var icon: String {
            switch self {
            case .blossom: return "server.rack"
            case .cached: return "archivebox.fill"
            case .remote: return "globe"
            }
        }
    }
}
