import Foundation

/// Reads and writes this device's "removed from this device" list
/// (`DeviceRemovedHashes`, A3) in the relay data folder, from any thread.
/// The engine and the Android app read the same file.
///
/// Also holds a file set aside while its delete is being checked: it moves
/// out of the vault folder (to `removed_here_aside/<hash>/`, every name it
/// is served by) before the servers are
/// asked, so no address of this device (its tunnel domain, Tailscale or LAN
/// name) can answer for it and prove its own copy (Tron, PR 2652 M1). Not a
/// `<hash>.deleting` rename: the engine serves `<hash>.<any ext>` apart from
/// its partial suffixes (haven-go load_blob.go), so that would still answer.
final class DeviceRemovedStore: @unchecked Sendable {
    static let shared = DeviceRemovedStore()
    static let asideFolder = "removed_here_aside"

    private let lock = NSLock()
    private var lists: [String: DeviceRemovedHashes] = [:] // by file path
    private var inFlight = Set<String>() // hashes set aside by a delete running now

    /// The list in `relayDataDir` (empty when none was saved).
    func list(relayDataDir: URL) -> DeviceRemovedHashes {
        let url = DeviceRemovedHashes.fileURL(relayDataDir: relayDataDir)
        return lock.withLock { loadLocked(url) ?? lists[url.path] ?? DeviceRemovedHashes() }
    }

    /// `hashes` without the ones removed here.
    func keeping(_ hashes: [String], relayDataDir: URL) -> [String] {
        list(relayDataDir: relayDataDir).keeping(hashes)
    }

    /// Puts `sha256` on `owner`'s list and writes it. false when it could not
    /// be read or written: the caller must not delete, or the next run pulls
    /// it back.
    func add(_ sha256: String, owner: String, relayDataDir: URL) -> Bool {
        let url = DeviceRemovedHashes.fileURL(relayDataDir: relayDataDir)
        return lock.withLock {
            guard var list = loadLocked(url) else { return false }
            list.add(sha256, owner: owner)
            guard list.contains(sha256), saveLocked(list, to: url) else { return false }
            lists[url.path] = list
            return true
        }
    }

    /// Takes `sha256` off every account's list (an explicit Save to Vault,
    /// or a delete that did not happen).
    func remove(_ sha256: String, relayDataDir: URL) {
        let url = DeviceRemovedHashes.fileURL(relayDataDir: relayDataDir)
        lock.withLock { removeLocked(sha256, url: url) }
    }

    // MARK: Set aside while the delete is checked

    private static let listedBeforeMarker = ".listed-before"

    /// Every vault file of `sha256`: the bare hash and each `<hash>.<ext>`,
    /// so no name of it is left to answer the check (Tron, #2654 low 2).
    static func vaultFiles(of sha256: String, in vault: URL) -> [URL] {
        let hash = sha256.lowercased()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: vault.path) else { return [] }
        return names.filter { let n = $0.lowercased(); return n == hash || n.hasPrefix(hash + ".") }
            .sorted().map { vault.appendingPathComponent($0) }
    }

    private func asideDir(_ relayDataDir: URL) -> URL {
        relayDataDir.standardizedFileURL.appendingPathComponent(Self.asideFolder, isDirectory: true)
    }

    /// Moves `files` (the vault copies of `sha256`) out of the vault folder,
    /// into `removed_here_aside/<hash>/`. `wasListed`: the hash was on the
    /// list before this check, so putting the files back leaves it listed
    /// (Tron, #2654 low 3); a marker file keeps that for a later process.
    /// false when they could not all be moved (then nothing changed).
    func setAside(_ files: [URL], sha256: String, wasListed: Bool, relayDataDir: URL) -> Bool {
        let hash = sha256.lowercased()
        let dir = asideDir(relayDataDir).appendingPathComponent(hash, isDirectory: true)
        return lock.withLock {
            guard !files.isEmpty, !FileManager.default.fileExists(atPath: dir.path) else { return false }
            var moved: [(URL, URL)] = []
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if wasListed {
                    try Data().write(to: dir.appendingPathComponent(Self.listedBeforeMarker))
                }
                for file in files {
                    let to = dir.appendingPathComponent(file.lastPathComponent)
                    try FileManager.default.moveItem(at: file, to: to)
                    moved.append((file, to))
                }
            } catch {
                for (from, to) in moved { try? FileManager.default.moveItem(at: to, to: from) }
                try? FileManager.default.removeItem(at: dir)
                return false
            }
            inFlight.insert(hash)
            return true
        }
    }

    /// The check refused, or the delete failed: every file goes back to the
    /// vault, and the list is as it was before the check. false when a file
    /// could not go back (it stays aside and listed; the next pass retries).
    @discardableResult
    func putBack(_ sha256: String, relayDataDir: URL, vault: URL) -> Bool {
        lock.withLock { putBackLocked(sha256.lowercased(), relayDataDir: relayDataDir, vault: vault) }
    }

    /// The check allowed it: the set-aside files go for good.
    func discardSetAside(_ sha256: String, relayDataDir: URL) throws {
        let dir = asideDir(relayDataDir).appendingPathComponent(sha256.lowercased(), isDirectory: true)
        try lock.withLock { try FileManager.default.removeItem(at: dir) }
    }

    /// The delete of `sha256` is over (deleted, or put back).
    func finished(_ sha256: String) {
        lock.withLock { _ = inFlight.remove(sha256.lowercased()) }
    }

    /// Puts back every file a delete left aside and never finished (the app
    /// quit mid-check), with the list as it was before that check.
    func recoverSetAside(relayDataDir: URL, vault: URL) {
        let root = asideDir(relayDataDir)
        let url = DeviceRemovedHashes.fileURL(relayDataDir: relayDataDir)
        lock.withLock {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path), !names.isEmpty else { return }
            for name in names {
                let hash = String(name.prefix(64)).lowercased()
                guard MediaSizeCache.isHash(hash), !inFlight.contains(hash) else { continue }
                if name.count == 64 {
                    putBackLocked(hash, relayDataDir: relayDataDir, vault: vault)
                    continue
                }
                // A file set aside by 3.3.1 before (65) (one flat file, never listed before).
                let from = root.appendingPathComponent(name), to = vault.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: to.path) {
                    try? FileManager.default.removeItem(at: from)
                } else if (try? FileManager.default.moveItem(at: from, to: to)) == nil {
                    continue
                }
                removeLocked(hash, url: url)
            }
        }
    }

    private func putBackLocked(_ hash: String, relayDataDir: URL, vault: URL) -> Bool {
        let dir = asideDir(relayDataDir).appendingPathComponent(hash, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let wasListed = names.contains(Self.listedBeforeMarker)
        var all = true
        for name in names where name != Self.listedBeforeMarker {
            let from = dir.appendingPathComponent(name), to = vault.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: to.path) {
                try? FileManager.default.removeItem(at: from)
            } else if (try? FileManager.default.moveItem(at: from, to: to)) == nil {
                all = false
            }
        }
        guard all else { return false }
        try? FileManager.default.removeItem(at: dir)
        if !wasListed { removeLocked(hash, url: DeviceRemovedHashes.fileURL(relayDataDir: relayDataDir)) }
        return true
    }

    // MARK: File

    private func removeLocked(_ sha256: String, url: URL) {
        guard var list = loadLocked(url), list.contains(sha256) else { return }
        list.remove(sha256)
        if saveLocked(list, to: url) { lists[url.path] = list }
    }

    /// The file's list, read again each time: one read of a small file, and
    /// a cached copy could miss a write by another process. No file: empty.
    /// A file that could not be read just now (iOS data protection, I/O):
    /// nil, so nothing is written over it. A file that is not a list is set
    /// aside as `removed_here.json.corrupt-<time>` and kept, never written
    /// over by the next add (Tron, PR 2652 S2); then the last list read in
    /// this process carries on.
    private func loadLocked(_ url: URL) -> DeviceRemovedHashes? {
        guard FileManager.default.fileExists(atPath: url.path) else { return DeviceRemovedHashes() }
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let saved = try? JSONDecoder().decode(DeviceRemovedHashes.self, from: data) {
            lists[url.path] = saved
            return saved
        }
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".corrupt-\(Int(Date().timeIntervalSince1970))")
        guard (try? FileManager.default.moveItem(at: url, to: aside)) != nil else { return nil }
        return lists[url.path] ?? DeviceRemovedHashes()
    }

    private func saveLocked(_ list: DeviceRemovedHashes, to url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(list) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
