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
    ///   - rumorPTags: The p-tags for the rumor (actual conversation participants)
    ///   - giftWrapRecipient: The pubkey to deliver the gift wrap to (may differ from rumor p-tags for self-copies)
    ///   - senderHexPrivkey: Sender's hex private key
    ///   - senderHexPubkey: Sender's hex public key
    /// - Returns: A fully signed kind 1059 gift-wrap event
    static func createGiftWrap(
        content: String,
        rumorPTags: [[String]],
        giftWrapRecipient: String,
        senderHexPrivkey: String,
        senderHexPubkey: String
    ) throws -> NostrEvent {
        // Step 1: Create rumor (kind 14, unsigned)
        let rumorTimestamp = Int64(Date().timeIntervalSince1970)
        let rumorTags = rumorPTags

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

        // Step 2: Create seal (kind 13) - encrypt rumor with sender->gift wrap recipient
        let sealTimestamp = Int64(Date().addingTimeInterval(Double.random(in: -172800...0)).timeIntervalSince1970)
        let encryptedRumor = try NIP44Service.encrypt(
            plaintext: rumorJSON,
            recipientPubkey: giftWrapRecipient,
            senderPrivkey: senderHexPrivkey
        )

        // Build seal event structure (kind 13)
        let sealEventJSON = try buildSealEventJSON(
            senderPubkey: senderHexPubkey,
            encryptedContent: encryptedRumor,
            timestamp: sealTimestamp
        )

        // Sign seal with sender's key to get the complete seal event
        guard let sealEventCStr = withCStrings([sealEventJSON, senderHexPrivkey], { p in SignEventC(p[0], p[1]) }) else {
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

        // Step 4: Create gift wrap (kind 1059) - encrypt seal with ephemeral->gift wrap recipient
        let giftWrapTimestamp = Int64(Date().addingTimeInterval(Double.random(in: -172800...0)).timeIntervalSince1970)

        // Encrypt seal JSON with ephemeral key
        guard let sealData = try? JSONEncoder().encode(sealEvent),
              let sealJSONForEncryption = String(data: sealData, encoding: .utf8) else {
            throw NIP17Error.sealCreationFailed
        }

        let encryptedSeal = try NIP44Service.encrypt(
            plaintext: sealJSONForEncryption,
            recipientPubkey: giftWrapRecipient,
            senderPrivkey: ephemeralSk
        )

        // Build gift wrap event structure (kind 1059)
        let giftWrapEventJSON = try buildGiftWrapEventJSON(
            ephemeralPubkey: ephemeralPk,
            encryptedContent: encryptedSeal,
            recipientPubkey: giftWrapRecipient,
            timestamp: giftWrapTimestamp
        )

        // Mine PoW + sign gift wrap with ephemeral key
        let powSnap = PowPreferences.snapshot()
        let dmDiff = powSnap.dmEnabled ? powSnap.dmDifficulty : 0
        guard let giftWrapCStr = withCStrings([giftWrapEventJSON, ephemeralSk], { p in MineAndSignEventC(p[0], p[1], Int32(dmDiff), Int32(10_000_000)) }) else {
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

    // MARK: - Async Gift Wrap Creation (NIP-46 compatible)

    /// Async variant of createGiftWrap that supports NIP-46 remote signing.
    /// When in NIP-46 mode: seal encrypt+sign goes through the signer; gift wrap uses local ephemeral key.
    /// When in local mode: delegates to the synchronous createGiftWrap.
    static func createGiftWrapAsync(
        content: String,
        rumorPTags: [[String]],
        giftWrapRecipient: String,
        senderHexPrivkey: String?,
        senderHexPubkey: String
    ) async throws -> NostrEvent {
        let isNIP46 = await ConfigService.shared.config.activeSigningMode() == "nip46"

        if !isNIP46 {
            guard let sk = senderHexPrivkey else { throw NIP17Error.eventSigningFailed }
            return try createGiftWrap(
                content: content, rumorPTags: rumorPTags, giftWrapRecipient: giftWrapRecipient,
                senderHexPrivkey: sk, senderHexPubkey: senderHexPubkey
            )
        }

        // Step 1: Create rumor (kind 14, unsigned) -- same as sync version
        let rumorTimestamp = Int64(Date().timeIntervalSince1970)
        var rumor = DMRumor(id: "", pubkey: senderHexPubkey, created_at: rumorTimestamp, kind: 14, tags: rumorPTags, content: content)
        rumor.id = try computeEventID(pubkey: rumor.pubkey, createdAt: rumor.created_at, kind: rumor.kind, tags: rumor.tags, content: rumor.content)

        guard let rumorJSON = try encodeToJSON(rumor) else { throw NIP17Error.rumorCreationFailed }

        // Step 2: Encrypt rumor via NIP-46 nip44_encrypt
        let sealTimestamp = Int64(Date().addingTimeInterval(Double.random(in: -172800...0)).timeIntervalSince1970)
        let encryptedRumor = try await NIP46Service.shared.nip44Encrypt(thirdPartyPubkey: giftWrapRecipient, plaintext: rumorJSON)

        // Build seal event JSON and sign via NIP-46 sign_event
        let sealEventJSON = try buildSealEventJSON(senderPubkey: senderHexPubkey, encryptedContent: encryptedRumor, timestamp: sealTimestamp)
        let signedSealStr = try await NIP46Service.shared.signEvent(eventJSON: sealEventJSON)

        guard let sealEventData = signedSealStr.data(using: .utf8),
              let sealEvent = try? JSONDecoder().decode(NostrEvent.self, from: sealEventData) else {
            throw NIP17Error.sealCreationFailed
        }

        // Step 3: Generate ephemeral keypair -- ALWAYS LOCAL
        guard let keyPairCStr = GenerateKeyPairC() else { throw NIP17Error.ephemeralKeyFailed }
        let keyPairStr = String(cString: keyPairCStr)
        free(keyPairCStr)
        let parts = keyPairStr.split(separator: ":")
        guard parts.count == 2 else { throw NIP17Error.ephemeralKeyFailed }
        let ephemeralSk = String(parts[0])
        let ephemeralPk = String(parts[1])

        // Step 4: Create gift wrap (kind 1059) -- ALWAYS LOCAL (ephemeral key)
        let giftWrapTimestamp = Int64(Date().addingTimeInterval(Double.random(in: -172800...0)).timeIntervalSince1970)

        guard let sealData = try? JSONEncoder().encode(sealEvent),
              let sealJSONForEncryption = String(data: sealData, encoding: .utf8) else {
            throw NIP17Error.sealCreationFailed
        }

        let encryptedSeal = try NIP44Service.encrypt(plaintext: sealJSONForEncryption, recipientPubkey: giftWrapRecipient, senderPrivkey: ephemeralSk)
        let giftWrapEventJSON = try buildGiftWrapEventJSON(ephemeralPubkey: ephemeralPk, encryptedContent: encryptedSeal, recipientPubkey: giftWrapRecipient, timestamp: giftWrapTimestamp)

        // Mine PoW + sign gift wrap with ephemeral key
        let powSnap = PowPreferences.snapshot()
        let dmDiff = powSnap.dmEnabled ? powSnap.dmDifficulty : 0
        guard let giftWrapCStr = withCStrings([giftWrapEventJSON, ephemeralSk], { p in MineAndSignEventC(p[0], p[1], Int32(dmDiff), Int32(10_000_000)) }) else { throw NIP17Error.eventSigningFailed }

        let giftWrapStr = String(cString: giftWrapCStr)
        free(giftWrapCStr)

        guard let giftWrapData = giftWrapStr.data(using: .utf8),
              let giftWrap = try? JSONDecoder().decode(NostrEvent.self, from: giftWrapData) else {
            throw NIP17Error.giftWrapCreationFailed
        }

        return giftWrap
    }

    // MARK: - Async Gift Wrap Unwrapping (NIP-46 compatible)

    /// Async variant of unwrapGiftWrap that supports NIP-46 remote decryption.
    static func unwrapGiftWrapAsync(
        _ event: NostrEvent,
        recipientPrivkey: String?
    ) async throws -> (senderPubkey: String, content: String, timestamp: Date, rumorTags: [[String]]) {
        let isNIP46 = await ConfigService.shared.config.activeSigningMode() == "nip46"

        if !isNIP46 {
            guard let sk = recipientPrivkey else { throw NIP17Error.decryptionFailed }
            return try unwrapGiftWrap(event, recipientPrivkey: sk)
        }

        guard event.kind == 1059 else { throw NIP17Error.invalidGiftWrap }

        // Step 1: Decrypt gift wrap via NIP-46 nip44_decrypt
        let decryptedSealJSON = try await NIP46Service.shared.nip44Decrypt(thirdPartyPubkey: event.pubkey, ciphertext: event.content)

        // Step 2: Parse seal
        guard let sealData = decryptedSealJSON.data(using: .utf8),
              let sealEvent = try? JSONDecoder().decode(NostrEvent.self, from: sealData) else {
            throw NIP17Error.decryptionFailed
        }
        guard sealEvent.kind == 13 else { throw NIP17Error.invalidGiftWrap }

        // Step 3: Decrypt seal via NIP-46 nip44_decrypt
        let decryptedRumorJSON = try await NIP46Service.shared.nip44Decrypt(thirdPartyPubkey: sealEvent.pubkey, ciphertext: sealEvent.content)

        // Step 4: Parse rumor
        guard let rumorData = decryptedRumorJSON.data(using: .utf8),
              let rumor = try? JSONDecoder().decode(DMRumor.self, from: rumorData) else {
            throw NIP17Error.decryptionFailed
        }
        guard rumor.kind == 14 else { throw NIP17Error.invalidGiftWrap }

        // Step 5: Verify seal pubkey matches rumor pubkey
        guard sealEvent.pubkey == rumor.pubkey else {
            print("NIP-17: Seal pubkey (\(sealEvent.pubkey.prefix(8))) does not match rumor pubkey (\(rumor.pubkey.prefix(8))) — possible impersonation")
            throw NIP17Error.invalidGiftWrap
        }

        return (
            senderPubkey: rumor.pubkey,
            content: rumor.content,
            timestamp: Date(timeIntervalSince1970: TimeInterval(rumor.created_at)),
            rumorTags: rumor.tags
        )
    }

    // MARK: - Gift Wrap Unwrapping

    /// Unwraps a received NIP-17 gift-wrapped event
    /// - Parameters:
    ///   - event: The kind 1059 gift-wrap event
    ///   - recipientPrivkey: Recipient's hex private key (for decryption)
    /// - Returns: Tuple containing (sender pubkey, plaintext content, timestamp, rumor tags)
    static func unwrapGiftWrap(
        _ event: NostrEvent,
        recipientPrivkey: String
    ) throws -> (senderPubkey: String, content: String, timestamp: Date, rumorTags: [[String]]) {
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

        // Step 5: Verify seal pubkey matches rumor pubkey (prevents sender impersonation)
        guard sealEvent.pubkey == rumor.pubkey else {
            print("⚠️ NIP-17: Seal pubkey (\(sealEvent.pubkey.prefix(8))) does not match rumor pubkey (\(rumor.pubkey.prefix(8))) — possible impersonation attempt")
            throw NIP17Error.invalidGiftWrap
        }

        return (
            senderPubkey: rumor.pubkey,
            content: rumor.content,
            timestamp: Date(timeIntervalSince1970: TimeInterval(rumor.created_at)),
            rumorTags: rumor.tags
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
