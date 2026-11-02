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
    /// sha256 to the first file named `<sha256>.<ext>` (never a `.corrupt` one).
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
            if (name as NSString).pathExtension == "corrupt" { continue }
            let hash = String(name[..<dot])
            if byHash[hash] == nil { byHash[hash] = name }
        }
    }

    private static func modificationDate(of directory: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: directory.path))?[.modificationDate] as? Date
    }
}
