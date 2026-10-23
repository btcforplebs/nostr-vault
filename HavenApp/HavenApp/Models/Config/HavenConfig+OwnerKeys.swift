import Foundation

extension HavenConfig {
    /// Whether this config holds any private key: the owner's (encrypted or
    /// legacy plaintext) or a stored account credential. config.json.bak is
    /// never replaced by a config without one while it has one itself.
    var hasKeyMaterial: Bool {
        !ownerNcryptsec.isEmpty || !ownerNsec.isEmpty || !accountCredentials.isEmpty
    }

    /// Returns the hex private key decoded from ownerNsec (fallback for old plaintext keys)
    var ownerHexKey: String? {
        Self.hexKey(fromNsec: ownerNsec)
    }

    /// Decrypts the ncryptsec with a password to get the plaintext nsec
    /// - Parameter password: The password to decrypt the key
    /// - Returns: The plaintext nsec if successfully decrypted
    /// - Throws: NIP49Service.NIP49Error if decryption fails
    func getDecryptedNsec(password: String) throws -> String {
        let clean = ownerNcryptsec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            // Fall back to plaintext nsec if no encrypted key exists (migration)
            return ownerNsec
        }
        return try NIP49Service.decrypt(ncryptsec: clean, password: password)
    }

    /// Encrypts an nsec and stores it as ownerNcryptsec
    /// - Parameters:
    ///   - nsec: The plaintext nsec to encrypt
    ///   - password: The password to use for encryption
    /// - Throws: NIP49Service.NIP49Error if encryption fails
    mutating func setEncryptedNsec(nsec: String, password: String) throws {
        ownerNcryptsec = try NIP49Service.encrypt(nsec: nsec, password: password)
        // Clear plaintext key for security
        self.ownerNsec = ""
    }

    /// Gets the hex key by decrypting ncryptsec with a password
    /// - Parameter password: The password to decrypt the key
    /// - Returns: The hex private key if decryption succeeds
    /// - Throws: NIP49Service.NIP49Error if decryption fails
    func getDecryptedHexKey(password: String) throws -> String {
        let nsec = try getDecryptedNsec(password: password)
        let clean = nsec.trimmingCharacters(in: .whitespacesAndNewlines)

        if let decoded = Bech32.decode(clean), decoded.hrp == "nsec" {
            return decoded.hexString
        }
        // Fallback for raw hex
        if clean.count == 64 && clean.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil {
            return clean
        }
        throw NIP49Service.NIP49Error.decodingFailed
    }
}

/// What `HavenConfig.encryptPlaintextOwnerKey` did with a plaintext `ownerNsec`.
enum PlaintextOwnerKeyMigration: Equatable {
    /// No plaintext key, or one that is not a key.
    case nothingToDo
    /// Encrypted into `ownerNcryptsec` and cleared. `newPassword` is the
    /// password it was encrypted with when there was none stored: the caller
    /// must have it in the keychain before it saves this config.
    case encrypted(newPassword: String?)
    /// `ownerNcryptsec` already held the same key: plaintext cleared.
    case cleared
    /// `ownerNcryptsec` holds a key the stored password cannot show to be the
    /// same one (no password, or a different key): left as it is, since the
    /// plaintext may be the only copy.
    case keptUnverified
    /// Encryption failed or did not decrypt back to the same key.
    case failed
}

extension HavenConfig {
    /// The owner's key must not sit in config.json as plaintext: the file is
    /// in an encrypted device backup, and `ownerHexKey` still signs with it.
    /// Encrypts it into `ownerNcryptsec` with the stored password (or a new
    /// one from `newPassword` when none is stored) and clears it, only once
    /// the result decrypts back to the same key.
    mutating func encryptPlaintextOwnerKey(
        storedPassword: String?,
        newPassword: () -> String,
        encrypt: (_ nsec: String, _ password: String) throws -> String,
        decrypt: (_ ncryptsec: String, _ password: String) throws -> String
    ) -> PlaintextOwnerKeyMigration {
        guard let hex = ownerHexKey else { return .nothingToDo }
        let plaintext = ownerNsec.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = ownerNcryptsec.trimmingCharacters(in: .whitespacesAndNewlines)

        if !existing.isEmpty {
            guard let password = storedPassword,
                  let nsec = try? decrypt(existing, password),
                  Self.hexKey(fromNsec: nsec) == hex else { return .keptUnverified }
            ownerNsec = ""
            return .cleared
        }

        let password = storedPassword ?? newPassword()
        guard let encrypted = try? encrypt(plaintext, password),
              let back = try? decrypt(encrypted, password),
              Self.hexKey(fromNsec: back) == hex else { return .failed }
        ownerNcryptsec = encrypted
        ownerNsec = ""
        return .encrypted(newPassword: storedPassword == nil ? password : nil)
    }

    /// The hex key in an nsec or 64-character hex string, or nil.
    static func hexKey(fromNsec nsec: String) -> String? {
        let clean = nsec.trimmingCharacters(in: .whitespacesAndNewlines)
        if let decoded = Bech32.decode(clean), decoded.hrp == "nsec" {
            return decoded.hexString
        }
        if clean.count == 64 && clean.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil {
            return clean
        }
        return nil
    }
}
