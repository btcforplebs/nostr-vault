import Foundation
import SwiftUI
import CryptoKit
import AVFoundation
import CoreMedia
import Combine

extension MediaCacheService {
    /// Internal version that resolves file paths even for local relay URLs.
    /// Used for components like AVAsset thumbnail generation which can handle raw files.
    ///
    /// Files named by a Blossom content hash are integrity-checked before being
    /// returned: a truncated/corrupt local copy (e.g. from an interrupted blob
    /// write) would otherwise shadow a perfectly healthy remote URL forever.
    func internalLocalFileURL(for url: URL) -> URL? {
        let blobHash = Self.blossomHash(in: url)

        // 1. Local relay media-tab URLs may point at files in Blossom by their
        // exact filename, not only by a bare sha256 hash. Resolve those directly
        // so AVFoundation does not have to stream through localhost on iOS.
        if isLocalURL(url), let localBlossomURL = blossomFile(named: url.lastPathComponent) {
            if let blobHash {
                return verifiedHashNamedFile(localBlossomURL, expectedHash: blobHash)
            }
            return localBlossomURL
        }

        // 2. Try to find if it's a local Blossom file we already have by hash.
        if let blobHash,
           let localBlossomURL = blossomFile(forHash: blobHash, extensionHint: url.pathExtension),
           let verified = verifiedHashNamedFile(localBlossomURL, expectedHash: blobHash) {
            return verified
        }

        // 3. Try the general cache
        let path = cachePath(for: url)
        if FileManager.default.fileExists(atPath: path.path) {
            // Blossom-hash cache entries are keyed (and named) by the blob's
            // content hash, so they can be verified too. URL-keyed entries can't.
            if let blobHash {
                return verifiedHashNamedFile(path, expectedHash: blobHash)
            }
            return path
        }

        return nil
    }

    /// Extracts a 64-hex Blossom content hash from the URL's last path component, if present.
    static func blossomHash(in url: URL) -> String? {
        let last = url.lastPathComponent
        let pattern = #"^([a-f0-9]{64})(\.[a-z0-9]+)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let ns = last as NSString
        guard let match = regex.firstMatch(in: last, options: [], range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range(at: 1)).lowercased()
    }

    /// Returns `fileURL` only if its content actually hashes to `expectedHash`
    /// (memoized per launch). A mismatching file is discarded — deleted from the
    /// cache, or quarantined with a `.corrupt` suffix in the Blossom store — so
    /// callers fall through to the healthy remote URL and the copy can heal.
    func verifiedHashNamedFile(_ fileURL: URL, expectedHash: String) -> URL? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.resolvingSymlinksInPath().path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return nil }
        if size == 0 {
            discardCorruptFile(fileURL)
            return nil
        }
        if size > Self.integrityMaxHashBytes { return fileURL }

        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(fileURL.path)|\(size)|\(mtime)"
        integrityLock.lock()
        let cached = integrityVerdicts[key]
        integrityLock.unlock()
        if let cached { return cached ? fileURL : nil }

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1 << 20)
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let ok = digest == expectedHash

        integrityLock.lock()
        integrityVerdicts[key] = ok
        integrityLock.unlock()

        if !ok {
            #if DEBUG
            print("MediaCacheService: corrupt local copy of \(expectedHash.prefix(8))… (got \(digest.prefix(8))…), discarding")
            #endif
            Task { @MainActor in
                RelayProcessManager.shared.addLog("MediaCache: local copy of blob \(expectedHash.prefix(8))… is corrupt — using remote copy", level: "WARN")
            }
            discardCorruptFile(fileURL)
            return nil
        }
        return fileURL
    }

    /// Drops the disposable cached copy of a URL (used when a local copy failed
    /// to play so the next fetch re-downloads from the source).
    func discardCachedCopy(for url: URL) {
        let path = cachePath(for: url)
        try? FileManager.default.removeItem(at: path)
    }

    /// Cache entries are disposable and get deleted; Blossom blobs are relay data,
    /// so they're quarantined under a `.corrupt` suffix instead — HEAD /<hash>
    /// stops claiming the blob exists and a later re-mirror can heal it.
    private func discardCorruptFile(_ fileURL: URL) {
        if fileURL.path.hasPrefix(blossomDirectory.path) {
            let quarantined = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: quarantined)
            try? FileManager.default.moveItem(at: fileURL, to: quarantined)
        } else {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    func blossomFile(named filename: String) -> URL? {
        guard !filename.isEmpty, filename != ".", filename != ".." else { return nil }
        let fileURL = blossomDirectory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    /// Returns true if a file with the given SHA256 hash exists in the local blossom directory.
    func isInLocalBlossom(hash: String) -> Bool {
        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { return false }
        return blossomFile(forHash: hash, extensionHint: "") != nil
    }

    func blossomFile(forHash hash: String, extensionHint: String) -> URL? {
        if let exact = blossomFile(named: hash) {
            return exact
        }

        if !extensionHint.isEmpty, let withExtension = blossomFile(named: "\(hash).\(extensionHint)") {
            return withExtension
        }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: blossomDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return contents.first { $0.lastPathComponent.hasPrefix("\(hash).") && $0.pathExtension != "corrupt" }
    }
}
