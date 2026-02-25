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
        guard let encryptedCStr = EncryptNIP04C(
            UnsafeMutablePointer(mutating: (plaintext as NSString).utf8String),
            UnsafeMutablePointer(mutating: (remotePubkey as NSString).utf8String),
            UnsafeMutablePointer(mutating: (localPrivkey as NSString).utf8String)
        ) else {
            throw NIP04Error.encryptionFailed
        }
        
        let result = String(cString: encryptedCStr)
        free(encryptedCStr)
        return result
    }
    
    /// Decrypts a NIP-04 payload
    /// - Parameters:
    ///   - ciphertext: The base64-encoded encrypted payload (including IV)
    ///   - remotePubkey: The 32-byte hex public key of the sender
    ///   - localPrivkey: The 32-byte hex private key of the receiver
    /// - Returns: Decrypted plaintext string
    static func decrypt(ciphertext: String, remotePubkey: String, localPrivkey: String) throws -> String {
        guard let decryptedCStr = DecryptNIP04C(
            UnsafeMutablePointer(mutating: (ciphertext as NSString).utf8String),
            UnsafeMutablePointer(mutating: (remotePubkey as NSString).utf8String),
            UnsafeMutablePointer(mutating: (localPrivkey as NSString).utf8String)
        ) else {
            throw NIP04Error.decryptionFailed
        }
        
        let result = String(cString: decryptedCStr)
        free(decryptedCStr)
        return result
    }
}
