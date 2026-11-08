import Foundation

/// The date a blob copied into this vault should carry on disk.
///
/// The Media grid dates a local file by its modified time whenever the note
/// that uses it isn't loaded. A copy written "now" makes an old photo jump to
/// Today, and every write re-sorts the grid. Copy-ins stamp the file with the
/// photo's own date instead: the note's `created_at`, or the server's BUD-02
/// `uploaded` time.
enum CopiedInDate {
    /// The newest date per key. The grid's rule for a photo used in several
    /// notes, so it gets one date whatever order the notes arrive in.
    static func newestByKey<T>(_ items: [T], key: (T) -> String, date: (T) -> Date) -> [String: Date] {
        var out: [String: Date] = [:]
        for item in items {
            let k = key(item), d = date(item)
            if let have = out[k], have >= d { continue }
            out[k] = d
        }
        return out
    }

    /// The earliest BUD-02 `uploaded` time (unix seconds) per sha256 across
    /// servers. The first upload is closest to the photo's real date; later
    /// ones are copies. Missing hashes and zero/negative times are skipped.
    static func uploadedByHash(_ blobs: [(sha256: String?, uploaded: Int?)]) -> [String: Date] {
        var out: [String: Date] = [:]
        for blob in blobs {
            guard let hash = blob.sha256?.lowercased(), !hash.isEmpty,
                  let secs = blob.uploaded, secs > 0 else { continue }
            let d = Date(timeIntervalSince1970: TimeInterval(secs))
            if let have = out[hash], have <= d { continue }
            out[hash] = d
        }
        return out
    }

    /// The stored file for a blob: `<sha256>` or `<sha256>.<ext>`.
    static func storedFile(sha256: String, in dir: URL) -> URL? {
        let fm = FileManager.default
        let exact = dir.appendingPathComponent(sha256)
        if fm.fileExists(atPath: exact.path) { return exact }
        let prefix = sha256 + "."
        guard let name = (try? fm.contentsOfDirectory(atPath: dir.path))?
            .filter({ $0.hasPrefix(prefix) }).sorted().first else { return nil }
        return dir.appendingPathComponent(name)
    }

    /// Set the blob's file modified time to `date`. Nothing happens with no
    /// date, a date in the future, or no stored file. True when stamped.
    @discardableResult
    static func stamp(sha256: String, in dir: URL, date: Date?, now: Date = Date()) -> Bool {
        guard let date, date <= now,
              let file = storedFile(sha256: sha256, in: dir) else { return false }
        return (try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)) != nil
    }
}
