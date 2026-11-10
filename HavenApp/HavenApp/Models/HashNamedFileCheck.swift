import Foundation
import CryptoKit

/// SHA-256 of a Blossom blob as lowercase hex, the form its filename uses.
/// `MediaCacheService` checks hash-named local copies with this before
/// trusting them.
enum HashNamedFileCheck {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Hashes a file in 1 MB chunks so a large blob is never held whole.
    /// nil when the file cannot be opened.
    static func sha256Hex(streaming fileURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1 << 20)
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
