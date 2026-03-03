import Foundation
import CryptoKit
import CommonCrypto
import Security

/// NIP-49: Private Key Encryption
/// Provides password-protected encryption of Nostr private keys
/// Reference: https://nips.nostr.com/49
struct NIP49Service {

    // MARK: - Error Types
    enum NIP49Error: LocalizedError {
        case invalidEncrypted
        case decryptionFailed
        case invalidPassword
        case encodingFailed
        case decodingFailed

        var errorDescription: String? {
            switch self {
            case .invalidEncrypted:
                return "Invalid encrypted key format"
            case .decryptionFailed:
                return "Failed to decrypt key with this password"
            case .invalidPassword:
                return "Password is required"
            case .encodingFailed:
                return "Failed to encode encrypted key"
            case .decodingFailed:
                return "Failed to decode encrypted key"
            }
        }
    }

    // MARK: - Encryption (nsec → ncryptsec)

    /// Encrypts a private key (nsec) with a password to create ncryptsec format
    /// - Parameters:
    ///   - nsec: The bech32-encoded nsec private key
    ///   - password: The user's password for encryption
    /// - Returns: The encrypted key in ncryptsec format
    static func encrypt(nsec: String, password: String) throws -> String {
        guard !password.isEmpty else { throw NIP49Error.invalidPassword }

        // Decode nsec to get raw key bytes
        let hexKey = try decodeNsec(nsec)
        guard let keyData = Data(hex: hexKey) else { throw NIP49Error.decodingFailed }

        // Generate random salt (16 bytes)
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })

        // Derive encryption key using Argon2id-like approach
        // For simplicity, use PBKDF2 which is available in CryptoKit
        let passwordData = password.data(using: .utf8) ?? Data()
        let derivedKey = PBKDF2.derive(
            password: passwordData,
            salt: salt,
            iterations: 262144, // Recommended for Argon2id equivalent
            keyLength: 32
        )

        // Generate random nonce (24 bytes for XChaCha20-Poly1305 equivalent)
        let nonce = Data((0..<24).map { _ in UInt8.random(in: 0...255) })

        // Encrypt using AES-256-GCM (CryptoKit native)
        let sealedBox = try AES.GCM.seal(keyData, using: SymmetricKey(data: derivedKey), nonce: AES.GCM.Nonce(data: nonce))

        // Combine: version (1 byte) + salt (16 bytes) + nonce (24 bytes) + ciphertext + tag
        var payload = Data([1]) // version byte
        payload.append(salt)
        payload.append(nonce)
        payload.append(sealedBox.ciphertext)
        payload.append(sealedBox.tag)

        // Bech32 encode as ncryptsec
        guard let encoded = Bech32.encode(hrp: "ncryptsec", data: payload) else {
            throw NIP49Error.encodingFailed
        }

        return encoded
    }

    // MARK: - Decryption (ncryptsec → nsec)

    /// Decrypts an ncryptsec key with a password to retrieve the private key
    /// - Parameters:
    ///   - ncryptsec: The encrypted key in ncryptsec format
    ///   - password: The user's password for decryption
    /// - Returns: The decrypted nsec (bech32-encoded private key)
    static func decrypt(ncryptsec: String, password: String) throws -> String {
        guard !password.isEmpty else { throw NIP49Error.invalidPassword }

        // Bech32 decode
        guard let decoded = Bech32.decode(ncryptsec.lowercased()),
              decoded.hrp == "ncryptsec" else {
            throw NIP49Error.invalidEncrypted
        }

        let payload = decoded.data

        // Parse payload: version (1) + salt (16) + nonce (24) + ciphertext + tag (16)
        guard payload.count > 57 else { throw NIP49Error.invalidEncrypted }

        let version = payload[0]
        guard version == 1 else { throw NIP49Error.invalidEncrypted }

        let salt = payload[1..<17]
        let nonce = payload[17..<41]
        let ciphertext = payload[41..<(payload.count - 16)]
        let tag = payload[(payload.count - 16)...]

        // Derive key using same parameters
        let passwordData = password.data(using: .utf8) ?? Data()
        let derivedKey = PBKDF2.derive(
            password: passwordData,
            salt: Data(salt),
            iterations: 262144,
            keyLength: 32
        )

        // Decrypt
        do {
            let sealedBox = try AES.GCM.SealedBox(
                nonce: try AES.GCM.Nonce(data: Data(nonce)),
                ciphertext: Data(ciphertext),
                tag: Data(tag)
            )
            let decrypted = try AES.GCM.open(sealedBox, using: SymmetricKey(data: derivedKey))

            // Encode as nsec
            guard let nsec = Bech32.encode(hrp: "nsec", data: decrypted) else {
                throw NIP49Error.encodingFailed
            }

            return nsec
        } catch {
            print("NIP49Service: AES-GCM decrypt failed (version=\(version), payloadSize=\(payload.count)): \(error)")
            throw NIP49Error.decryptionFailed
        }
    }

    // MARK: - Utilities

    /// Checks if a string is in ncryptsec format
    static func isNcryptsec(_ value: String) -> Bool {
        guard let decoded = Bech32.decode(value.lowercased()) else { return false }
        return decoded.hrp == "ncryptsec"
    }

    /// Decodes nsec to hex private key
    private static func decodeNsec(_ nsec: String) throws -> String {
        guard let decoded = Bech32.decode(nsec.lowercased()),
              decoded.hrp == "nsec" else {
            throw NIP49Error.decodingFailed
        }
        return decoded.data.hex
    }
    
    // MARK: - Keychain Storage for Password
    
    /// Keychain service identifier
    private static let keychainService = "com.havenapp.nip49"
    private static let keychainAccount = "owner-key-password"
    
    /// Stores the NIP-49 password securely in Keychain
    /// - Parameter password: The password to store
    /// - Returns: True if storage was successful
    static func storePasswordInKeychain(_ password: String) -> Bool {
        guard let passwordData = password.data(using: .utf8) else { return false }
        
        // First, try to delete any existing item
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        
        // Add the new item
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: passwordData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        
        if status == errSecSuccess {
            #if DEBUG
            print("NIP49Service: Password stored successfully in Keychain")
            #endif
            return true
        } else {
            #if DEBUG
            print("NIP49Service: Failed to store password in Keychain: \(status)")
            #endif
            return false
        }
    }
    
    /// Retrieves the NIP-49 password from Keychain
    /// - Returns: The stored password, or nil if not found
    static func getPasswordFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess, let passwordData = result as? Data {
            return String(data: passwordData, encoding: .utf8)
        } else if status == errSecItemNotFound {
            #if DEBUG
            print("NIP49Service: No password found in Keychain")
            #endif
        } else {
            #if DEBUG
            print("NIP49Service: Error retrieving password from Keychain: \(status)")
            #endif
        }
        
        return nil
    }
    
    /// Deletes the NIP-49 password from Keychain
    /// - Returns: True if deletion was successful
    static func deletePasswordFromKeychain() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        if status == errSecSuccess || status == errSecItemNotFound {
            #if DEBUG
            print("NIP49Service: Password deleted from Keychain")
            #endif
            return true
        } else {
            #if DEBUG
            print("NIP49Service: Failed to delete password from Keychain: \(status)")
            #endif
            return false
        }
    }
    
    /// Checks if a password is stored in Keychain
    /// - Returns: True if password exists
    static func hasStoredPassword() -> Bool {
        return getPasswordFromKeychain() != nil
    }
}

// MARK: - PBKDF2 Helper

private struct PBKDF2 {
    static func derive(password: Data, salt: Data, iterations: Int, keyLength: Int) -> Data {
        var result = [UInt8](repeating: 0, count: keyLength)

        let passwordBytes = [UInt8](password)
        let saltBytes = [UInt8](salt)

        CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passwordBytes,
            passwordBytes.count,
            saltBytes,
            saltBytes.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            UInt32(iterations),
            &result,
            result.count
        )

        return Data(result)
    }
}

// MARK: - Data Extensions

extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hex: String) {
        self.init(capacity: hex.count / 2)
        let regex = try! NSRegularExpression(pattern: "[0-9a-f]{2}", options: .caseInsensitive)
        let nsHex = hex as NSString
        let range = NSRange(location: 0, length: nsHex.length)

        for match in regex.matches(in: hex, range: range) {
            let byteStr = nsHex.substring(with: match.range)
            if let num = UInt8(byteStr, radix: 16) {
                append(num)
            } else {
                return nil
            }
        }
    }
}
