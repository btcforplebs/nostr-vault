import Foundation

enum NIP44Service {
    enum NIP44Error: Error, LocalizedError {
        case encryptionFailed
        case decryptionFailed
        case invalidKeyFormat

        var errorDescription: String? {
            switch self {
            case .encryptionFailed: return "Failed to encrypt payload"
            case .decryptionFailed: return "Failed to decrypt payload"
            case .invalidKeyFormat: return "Invalid key format"
            }
        }
    }

    /// Encrypts a plaintext payload using NIP-44 (ChaCha20 + HMAC-SHA256)
    /// - Parameters:
    ///   - plaintext: The content to encrypt
    ///   - recipientPubkey: The 32-byte hex public key of the receiver
    ///   - senderPrivkey: The 32-byte hex private key of the sender
    /// - Returns: Base64-encoded encrypted payload string
    static func encrypt(plaintext: String, recipientPubkey: String, senderPrivkey: String) throws -> String {
        guard let encryptedCStr = withCStrings([plaintext, recipientPubkey, senderPrivkey], { p in EncryptNIP44C(p[0], p[1], p[2]) }) else {
            throw NIP44Error.encryptionFailed
        }

        let result = String(cString: encryptedCStr)
        free(encryptedCStr)
        return result
    }

    /// Async encrypt that delegates to NIP-46 when in remote signing mode, otherwise uses local keys.
    static func encryptAsync(plaintext: String, recipientPubkey: String, senderPrivkey: String? = nil) async throws -> String {
        if await ConfigService.shared.config.activeSigningMode() == "nip46" {
            return try await NIP46Service.shared.nip44Encrypt(thirdPartyPubkey: recipientPubkey, plaintext: plaintext)
        } else {
            guard let sk = senderPrivkey else { throw NIP44Error.invalidKeyFormat }
            return try encrypt(plaintext: plaintext, recipientPubkey: recipientPubkey, senderPrivkey: sk)
        }
    }

    /// Async decrypt that delegates to NIP-46 when in remote signing mode, otherwise uses local keys.
    static func decryptAsync(ciphertext: String, senderPubkey: String, recipientPrivkey: String? = nil) async throws -> String {
        if await ConfigService.shared.config.activeSigningMode() == "nip46" {
            return try await NIP46Service.shared.nip44Decrypt(thirdPartyPubkey: senderPubkey, ciphertext: ciphertext)
        } else {
            guard let sk = recipientPrivkey else { throw NIP44Error.invalidKeyFormat }
            return try decrypt(ciphertext: ciphertext, senderPubkey: senderPubkey, recipientPrivkey: sk)
        }
    }

    /// Decrypts a NIP-44 payload
    /// - Parameters:
    ///   - ciphertext: The base64-encoded encrypted payload
    ///   - senderPubkey: The 32-byte hex public key of the sender
    ///   - recipientPrivkey: The 32-byte hex private key of the receiver
    /// - Returns: Decrypted plaintext string
    static func decrypt(ciphertext: String, senderPubkey: String, recipientPrivkey: String) throws -> String {
        guard let decryptedCStr = withCStrings([ciphertext, senderPubkey, recipientPrivkey], { p in DecryptNIP44C(p[0], p[1], p[2]) }) else {
            throw NIP44Error.decryptionFailed
        }

        let result = String(cString: decryptedCStr)
        free(decryptedCStr)
        return result
    }
}
