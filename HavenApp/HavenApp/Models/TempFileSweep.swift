import Foundation

/// Clears the app's own leftovers from `tmp/` at launch.
///
/// Nothing in the app removed a temp file a killed or crashed job left
/// behind, and iOS does not empty an app's `tmp/` on its own while there is
/// disk to spare. On LogePhone (2026-11-26) that came to about 19 GB:
/// cut-off imports, URLSession downloads never moved, upload copies and
/// export zips that were shared and then kept.
///
/// Safety, in the order it is checked:
/// - Only the top level of the given folder (the app's `tmp/`) is looked at,
///   and only names the app itself writes (`kind(of:)`). Anything else there,
///   such as the relay's socket, the fallback `Haven/` folder or another
///   framework's files, is never touched.
/// - Symlinks are left to `PlayableLinks.purgeStale`.
/// - A file a running job holds (`TempFileLeases`) is kept, however old.
/// - Only an entry that has not changed for `maxAge` goes. The age is the
///   newer of the content and status-change times, so a file just copied or
///   moved here (which keeps its source's modified time) counts as new.
/// - A hash-named playable link (`<sha256>.<ext>`) is a hard link to a vault
///   blob, sharing its bytes: it goes only when its link count is 1, meaning
///   the blob itself was already deleted and the link alone holds the space.
///
/// Pure Foundation (plus `lstat`), so it is unit-tested against a temp folder.
enum TempFileSweep {
    /// An entry unchanged this long belongs to no job still running.
    static let maxAge: TimeInterval = 24 * 60 * 60

    enum Kind: String, CaseIterable {
        /// `StreamingBlobDownload` (`import-<uuid>.part`) and owner import (`import-….blob`).
        case importDownload
        /// A URLSession download task's file that was never moved or removed.
        case urlSessionDownload
        /// Copies made to upload (`haven-upload-`, `queued-`, `homevault-`).
        case uploadCopy
        /// Backup zips and their staging folders.
        case export
        /// Videos the app wrote out to compress, send or share.
        case videoOut
        /// Other short-lived folders and files the app names.
        case scratch
        /// `<sha256>.<ext>`: a playable link to a blob (see type comment).
        case playableLink
    }

    struct Result: Equatable {
        var removed = 0
        var removedBytes: Int64 = 0
        /// Named entries kept because they are new or held.
        var kept = 0
    }

    private static let prefixes: [(String, Kind)] = [
        ("import-", .importDownload),
        ("CFNetworkDownload_", .urlSessionDownload),
        ("haven-upload-", .uploadCopy),
        ("queued-", .uploadCopy),
        ("homevault-", .uploadCopy),
        ("blossom-backup-", .export),
        ("haven-backup-", .export),
        ("nostrvault-backup-", .export),
        ("blossom_export_temp_", .export),
        ("blossom_import_source_", .export),
        ("BlossomExport_", .export),
        ("BlossomImport_", .export),
        ("nv-video-", .videoOut),
        ("dm-video-", .videoOut),
        ("divine-", .videoOut),
        ("share-", .scratch),
        ("private-copy-", .scratch),
        ("emoji-zip-", .scratch),
        ("mirror-race-", .scratch),
    ]

    /// Which of the app's own temp files `name` is, or nil for anything else.
    static func kind(of name: String) -> Kind? {
        if let hit = prefixes.first(where: { name.hasPrefix($0.0) }) { return hit.1 }
        let stem = name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? name
        if stem.count == 64, stem.allSatisfy(\.isHexDigit) { return .playableLink }
        // `<uuid>.mp4`: a grid or list video saved out to share.
        if name.hasSuffix(".mp4"), UUID(uuidString: String(name.dropLast(4))) != nil { return .videoOut }
        return nil
    }

    /// Removes the app's own stale entries at the top of `directory`.
    static func sweep(directory: URL,
                      now: Date = Date(),
                      maxAge: TimeInterval = maxAge,
                      isHeld: (URL) -> Bool = { TempFileLeases.shared.isHeld($0) },
                      fileManager fm: FileManager = .default) -> Result {
        var result = Result()
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return result }
        for name in names {
            guard let kind = kind(of: name) else { continue }
            let url = directory.appendingPathComponent(name)
            guard let top = Stat(url.path), !top.isSymlink else { continue }
            if kind == .playableLink && (top.isDirectory || top.links > 1) { continue }
            if isHeld(url) { result.kept += 1; continue }
            let (newest, bytes) = top.isDirectory ? walk(url, fm) : (top.changed, top.size)
            guard now.timeIntervalSince(newest) > maxAge else { result.kept += 1; continue }
            do {
                try fm.removeItem(at: url)
                result.removed += 1
                result.removedBytes += bytes
            } catch {
                continue
            }
        }
        return result
    }

    /// A folder's newest change (itself included) and its bytes, without
    /// following links.
    private static func walk(_ dir: URL, _ fm: FileManager) -> (Date, Int64) {
        var newest = Stat(dir.path)?.changed ?? .distantFuture
        var bytes: Int64 = 0
        guard let e = fm.enumerator(atPath: dir.path) else { return (.distantFuture, 0) }
        while let rel = e.nextObject() as? String {
            guard let s = Stat(dir.appendingPathComponent(rel).path) else { continue }
            newest = max(newest, s.changed)
            if !s.isDirectory && !s.isSymlink { bytes += s.size }
        }
        return (newest, bytes)
    }

    /// `lstat` of one path: never follows a symlink.
    private struct Stat {
        let isSymlink: Bool
        let isDirectory: Bool
        let links: Int
        let size: Int64
        /// Newer of content-modified and status-changed.
        let changed: Date

        init?(_ path: String) {
            var st = stat()
            guard lstat(path, &st) == 0 else { return nil }
            let type = st.st_mode & S_IFMT
            isSymlink = type == S_IFLNK
            isDirectory = type == S_IFDIR
            links = Int(st.st_nlink)
            size = Int64(st.st_size)
            func date(_ t: timespec) -> Date {
                Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_nsec) / 1e9)
            }
            changed = max(date(st.st_mtimespec), date(st.st_ctimespec))
        }
    }
}

/// Temp files a running job is using, so `TempFileSweep` never removes one
/// mid-job, however old it looks.
final class TempFileLeases: @unchecked Sendable {
    static let shared = TempFileLeases()

    private let lock = NSLock()
    private var held: [String: Int] = [:]

    func hold(_ url: URL) {
        let key = url.standardizedFileURL.path
        lock.withLock { held[key, default: 0] += 1 }
    }

    func release(_ url: URL) {
        let key = url.standardizedFileURL.path
        lock.withLock {
            guard let n = held[key] else { return }
            held[key] = n > 1 ? n - 1 : nil
        }
    }

    /// Whether `url`, or anything inside it, is held.
    func isHeld(_ url: URL) -> Bool {
        let key = url.standardizedFileURL.path
        return lock.withLock { held.keys.contains { $0 == key || $0.hasPrefix(key + "/") } }
    }
}
