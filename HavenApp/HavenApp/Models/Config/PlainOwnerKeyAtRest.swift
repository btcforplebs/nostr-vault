import Foundation

/// Where a plaintext owner key (`HavenConfig.ownerNsec`) is kept between
/// launches. Older builds wrote it to config.json; this build keeps it in the
/// keychain and leaves it out of the file, the same rule Android follows
/// (ConfigStore.save, #2448). `HavenConfig.encryptPlaintextOwnerKey` still
/// turns it into `ownerNcryptsec` when it can; this covers the cases where it
/// cannot (`.keptUnverified`, `.failed`) and any key that reaches `ownerNsec`
/// in memory.
///
/// The rules:
/// - A key the keychain holds is never written to config.json.
/// - A key that config.json already held (an older build's) stays there until
///   the keychain has taken it, so no key is lost.
/// - Any other key never goes in the file. If the keychain refuses it, it is
///   in memory only and `notSaved` is raised for the warning.
/// - The keychain copy is deleted only after config.json has been written
///   without a plaintext key, and only if this session read or wrote it.
struct PlainOwnerKeyAtRest {
    /// The keychain account (service `CredentialStore.service`).
    static let account = "owner-nsec"

    /// The plaintext key config.json holds now, as last read or written.
    private(set) var inFile: String
    /// The key the keychain holds, as this session last read or wrote it.
    /// Empty when it holds none or could not be read.
    private(set) var inKeychain: String

    init(inFile: String = "", inKeychain: String = "") {
        self.inFile = Self.clean(inFile)
        self.inKeychain = Self.clean(inKeychain)
    }

    /// What a save writes for `ownerNsec`, and whether the key is unsaved.
    struct Decision: Equatable {
        let onDisk: String
        let notSaved: Bool
    }

    /// At load: `fromFile` is config.json's `ownerNsec`, `stored` the
    /// keychain's. Returns the key to keep in memory. A key in the file wins
    /// (an older build wrote it after the keychain copy), and the next save
    /// stores it.
    static func loaded(fromFile: String, stored: String?) -> (state: PlainOwnerKeyAtRest, key: String) {
        let file = clean(fromFile)
        let state = PlainOwnerKeyAtRest(inFile: file, inKeychain: stored ?? "")
        return (state, file.isEmpty ? state.inKeychain : file)
    }

    /// Before config.json is written. `store` must write the key and read it
    /// back; it is called only when the keychain does not already hold it.
    mutating func prepareSave(_ current: String, store: (String) -> Bool) -> Decision {
        let key = Self.clean(current)
        guard !key.isEmpty else { return Decision(onDisk: "", notSaved: false) }
        if inKeychain != key, store(key) { inKeychain = key }
        if inKeychain == key { return Decision(onDisk: "", notSaved: false) }
        // Refused. The file keeps an older build's key, so it is not lost;
        // a key that was never in the file stays out of it.
        if key == inFile { return Decision(onDisk: key, notSaved: false) }
        return Decision(onDisk: "", notSaved: true)
    }

    /// After config.json was written with `onDisk`. Returns the key that
    /// came out of the file this save (now held by the keychain), for the
    /// caller to scrub from the copies beside it, or nil.
    @discardableResult
    mutating func didSave(onDisk: String, current: String, delete: () -> Bool) -> String? {
        let removed = (!inFile.isEmpty && onDisk.isEmpty && inFile == inKeychain) ? inFile : nil
        inFile = Self.clean(onDisk)
        if Self.clean(current).isEmpty, !inKeychain.isEmpty, delete() { inKeychain = "" }
        return removed
    }

    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension HavenConfig {
    /// The config as config.json gets it: `ownerNsec` is `onDisk`, decided
    /// by `PlainOwnerKeyAtRest.prepareSave`, never the key in memory.
    func withPlainOwnerKeyOnDisk(_ onDisk: String) -> HavenConfig {
        var copy = self
        copy.ownerNsec = onDisk
        return copy
    }
}
