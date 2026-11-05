import CryptoKit
import Foundation

/// Which files the vault's Blossom folder holds, by sha256, kept in memory so
/// a photo that is not on the phone costs one `stat` of the folder instead of
/// a full listing. The gallery asks this once per photo, and most photos from
/// other people are not on the phone, so a big vault used to list its whole
/// folder once per photo.
///
/// The relay writes and deletes blobs itself, so the app is not told about
/// every change. The folder's own modification date moves whenever a file is
/// added, renamed into place or removed, so the list is read again whenever
/// that date differs from the one it was read at. Memory only: nothing here is
/// written anywhere.
final class BlossomFolderIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var directory: URL?
    private var readAt: Date?
    /// sha256 to the first file named `<sha256>.<ext>` (never a partial one, `isPartial`).
    private var byHash: [String: String] = [:]
    /// How many times the folder was listed: for tests.
    private(set) var listings = 0

    init() {}

    /// The file named `<hash>.<ext>` in `directory`, or nil.
    func file(forHash hash: String, in directory: URL) -> URL? {
        let modified = Self.modificationDate(of: directory)
        lock.lock()
        defer { lock.unlock() }
        if self.directory != directory || readAt == nil || modified == nil || modified != readAt {
            reload(directory, modified: modified)
        }
        return byHash[hash].map { directory.appendingPathComponent($0) }
    }

    /// Forget the list, so the next lookup reads the folder again.
    func invalidate() {
        lock.lock()
        readAt = nil
        lock.unlock()
    }

    private func reload(_ directory: URL, modified: Date?) {
        listings += 1
        self.directory = directory
        // The date is taken before the listing, so a file landing while it
        // runs moves the date past it and the next lookup lists again.
        readAt = modified
        byHash = [:]
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where !name.hasPrefix(".") {
            guard let dot = name.firstIndex(of: "."), name.distance(from: name.startIndex, to: dot) == 64 else { continue }
            if Self.isPartial(name) { continue }
            let hash = String(name[..<dot])
            if byHash[hash] == nil { byHash[hash] = name }
        }
    }

    /// Files that are not the blob: the relay's write-then-rename temp, one
    /// the viewer set aside as broken, and the apps' download and restore
    /// temps (haven-go load_blob.go partialBlobSuffixes). Counting a
    /// half-written `<sha>.tmp` as stored hid that photo for good.
    static let partialExtensions: Set<String> = ["tmp", "corrupt", "part", "restoring", "download"]

    static func isPartial(_ name: String) -> Bool {
        partialExtensions.contains((name as NSString).pathExtension)
    }

    private static func modificationDate(of directory: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: directory.path))?[.modificationDate] as? Date
    }
}

/// Moves the files of an unpacked media backup into the Blossom folder, the
/// way Android's BlossomArchive.import does: a file goes in only when its
/// bytes hash to the sha256 its name claims, and an existing blob is swapped
/// atomically (`replaceItemAt`), never deleted first. A wrong-bytes entry
/// used to replace a good photo, and a failed move after the delete lost it.
enum BlossomArchiveRestore {
    struct Result: Equatable {
        var imported = 0
        /// Named like a blob but holding other bytes.
        var mismatched = 0
        /// Not named like a blob, or not readable.
        var skipped = 0
    }

    /// Every file under `staging`, folders included (a zip of a folder puts
    /// its blobs one level down), into `blossomDir` as `<sha256>`.
    static func restore(from staging: URL, into blossomDir: URL, fileManager fm: FileManager = .default) -> Result {
        var result = Result()
        guard let walker = fm.enumerator(at: staging, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return result
        }
        for case let fileURL as URL in walker {
            if fileURL.lastPathComponent == "__MACOSX" {
                walker.skipDescendants()
                continue
            }
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let name = fileURL.deletingPathExtension().lastPathComponent
            guard isBlobHash(name) else {
                result.skipped += 1
                continue
            }
            guard let digest = sha256Hex(of: fileURL) else {
                result.skipped += 1
                continue
            }
            guard digest == name else {
                result.mismatched += 1
                continue
            }
            let dest = blossomDir.appendingPathComponent(name)
            do {
                if fm.fileExists(atPath: dest.path) {
                    _ = try fm.replaceItemAt(dest, withItemAt: fileURL)
                } else {
                    try fm.moveItem(at: fileURL, to: dest)
                }
                result.imported += 1
            } catch {
                result.skipped += 1
            }
        }
        return result
    }

    static func isBlobHash(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// The file's sha256, read in 1 MiB pieces so a video isn't loaded whole.
    static func sha256Hex(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            // read returns nil (or empty) at the end of the file.
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
