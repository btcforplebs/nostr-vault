import Foundation

/// Reads, saves and removes the wallet string kept on the active account
/// (see `NWCBackup` for the format). The string is only ever published NIP-44
/// encrypted to the account's own key, and never written to a log: errors here
/// carry no content.
@MainActor
enum NWCBackupService {
    enum BackupError: LocalizedError {
        case noKey
        case notAWallet
        case encryptFailed
        case accountChanged

        var errorDescription: String? {
            switch self {
            case .noKey: return "This account has no key on this device to encrypt with."
            case .notAWallet: return "That isn't a nostr+walletconnect:// link."
            case .encryptFailed: return "Couldn't encrypt the wallet. Nothing was saved."
            case .accountChanged: return "The account changed. Nothing was published; check again."
            }
        }
    }

    /// What `account`'s slot holds. With `askSigner` false, a remote signer
    /// (bunker) is not asked to decrypt: opening the wallet screen must not
    /// send the secret to the signer, so the slot shows as `needsSigner`
    /// until the user taps to load it.
    static func status(for account: String, askSigner: Bool,
                       nostrService: NostrService) async -> NWCBackup.Status {
        guard !account.isEmpty else { return .unknown }
        let config = ConfigService.shared.config
        let lookup = await nostrService.lookupNewestReplaceable(
            kind: NWCBackup.kind, for: account, alsoAsk: config.readRelays, dTag: NWCBackup.dTag)
        guard let event = lookup.event, NWCBackup.isBackup(kind: event.kind, tags: event.tags) else {
            return NWCBackup.status(slot: nil, answeredAny: lookup.answered > 0, read: .notTried)
        }
        let slot = (content: event.content, tags: event.tags, createdAt: event.created_at)
        if NWCBackup.isCleared(content: event.content, tags: event.tags) {
            return NWCBackup.status(slot: slot, answeredAny: true, read: .notTried)
        }
        // Only the account that is still active can decrypt its own slot.
        guard nostrService.activeHexPubkey == account else { return .unknown }
        let read: NWCBackup.Read
        if usesRemoteSigner, !askSigner {
            read = .notTried
        } else if let plaintext = try? await decryptFromSelf(event.content, me: account) {
            read = .plaintext(plaintext)
        } else {
            read = .failed
        }
        return NWCBackup.status(slot: slot, answeredAny: true, read: read)
    }

    /// Publishes `uri`, encrypted to the locked account's own key. Refuses if
    /// the active account is no longer `lock`'s at any step.
    static func save(_ uri: String, lockedTo lock: PostingAccount.Lock,
                     nostrService: NostrService) async throws {
        guard let plaintext = NWCBackup.plaintext(forSaving: uri) else { throw BackupError.notAWallet }
        guard !lock.hex.isEmpty, nostrService.activeHexPubkey == lock.hex else { throw BackupError.accountChanged }
        let encrypted: String
        do {
            encrypted = try await encryptToSelf(plaintext, me: lock.hex)
        } catch BackupError.noKey {
            throw BackupError.noKey
        } catch {
            throw BackupError.encryptFailed
        }
        // Never publish anything that is not ciphertext.
        guard NWCBackup.isCiphertext(encrypted) else { throw BackupError.encryptFailed }
        // Encrypted with whichever key was active: still the locked account?
        guard nostrService.activeHexPubkey == lock.hex else { throw BackupError.accountChanged }
        try await publish(content: encrypted, tags: NWCBackup.tags, lock: lock, nostrService: nostrService)
    }

    /// Takes the saved wallet off `lock`'s account: same slot, empty content.
    /// Needs no decryption, so it works from a device that can't read the slot.
    static func clear(lockedTo lock: PostingAccount.Lock, nostrService: NostrService) async throws {
        guard !lock.hex.isEmpty, nostrService.activeHexPubkey == lock.hex else { throw BackupError.accountChanged }
        try await publish(content: "", tags: NWCBackup.clearedTags, lock: lock, nostrService: nostrService)
    }

    private static func publish(content: String, tags: [[String]], lock: PostingAccount.Lock,
                                nostrService: NostrService) async throws {
        do {
            try await ModePostPublisher.publish(kind: NWCBackup.kind, content: content, tags: tags,
                                                nostrService: nostrService, lockedTo: lock)
        } catch ModePostPublisher.PublishError.accountChanged {
            throw BackupError.accountChanged
        }
    }

    // MARK: - NIP-44 to self (local key or the account's remote signer)

    static var usesRemoteSigner: Bool {
        ConfigService.shared.config.activeSigningMode() == "nip46"
    }

    private static func encryptToSelf(_ plaintext: String, me: String) async throws -> String {
        if usesRemoteSigner {
            return try await NIP44Service.encryptAsync(plaintext: plaintext, recipientPubkey: me)
        }
        guard let sk = try? DMService.shared.getActivePrivateKey() else { throw BackupError.noKey }
        return try NIP44Service.encrypt(plaintext: plaintext, recipientPubkey: me, senderPrivkey: sk)
    }

    private static func decryptFromSelf(_ ciphertext: String, me: String) async throws -> String {
        if usesRemoteSigner {
            return try await NIP44Service.decryptAsync(ciphertext: ciphertext, senderPubkey: me)
        }
        guard let sk = try? DMService.shared.getActivePrivateKey() else { throw BackupError.noKey }
        return try NIP44Service.decrypt(ciphertext: ciphertext, senderPubkey: me, recipientPrivkey: sk)
    }
}
