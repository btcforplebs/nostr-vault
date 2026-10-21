import Foundation

enum NIP04Service {
    enum NIP04Error: Error, LocalizedError {
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
    
    /// Encrypts a plaintext payload using NIP-04 (AES-256-CBC)
    /// - Parameters:
    ///   - plaintext: The content to encrypt
    ///   - remotePubkey: The 32-byte hex public key of the receiver
    ///   - localPrivkey: The 32-byte hex private key of the sender
    /// - Returns: Base64-encoded encrypted payload string (including IV)
    static func encrypt(plaintext: String, remotePubkey: String, localPrivkey: String) throws -> String {
        guard let encryptedCStr = withCStrings([plaintext, remotePubkey, localPrivkey], { p in EncryptNIP04C(p[0], p[1], p[2]) }) else {
            throw NIP04Error.encryptionFailed
        }
        
        let result = String(cString: encryptedCStr)
        free(encryptedCStr)
        return result
    }
    
    /// Async encrypt that delegates to NIP-46 when in remote signing mode, otherwise uses local keys.
    static func encryptAsync(plaintext: String, remotePubkey: String, localPrivkey: String? = nil) async throws -> String {
        if await ConfigService.shared.config.activeSigningMode() == "nip46" {
            return try await NIP46Service.shared.nip04Encrypt(thirdPartyPubkey: remotePubkey, plaintext: plaintext)
        } else {
            guard let sk = localPrivkey else { throw NIP04Error.invalidKeyFormat }
            return try encrypt(plaintext: plaintext, remotePubkey: remotePubkey, localPrivkey: sk)
        }
    }

    /// Async decrypt that delegates to NIP-46 when in remote signing mode, otherwise uses local keys.
    static func decryptAsync(ciphertext: String, remotePubkey: String, localPrivkey: String? = nil) async throws -> String {
        if await ConfigService.shared.config.activeSigningMode() == "nip46" {
            return try await NIP46Service.shared.nip04Decrypt(thirdPartyPubkey: remotePubkey, ciphertext: ciphertext)
        } else {
            guard let sk = localPrivkey else { throw NIP04Error.invalidKeyFormat }
            return try decrypt(ciphertext: ciphertext, remotePubkey: remotePubkey, localPrivkey: sk)
        }
    }

    /// Decrypts a NIP-04 payload
    /// - Parameters:
    ///   - ciphertext: The base64-encoded encrypted payload (including IV)
    ///   - remotePubkey: The 32-byte hex public key of the sender
    ///   - localPrivkey: The 32-byte hex private key of the receiver
    /// - Returns: Decrypted plaintext string
    static func decrypt(ciphertext: String, remotePubkey: String, localPrivkey: String) throws -> String {
        guard let decryptedCStr = withCStrings([ciphertext, remotePubkey, localPrivkey], { p in DecryptNIP04C(p[0], p[1], p[2]) }) else {
            throw NIP04Error.decryptionFailed
        }
        
        let result = String(cString: decryptedCStr)
        free(decryptedCStr)
        return result
    }
}
