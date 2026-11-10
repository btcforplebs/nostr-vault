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
        resolveLocalFile(for: url) { file, hash in verifiedHashNamedFile(file, expectedHash: hash) }
    }

    /// The bytes of the local copy `internalLocalFileURL` would pick, read
    /// once: a hash-named file is checked against its hash on the same bytes,
    /// instead of one full read to hash it and a second to load it.
    /// Reads the disk: never call on the main thread.
    func loadLocalFileData(for url: URL) -> Data? {
        var checked: Data?
        guard let file = resolveLocalFile(for: url, verify: { file, hash in
            guard let data = verifiedHashNamedFileData(file, expectedHash: hash) else { return nil }
            checked = data
            return file
        }) else { return nil }
        return checked ?? cachedFileData(at: file)
    }

    /// The lookup order shared by `internalLocalFileURL` and
    /// `loadLocalFileData`; `verify` checks a file named by a Blossom hash.
    private func resolveLocalFile(for url: URL, verify: (URL, String) -> URL?) -> URL? {
        let blobHash = Self.blossomHash(in: url)

        // 1. Local relay media-tab URLs may point at files in Blossom by their
        // exact filename, not only by a bare sha256 hash. Resolve those directly
        // so AVFoundation does not have to stream through localhost on iOS.
        if isLocalURL(url), let localBlossomURL = blossomFile(named: url.lastPathComponent) {
            if let blobHash {
                return verify(localBlossomURL, blobHash)
            }
            return localBlossomURL
        }

        // 2. Try to find if it's a local Blossom file we already have by hash.
        if let blobHash,
           let localBlossomURL = blossomFile(forHash: blobHash, extensionHint: url.pathExtension),
           let verified = verify(localBlossomURL, blobHash) {
            return verified
        }

        // 3. Try the general cache
        let path = cachePath(for: url)
        if FileManager.default.fileExists(atPath: path.path) {
            // Blossom-hash cache entries are keyed (and named) by the blob's
            // content hash, so they can be verified too. URL-keyed entries can't.
            if let blobHash {
                return verify(path, blobHash)
            }
            return path
        }

        return nil
    }

    /// Compiled once: views call `blossomHash(in:)` from their body on every
    /// update, and compiling the pattern each time showed on the main thread.
    private static let blossomHashRegex = try? NSRegularExpression(
        pattern: #"^([a-f0-9]{64})(\.[a-z0-9]+)?$"#, options: .caseInsensitive)

    /// Extracts a 64-hex Blossom content hash from the URL's last path component, if present.
    static func blossomHash(in url: URL) -> String? {
        let last = url.lastPathComponent
        guard let regex = blossomHashRegex else { return nil }
        let ns = last as NSString
        guard let match = regex.firstMatch(in: last, options: [], range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range(at: 1)).lowercased()
    }

    /// Returns `fileURL` only if its content actually hashes to `expectedHash`
    /// (memoized per launch). A mismatching file is discarded — deleted from the
    /// cache, or quarantined with a `.corrupt` suffix in the Blossom store — so
    /// callers fall through to the healthy remote URL and the copy can heal.
    func verifiedHashNamedFile(_ fileURL: URL, expectedHash: String) -> URL? {
        checkHashNamedFile(fileURL, expectedHash: expectedHash, keepData: false).ok ? fileURL : nil
    }

    /// `verifiedHashNamedFile`, returning the bytes it hashed so the caller
    /// does not read the file a second time. A file over the hash limit, or
    /// one already verified this launch, is read without hashing.
    func verifiedHashNamedFileData(_ fileURL: URL, expectedHash: String) -> Data? {
        let result = checkHashNamedFile(fileURL, expectedHash: expectedHash, keepData: true)
        guard result.ok else { return nil }
        return result.data ?? cachedFileData(at: fileURL)
    }

    private func checkHashNamedFile(_ fileURL: URL, expectedHash: String, keepData: Bool) -> (ok: Bool, data: Data?) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.resolvingSymlinksInPath().path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return (false, nil) }
        if size == 0 {
            discardCorruptFile(fileURL)
            return (false, nil)
        }
        if size > Self.integrityMaxHashBytes { return (true, nil) }

        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(fileURL.path)|\(size)|\(mtime)"
        integrityLock.lock()
        let cached = integrityVerdicts[key]
        integrityLock.unlock()
        if let cached { return (cached, nil) }

        let digest: String
        var kept: Data?
        if keepData {
            // One read serves both the hash and the caller.
            guard let data = cachedFileData(at: fileURL) else { return (false, nil) }
            digest = HashNamedFileCheck.sha256Hex(data)
            kept = data
        } else {
            guard let streamed = HashNamedFileCheck.sha256Hex(streaming: fileURL) else { return (false, nil) }
            digest = streamed
        }
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
            return (false, nil)
        }
        return (true, kept)
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

        return blossomFolderIndex.file(forHash: hash, in: blossomDirectory)
    }
}
