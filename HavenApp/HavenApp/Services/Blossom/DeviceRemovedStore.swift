import Foundation

/// Reads and writes this device's "removed from this device" list
/// (`DeviceRemovedHashes`, A3) in the relay data folder, from any thread.
/// The engine and the Android app read the same file.
final class DeviceRemovedStore: @unchecked Sendable {
    static let shared = DeviceRemovedStore()

    private let lock = NSLock()
    private var lists: [String: DeviceRemovedHashes] = [:] // by file path

    /// The list in `relayDataDir` (empty when none was saved).
    func list(relayDataDir: URL) -> DeviceRemovedHashes {
        let url = DeviceRemovedHashes.fileURL(relayDataDir: relayDataDir)
        return lock.withLock { loadLocked(url) }
    }

    /// `hashes` without the ones removed here.
    func keeping(_ hashes: [String], relayDataDir: URL) -> [String] {
        list(relayDataDir: relayDataDir).keeping(hashes)
    }

    /// Puts `sha256` on `owner`'s list and writes it. false when it could not
    /// be written: the caller must not delete, or the next run pulls it back.
    func add(_ sha256: String, owner: String, relayDataDir: URL) -> Bool {
        let url = DeviceRemovedHashes.fileURL(relayDataDir: relayDataDir)
        return lock.withLock {
            var list = loadLocked(url)
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
        lock.withLock {
            var list = loadLocked(url)
            guard list.contains(sha256) else { return }
            list.remove(sha256)
            if saveLocked(list, to: url) { lists[url.path] = list }
        }
    }

    /// The file's list, read again each time it is asked for: one read of a
    /// small file, and a cached copy could miss a write by another process.
    /// An unreadable file keeps the last list read, so a half-written file
    /// cannot let everything back in (as the engine does).
    private func loadLocked(_ url: URL) -> DeviceRemovedHashes {
        guard let data = try? Data(contentsOf: url) else {
            if !FileManager.default.fileExists(atPath: url.path) { lists[url.path] = nil; return DeviceRemovedHashes() }
            return lists[url.path] ?? DeviceRemovedHashes()
        }
        guard let saved = try? JSONDecoder().decode(DeviceRemovedHashes.self, from: data) else {
            return lists[url.path] ?? DeviceRemovedHashes()
        }
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
