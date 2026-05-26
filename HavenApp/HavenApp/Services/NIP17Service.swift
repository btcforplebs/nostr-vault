import Foundation
import CryptoKit

// DMRumor represents a kind 14 (unsigned) message in the DM flow
struct DMRumor: Codable {
    var id: String
    let pubkey: String
    let created_at: Int64
    let kind: Int  // Always 14
    let tags: [[String]]
    let content: String

    enum CodingKeys: String, CodingKey {
        case id, pubkey, created_at, kind, tags, content
    }
}

enum NIP17Service {
    enum NIP17Error: Error, LocalizedError {
        case rumorCreationFailed
        case sealCreationFailed
        case giftWrapCreationFailed
        case ephemeralKeyFailed
        case eventSigningFailed
        case invalidGiftWrap
        case decryptionFailed
        case invalidJSON

        var errorDescription: String? {
            switch self {
            case .rumorCreationFailed: return "Failed to create rumor"
            case .sealCreationFailed: return "Failed to seal message"
            case .giftWrapCreationFailed: return "Failed to create gift wrap"
            case .ephemeralKeyFailed: return "Failed to generate ephemeral key"
            case .eventSigningFailed: return "Failed to sign event"
            case .invalidGiftWrap: return "Invalid gift wrap event"
            case .decryptionFailed: return "Failed to decrypt message"
            case .invalidJSON: return "Invalid JSON data"
            }
        }
    }

    // MARK: - Gift Wrap Creation

    /// Creates a NIP-17 gift-wrapped event ready to publish
    /// - Parameters:
    ///   - content: The plaintext message content
    ///   - recipientHexPubkey: Recipient's hex public key
    ///   - senderHexPrivkey: Sender's hex private key
    ///   - senderHexPubkey: Sender's hex public key
    /// - Returns: A fully signed kind 1059 gift-wrap event
    static func createGiftWrap(
        content: String,
        recipientHexPubkey: String,
        senderHexPrivkey: String,
        senderHexPubkey: String
    ) throws -> NostrEvent {
        // Step 1: Create rumor (kind 14, unsigned)
        let rumorTimestamp = Int64(Date().timeIntervalSince1970)
        let rumorTags = [["p", recipientHexPubkey]]

        var rumor = DMRumor(
            id: "",  // Will be computed
            pubkey: senderHexPubkey,
            created_at: rumorTimestamp,
            kind: 14,
            tags: rumorTags,
            content: content
        )

        // Compute rumor ID (SHA256 of canonical JSON serialization)
        rumor.id = try computeEventID(
            pubkey: rumor.pubkey,
            createdAt: rumor.created_at,
            kind: rumor.kind,
            tags: rumor.tags,
            content: rumor.content
        )

        // Serialize rumor to JSON (for encryption)
        guard let rumorJSON = try encodeToJSON(rumor) else {
            throw NIP17Error.rumorCreationFailed
        }

        // Step 2: Create seal (kind 13) - encrypt rumor with sender->recipient
        let sealTimestamp = Int64(Date().addingTimeInterval(Double.random(in: -172800...0)).timeIntervalSince1970)
        let encryptedRumor = try NIP44Service.encrypt(
            plaintext: rumorJSON,
            recipientPubkey: recipientHexPubkey,
            senderPrivkey: senderHexPrivkey
        )

        // Build seal event structure (kind 13)
        let sealEventJSON = try buildSealEventJSON(
            senderPubkey: senderHexPubkey,
            encryptedContent: encryptedRumor,
            timestamp: sealTimestamp
        )

        // Sign seal with sender's key to get the complete seal event
        guard let sealEventCStr = SignEventC(
            UnsafeMutablePointer(mutating: (sealEventJSON as NSString).utf8String),
            UnsafeMutablePointer(mutating: (senderHexPrivkey as NSString).utf8String)
        ) else {
            throw NIP17Service.NIP17Error.eventSigningFailed
        }

        let sealEventStr = String(cString: sealEventCStr)
        free(sealEventCStr)

        guard let sealEventData = sealEventStr.data(using: .utf8),
              let sealEvent = try? JSONDecoder().decode(NostrEvent.self, from: sealEventData) else {
            throw NIP17Service.NIP17Error.sealCreationFailed
        }

        // Step 3: Generate ephemeral keypair
        guard let keyPairCStr = GenerateKeyPairC() else {
            throw NIP17Error.ephemeralKeyFailed
        }

        let keyPairStr = String(cString: keyPairCStr)
        free(keyPairCStr)

        let parts = keyPairStr.split(separator: ":")
        guard parts.count == 2 else {
            throw NIP17Error.ephemeralKeyFailed
        }

        let ephemeralSk = String(parts[0])
        let ephemeralPk = String(parts[1])

        // Step 4: Create gift wrap (kind 1059) - encrypt seal with ephemeral->recipient
        let giftWrapTimestamp = Int64(Date().addingTimeInterval(Double.random(in: -172800...0)).timeIntervalSince1970)

        // Encrypt seal JSON with ephemeral key
        guard let sealData = try? JSONEncoder().encode(sealEvent),
              let sealJSONForEncryption = String(data: sealData, encoding: .utf8) else {
            throw NIP17Error.sealCreationFailed
        }

        let encryptedSeal = try NIP44Service.encrypt(
            plaintext: sealJSONForEncryption,
            recipientPubkey: recipientHexPubkey,
            senderPrivkey: ephemeralSk
        )

        // Build gift wrap event structure (kind 1059)
        let giftWrapEventJSON = try buildGiftWrapEventJSON(
            ephemeralPubkey: ephemeralPk,
            encryptedContent: encryptedSeal,
            recipientPubkey: recipientHexPubkey,
            timestamp: giftWrapTimestamp
        )

        // Sign gift wrap with ephemeral key
        guard let giftWrapCStr = SignEventC(
            UnsafeMutablePointer(mutating: (giftWrapEventJSON as NSString).utf8String),
            UnsafeMutablePointer(mutating: (ephemeralSk as NSString).utf8String)
        ) else {
            throw NIP17Service.NIP17Error.eventSigningFailed
        }

        let giftWrapStr = String(cString: giftWrapCStr)
        free(giftWrapCStr)

        guard let giftWrapData = giftWrapStr.data(using: .utf8),
              let giftWrap = try? JSONDecoder().decode(NostrEvent.self, from: giftWrapData) else {
            throw NIP17Error.giftWrapCreationFailed
        }

        return giftWrap
    }

    // MARK: - Gift Wrap Unwrapping

    /// Unwraps a received NIP-17 gift-wrapped event
    /// - Parameters:
    ///   - event: The kind 1059 gift-wrap event
    ///   - recipientPrivkey: Recipient's hex private key (for decryption)
    /// - Returns: Tuple containing (sender pubkey, plaintext content, timestamp)
    static func unwrapGiftWrap(
        _ event: NostrEvent,
        recipientPrivkey: String
    ) throws -> (senderPubkey: String, content: String, timestamp: Date) {
        guard event.kind == 1059 else {
            throw NIP17Error.invalidGiftWrap
        }

        // Step 1: Decrypt gift wrap using recipient_privkey + ephemeral_pubkey
        let decryptedSealJSON = try NIP44Service.decrypt(
            ciphertext: event.content,
            senderPubkey: event.pubkey,  // ephemeral public key
            recipientPrivkey: recipientPrivkey
        )

        // Step 2: Parse seal event from decrypted JSON
        guard let sealData = decryptedSealJSON.data(using: .utf8),
              let sealEvent = try? JSONDecoder().decode(NostrEvent.self, from: sealData) else {
            throw NIP17Error.decryptionFailed
        }

        guard sealEvent.kind == 13 else {
            throw NIP17Error.invalidGiftWrap
        }

        // Step 3: Decrypt seal using recipient_privkey + sender_pubkey
        let decryptedRumorJSON = try NIP44Service.decrypt(
            ciphertext: sealEvent.content,
            senderPubkey: sealEvent.pubkey,  // sender public key
            recipientPrivkey: recipientPrivkey
        )

        // Step 4: Parse rumor from decrypted JSON
        guard let rumorData = decryptedRumorJSON.data(using: .utf8),
              let rumor = try? JSONDecoder().decode(DMRumor.self, from: rumorData) else {
            throw NIP17Error.decryptionFailed
        }

        guard rumor.kind == 14 else {
            throw NIP17Error.invalidGiftWrap
        }

        return (
            senderPubkey: rumor.pubkey,
            content: rumor.content,
            timestamp: Date(timeIntervalSince1970: TimeInterval(rumor.created_at))
        )
    }

    // MARK: - Helpers

    private static func computeEventID(
        pubkey: String,
        createdAt: Int64,
        kind: Int,
        tags: [[String]],
        content: String
    ) throws -> String {
        let eventArray: [Any] = [0, pubkey, createdAt, kind, tags, content]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: eventArray),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw NIP17Error.invalidJSON
        }

        let digest = SHA256.hash(data: Data(jsonString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func encodeToJSON<T: Encodable>(_ value: T) throws -> String? {
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8)
    }

    private static func buildSealEventJSON(
        senderPubkey: String,
        encryptedContent: String,
        timestamp: Int64
    ) throws -> String {
        let eventDict: [String: Any] = [
            "content": encryptedContent,
            "created_at": timestamp,
            "kind": 13,
            "pubkey": senderPubkey,
            "tags": [],
            "sig": ""  // Will be signed
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: eventDict),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw NIP17Error.sealCreationFailed
        }

        return jsonString
    }

    private static func buildGiftWrapEventJSON(
        ephemeralPubkey: String,
        encryptedContent: String,
        recipientPubkey: String,
        timestamp: Int64
    ) throws -> String {
        let tags = [["p", recipientPubkey]]
        let eventDict: [String: Any] = [
            "content": encryptedContent,
            "created_at": timestamp,
            "kind": 1059,
            "pubkey": ephemeralPubkey,
            "tags": tags,
            "sig": ""  // Will be signed
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: eventDict),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw NIP17Error.giftWrapCreationFailed
        }

        return jsonString
    }
}
