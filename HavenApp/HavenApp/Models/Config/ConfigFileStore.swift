import Foundation

/// config.json on disk. It holds the owner's key, so a write is atomic, the
/// last good load is kept as config.json.bak, and a file that would not load
/// is copied aside before anything is written over it.
struct ConfigFileStore {
    let url: URL

    var backupURL: URL { url.appendingPathExtension("bak") }

    enum Loaded<Value> {
        /// Neither config.json nor its backup exists: a fresh install.
        case missing
        /// `fromBackup` is true when config.json was missing or unreadable and
        /// the backup was used instead.
        case loaded(Value, fromBackup: Bool)
        /// Neither file would load.
        case unreadable(Error)
    }

    private var fileManager: FileManager { .default }

    /// Loads config.json, falling back to the backup. A good config.json
    /// becomes the new backup, unless it holds no key and the backup does:
    /// a file that merely decodes (every field is optional) must not erase
    /// the last copy of the key.
    func load<Value: Decodable>(_ type: Value.Type, hasKey: (Value) -> Bool) -> Loaded<Value> {
        var mainError: Error?
        if fileManager.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let value = try JSONDecoder().decode(type, from: data)
                if hasKey(value) || !backupHasKey(type, hasKey: hasKey) {
                    try? data.write(to: backupURL, options: .atomic)
                }
                return .loaded(value, fromBackup: false)
            } catch {
                mainError = error
            }
        }
        if fileManager.fileExists(atPath: backupURL.path) {
            do {
                let value = try JSONDecoder().decode(type, from: Data(contentsOf: backupURL))
                return .loaded(value, fromBackup: true)
            } catch {
                return .unreadable(mainError ?? error)
            }
        }
        if let mainError { return .unreadable(mainError) }
        return .missing
    }

    private func backupHasKey<Value: Decodable>(_ type: Value.Type, hasKey: (Value) -> Bool) -> Bool {
        guard let data = try? Data(contentsOf: backupURL),
              let backup = try? JSONDecoder().decode(type, from: data) else { return false }
        return hasKey(backup)
    }

    /// Replaces config.json in one step, so a crash leaves the old file or the
    /// new one, never half of either.
    func write(_ data: Data) throws {
        try data.write(to: url, options: .atomic)
    }

    /// Copies a config.json that would not load to config.json.unreadable-<time>
    /// so it can still be recovered by hand. Throws when the copy fails, and
    /// the caller must not write over the file then.
    @discardableResult
    func preserveUnreadable(now: Date = Date()) throws -> URL? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let name = url.lastPathComponent + ".unreadable-\(Int(now.timeIntervalSince1970))"
        let copy = url.deletingLastPathComponent().appendingPathComponent(name)
        if !fileManager.fileExists(atPath: copy.path) {
            try fileManager.copyItem(at: url, to: copy)
        }
        return copy
    }

    /// Deletes the backup when a save drops the last key that this session
    /// loaded or saved from config.json itself, so a user who removes their
    /// key (say, before handing the device on) leaves no copy behind.
    /// `hadKey` must be false after a failed load or a load from the backup:
    /// a keyless config written then is a recovery, and the backup may hold
    /// the only copy of the key.
    @discardableResult
    func forgetBackupIfKeyRemoved(hadKey: Bool, hasKey: Bool, setupDone: Bool) -> Bool {
        guard hadKey, !hasKey, setupDone else { return false }
        try? fileManager.removeItem(at: backupURL)
        return true
    }

    /// The copies beside config.json that can hold an old key: the backup
    /// and every config.json.unreadable-<time>.
    var copyURLs: [URL] {
        let dir = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".unreadable-"
        let unreadable = ((try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix(prefix) }
            .sorted()
            .map { dir.appendingPathComponent($0) }
        return [backupURL] + unreadable
    }

    /// Removes each of `secrets` from the backup and the unreadable copies,
    /// as text, so it works on a file that will not decode too. Only values
    /// that now live somewhere safer belong in `secrets`: anything else in a
    /// copy (another key, say) is left alone. Returns the files rewritten.
    @discardableResult
    func scrub(_ secrets: [String]) -> [URL] {
        let needles = secrets.filter { !$0.isEmpty }
        guard !needles.isEmpty else { return [] }
        var rewritten: [URL] = []
        for file in copyURLs {
            guard let data = try? Data(contentsOf: file),
                  var text = String(data: data, encoding: .utf8) else { continue }
            let before = text
            for needle in needles { text = text.replacingOccurrences(of: needle, with: "") }
            guard text != before, (try? Data(text.utf8).write(to: file, options: .atomic)) != nil else { continue }
            rewritten.append(file)
        }
        return rewritten
    }

    /// Factory reset: config.json and its backup both go.
    func removeAll() {
        try? fileManager.removeItem(at: url)
        try? fileManager.removeItem(at: backupURL)
    }
}
