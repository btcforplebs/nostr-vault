import Foundation

/// Reads and writes each vault owner's "removed from this device" list
/// (`DeviceRemovedHashes`, A3) beside the vault folder, from any thread.
/// The engine reads the same file (haven-go removed_here.go).
final class DeviceRemovedStore: @unchecked Sendable {
    static let shared = DeviceRemovedStore()

    private let lock = NSLock()
    private var lists: [String: DeviceRemovedHashes] = [:] // by file path

    /// `owner`'s list for the vault at `vault` (empty when none was saved).
    func list(owner: String, vault: URL) -> DeviceRemovedHashes {
        guard let url = DeviceRemovedHashes.fileURL(owner: owner, vault: vault) else { return DeviceRemovedHashes() }
        return lock.withLock { loadLocked(url) }
    }

    /// `hashes` without the ones `owner` removed here.
    func keeping(_ hashes: [String], owner: String, vault: URL) -> [String] {
        list(owner: owner, vault: vault).keeping(hashes)
    }

    /// Puts `sha256` on the list and writes it. false when it could not be
    /// written: the caller must not delete, or the next run pulls it back.
    func add(_ sha256: String, owner: String, vault: URL) -> Bool {
        guard let url = DeviceRemovedHashes.fileURL(owner: owner, vault: vault) else { return false }
        return lock.withLock {
            var list = loadLocked(url)
            list.add(sha256)
            guard list.contains(sha256), saveLocked(list, to: url) else { return false }
            lists[url.path] = list
            return true
        }
    }

    /// Takes `sha256` off the list (an explicit Save to Vault, or a delete
    /// that did not happen).
    func remove(_ sha256: String, owner: String, vault: URL) {
        guard let url = DeviceRemovedHashes.fileURL(owner: owner, vault: vault) else { return }
        lock.withLock {
            var list = loadLocked(url)
            guard list.contains(sha256) else { return }
            list.remove(sha256)
            if saveLocked(list, to: url) { lists[url.path] = list }
        }
    }

    private func loadLocked(_ url: URL) -> DeviceRemovedHashes {
        if let have = lists[url.path] { return have }
        let saved = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(DeviceRemovedHashes.self, from: $0) }
            ?? DeviceRemovedHashes()
        lists[url.path] = saved
        return saved
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
