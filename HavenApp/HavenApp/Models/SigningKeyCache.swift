import Foundation
import CryptoKit

/// Where the key that signs comes from, read off `HavenConfig` and the
/// keychain on the main actor. Plain strings, so the work it names can run
/// on any thread.
enum SigningKeySource: Sendable, Equatable {
    /// A plaintext key (an old config, before it is encrypted): no derivation.
    case plain(hex: String)
    /// A password-locked key (NIP-49 ncryptsec) and its stored password.
    case locked(ncryptsec: String, password: String)
}

/// The signing key, derived once a session instead of once a signature.
///
/// Opening a NIP-49 key is a scrypt run (a second or so on a phone). It used
/// to run on the main thread for every like, post, follow, DM sent or opened
/// and relay AUTH. An entry is filed under the ncryptsec text itself, so a
/// new or changed key (which is a new ncryptsec) is never answered from an
/// old entry, and under a digest of the password it opened with, so a
/// password that no longer matches what the keychain holds re-derives (and
/// fails) as before. Wrong passwords are not cached.
///
/// `hexKey(for:)` blocks its caller for the derivation: call it off the main
/// thread (`hexKeyOffMain`). Two callers asking at once get one derivation:
/// the second waits for the first and reads its entry.
final class SigningKeyCache: @unchecked Sendable {
    static let shared = SigningKeyCache(derive: SigningKeyCache.openNcryptsec)

    typealias Derive = @Sendable (_ ncryptsec: String, _ password: String) throws -> String

    private struct Entry {
        let passwordDigest: Data
        let hex: String
    }

    private let derive: Derive
    private let lock = NSLock()
    /// Held for a whole derivation, so concurrent askers share one.
    private let deriveLock = NSLock()
    private var entries: [String: Entry] = [:]
    private var derivationCount = 0
    private var mainThreadDerivationCount = 0

    init(derive: @escaping Derive) {
        self.derive = derive
    }

    /// Derivations run so far (successful or not).
    var derivations: Int { lock.withLock { derivationCount } }
    /// Of those, how many ran on the main thread. Zero in a healthy session.
    var mainThreadDerivations: Int { lock.withLock { mainThreadDerivationCount } }

    /// The hex key for `source`, from the cache when it holds it. Never derives.
    func cachedHexKey(for source: SigningKeySource) -> String? {
        switch source {
        case .plain(let hex):
            return hex
        case .locked(let ncryptsec, let password):
            return lookup(ncryptsec, Self.digest(password))
        }
    }

    /// The hex key for `source`, deriving it when this session has not yet.
    /// Blocks for the derivation; see the type's note.
    func hexKey(for source: SigningKeySource) throws -> String {
        switch source {
        case .plain(let hex):
            return hex
        case .locked(let ncryptsec, let password):
            let digest = Self.digest(password)
            if let hit = lookup(ncryptsec, digest) { return hit }
            deriveLock.lock()
            defer { deriveLock.unlock() }
            if let hit = lookup(ncryptsec, digest) { return hit }
            lock.withLock {
                derivationCount += 1
                if Thread.isMainThread { mainThreadDerivationCount += 1 }
            }
            let hex = try derive(ncryptsec, password)
            lock.withLock { entries[ncryptsec] = Entry(passwordDigest: digest, hex: hex) }
            return hex
        }
    }

    /// `hexKey(for:)` on a background thread, for callers on the main actor.
    func hexKeyOffMain(for source: SigningKeySource) async throws -> String {
        if let hit = cachedHexKey(for: source) { return hit }
        return try await Task.detached(priority: .userInitiated) { [self] in
            try self.hexKey(for: source)
        }.value
    }

    /// Derives `source` in the background so the first signature finds it ready.
    /// At the signing priority: a like that arrives mid-derivation waits on it.
    func warm(_ source: SigningKeySource) {
        guard cachedHexKey(for: source) == nil else { return }
        Task.detached(priority: .userInitiated) { [self] in
            _ = try? self.hexKey(for: source)
        }
    }

    /// Keeps only the entries for `ncryptsecs`: a key removed from the config
    /// (an account removed, the owner key deleted) leaves memory with it.
    func retainOnly(_ ncryptsecs: Set<String>) {
        lock.withLock { entries = entries.filter { ncryptsecs.contains($0.key) } }
    }

    func removeAll() {
        lock.withLock { entries.removeAll() }
    }

    private func lookup(_ ncryptsec: String, _ digest: Data) -> String? {
        lock.withLock {
            guard let entry = entries[ncryptsec], entry.passwordDigest == digest else { return nil }
            return entry.hex
        }
    }

    private static func digest(_ password: String) -> Data {
        Data(SHA256.hash(data: Data(password.utf8)))
    }

    /// The app's derivation: NIP-49 decrypt, then the nsec (or raw hex) to hex.
    static let openNcryptsec: Derive = { ncryptsec, password in
        let nsec = try NIP49Service.decrypt(ncryptsec: ncryptsec, password: password)
        guard let hex = HavenConfig.hexKey(fromNsec: nsec) else {
            throw NIP49Service.NIP49Error.decodingFailed
        }
        return hex
    }
}

/// Where an account's key would come from, before anything is derived.
enum SigningKeyLookup: Sendable, Equatable {
    case found(SigningKeySource)
    /// The key is password-locked and the keychain gave no password.
    case passwordMissing
    /// No key for this account on this device.
    case noKey
}

extension HavenConfig {
    /// The owner's key source: its ncryptsec and the password to open it
    /// (`password`, else `storedPassword()`), or the old plaintext key.
    func ownerKeySource(password: String?, storedPassword: () -> String?) -> SigningKeyLookup {
        let locked = ownerNcryptsec.trimmingCharacters(in: .whitespacesAndNewlines)
        if !locked.isEmpty {
            guard let pwd = password ?? storedPassword() else { return .passwordMissing }
            return .found(.locked(ncryptsec: locked, password: pwd))
        }
        guard let hex = ownerHexKey, !hex.isEmpty else { return .noKey }
        return .found(.plain(hex: hex))
    }

    /// A whitelisted account's key source: its ncryptsec and stored password.
    func credentialKeySource(forNpub npub: String, storedPassword: (String) -> String?) -> SigningKeyLookup {
        guard let locked = accountCredentials[npub], !locked.isEmpty else { return .noKey }
        guard let pwd = storedPassword(npub) else { return .passwordMissing }
        return .found(.locked(ncryptsec: locked, password: pwd))
    }

    /// Every password-locked key this config holds, as `SigningKeyCache` files them.
    var lockedKeyTexts: Set<String> {
        var out = Set(accountCredentials.values.filter { !$0.isEmpty })
        let owner = ownerNcryptsec.trimmingCharacters(in: .whitespacesAndNewlines)
        if !owner.isEmpty { out.insert(owner) }
        return out
    }
}
