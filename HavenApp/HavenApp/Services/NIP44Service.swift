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
        guard let encryptedCStr = EncryptNIP44C(
            UnsafeMutablePointer(mutating: (plaintext as NSString).utf8String),
            UnsafeMutablePointer(mutating: (recipientPubkey as NSString).utf8String),
            UnsafeMutablePointer(mutating: (senderPrivkey as NSString).utf8String)
        ) else {
            throw NIP44Error.encryptionFailed
        }

        let result = String(cString: encryptedCStr)
        free(encryptedCStr)
        return result
    }

    /// Decrypts a NIP-44 payload
    /// - Parameters:
    ///   - ciphertext: The base64-encoded encrypted payload
    ///   - senderPubkey: The 32-byte hex public key of the sender
    ///   - recipientPrivkey: The 32-byte hex private key of the receiver
    /// - Returns: Decrypted plaintext string
    static func decrypt(ciphertext: String, senderPubkey: String, recipientPrivkey: String) throws -> String {
        guard let decryptedCStr = DecryptNIP44C(
            UnsafeMutablePointer(mutating: (ciphertext as NSString).utf8String),
            UnsafeMutablePointer(mutating: (senderPubkey as NSString).utf8String),
            UnsafeMutablePointer(mutating: (recipientPrivkey as NSString).utf8String)
        ) else {
            throw NIP44Error.decryptionFailed
        }

        let result = String(cString: decryptedCStr)
        free(decryptedCStr)
        return result
    }
}
