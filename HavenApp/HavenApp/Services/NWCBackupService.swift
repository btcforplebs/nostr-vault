import Foundation

/// Reads, saves and removes the wallet string kept on the active account
/// (see `NWCBackup` for the format). The string is only ever published NIP-44
/// encrypted to the account's own key, and never written to a log: errors here
/// carry no content.
@MainActor
enum NWCBackupService {
    struct Saved: Equatable {
        let uri: String
        let savedAt: Date
    }

    enum BackupError: LocalizedError {
        case noKey
        case notAWallet
        case encryptFailed

        var errorDescription: String? {
            switch self {
            case .noKey: return "This account has no key on this device to encrypt with."
            case .notAWallet: return "That isn't a nostr+walletconnect:// link."
            case .encryptFailed: return "Couldn't encrypt the wallet. Nothing was saved."
            }
        }
    }

    /// The wallet saved on the active account, or nil when there is none, it
    /// was removed, or this device can't decrypt it (no key, signer refused).
    static func fetchSaved(nostrService: NostrService) async -> Saved? {
        let me = nostrService.activeHexPubkey
        guard !me.isEmpty else { return nil }
        let config = ConfigService.shared.config
        guard let event = await nostrService.fetchNewestReplaceable(
            kind: NWCBackup.kind, for: me, alsoAsk: config.readRelays, dTag: NWCBackup.dTag
        ), NWCBackup.isBackup(kind: event.kind, tags: event.tags),
           !NWCBackup.isCleared(content: event.content, tags: event.tags) else { return nil }
        guard let plaintext = try? await decryptFromSelf(event.content, me: me),
              let uri = NWCBackup.walletString(fromDecrypted: plaintext) else { return nil }
        return Saved(uri: uri, savedAt: Date(timeIntervalSince1970: TimeInterval(event.created_at)))
    }

    /// Publishes `uri`, encrypted to the active account's own key.
    static func save(_ uri: String, nostrService: NostrService) async throws {
        guard let plaintext = NWCBackup.plaintext(forSaving: uri) else { throw BackupError.notAWallet }
        let me = nostrService.activeHexPubkey
        guard !me.isEmpty else { throw BackupError.noKey }
        let encrypted: String
        do {
            encrypted = try await encryptToSelf(plaintext, me: me)
        } catch BackupError.noKey {
            throw BackupError.noKey
        } catch {
            throw BackupError.encryptFailed
        }
        // Never publish anything that is not ciphertext.
        guard !encrypted.isEmpty, !encrypted.lowercased().contains("walletconnect") else {
            throw BackupError.encryptFailed
        }
        try await ModePostPublisher.publish(kind: NWCBackup.kind, content: encrypted,
                                            tags: NWCBackup.tags, nostrService: nostrService)
    }

    /// Takes the saved wallet off the account: same slot, empty content.
    static func clear(nostrService: NostrService) async throws {
        try await ModePostPublisher.publish(kind: NWCBackup.kind, content: "",
                                            tags: NWCBackup.clearedTags, nostrService: nostrService)
    }

    // MARK: - NIP-44 to self (local key or the account's remote signer)

    private static func encryptToSelf(_ plaintext: String, me: String) async throws -> String {
        if ConfigService.shared.config.activeSigningMode() == "nip46" {
            return try await NIP44Service.encryptAsync(plaintext: plaintext, recipientPubkey: me)
        }
        guard let sk = try? DMService.shared.getActivePrivateKey() else { throw BackupError.noKey }
        return try NIP44Service.encrypt(plaintext: plaintext, recipientPubkey: me, senderPrivkey: sk)
    }

    private static func decryptFromSelf(_ ciphertext: String, me: String) async throws -> String {
        if ConfigService.shared.config.activeSigningMode() == "nip46" {
            return try await NIP44Service.decryptAsync(ciphertext: ciphertext, senderPubkey: me)
        }
        guard let sk = try? DMService.shared.getActivePrivateKey() else { throw BackupError.noKey }
        return try NIP44Service.decrypt(ciphertext: ciphertext, senderPubkey: me, recipientPrivkey: sk)
    }
}
