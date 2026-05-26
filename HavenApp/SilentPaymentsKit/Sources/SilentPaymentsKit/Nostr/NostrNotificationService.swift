// Sources/SilentPaymentsKit/Nostr/NostrNotificationService.swift
//
// Silent Payments via Nostr — NIP-17 encrypted DM notifications.
// Schema: https://delvingbitcoin.org/t/silent-payments-notifications-via-nostr/2203
//
// Alice (sender) sends a NIP-17 sealed DM to Bob's npub containing:
//   { "txid": "...", "tweak": "...", "blockhash": "..." }
//
// Bob (receiver) listens on his preferred relays and uses the notification
// to skip full-chain scanning.

import Foundation

// MARK: - Notification Service

public actor NostrNotificationService {

    private let relays: [URL]
    private var relayConnections: [String: WebSocketConnection] = [:]

    public init(relays: [URL]) {
        self.relays = relays
    }

    // MARK: - Sender: publish a payment notification

    /// Send a Silent Payment notification to the recipient via NIP-17 sealed DM.
    ///
    /// - Parameters:
    ///   - notification:   The payment notification payload.
    ///   - senderNsec:     Sender's 32-byte private key (used to sign the NIP-17 event).
    ///   - recipientNpub:  Recipient's 33-byte compressed public key (destination for the DM).
    ///   - relays:         Relays to publish on (use recipient's advertised relays when possible).
    public func sendNotification(
        _ notification: SilentPaymentNotification,
        senderNsec: Data,
        recipientNpub: Data
    ) async throws {

        let payload = try JSONEncoder().encode(notification)
        let payloadString = String(data: payload, encoding: .utf8)!

        // Build a NIP-17 sealed DM:
        // 1. Inner rumour event (kind 14, unsinged)
        // 2. Seal (kind 13, signed by sender, NIP-44 encrypted to recipient)
        // 3. Gift wrap (kind 1059, ephemeral key, NIP-44 encrypted to recipient)

        let sealedEvent = try buildGiftWrap(
            content: payloadString,
            senderPrivKey: senderNsec,
            recipientPubKey: recipientNpub
        )

        // Publish to all relays
        let eventJSON = try JSONEncoder().encode(sealedEvent)
        try await publishToRelays(eventJSON)
    }

    // MARK: - Receiver: subscribe to incoming notifications

    /// Subscribe to incoming Silent Payment notifications on the given relays.
    ///
    /// - Parameters:
    ///   - recipientNsec: Receiver's 32-byte private key (for decryption).
    ///   - since:         Only fetch events after this Unix timestamp (use last scan time).
    ///   - handler:       Called for each valid notification received.
    public func subscribeToNotifications(
        recipientNsec: Data,
        since: Int64 = 0,
        handler: @escaping (SilentPaymentNotification) async -> Void
    ) async throws {

        let recipientPub = try Secp256k1Helper.publicKey(from: recipientNsec)
        let xOnlyRecipient = Secp256k1Helper.xOnlyKey(recipientPub).hexString

        // NIP-17: subscribe to kind 1059 (gift wrap) addressed to our pubkey
        let filter = NostrFilter(
            kinds: [1059],
            ptags: [xOnlyRecipient],
            since: since > 0 ? Int(since) : nil
        )

        for relay in relays {
            Task {
                await subscribeOnRelay(
                    relay: relay,
                    filter: filter,
                    recipientNsec: recipientNsec,
                    handler: handler
                )
            }
        }
    }

    // MARK: - BIP-321 URI parsing
    // Parses: bitcoin:?sp1q...=&npub=npub1...&relays=wss://relay1,...

    public static func parseBIP321URI(_ uri: String) -> (
        silentPaymentAddress: String?,
        npub: String?,
        relays: [URL]
    ) {
        guard let components = URLComponents(string: uri) else {
            return (nil, nil, [])
        }
        let items = components.queryItems ?? []
        var spAddress: String?
        var npub: String?
        var relays: [URL] = []

        for item in items {
            if item.name.hasPrefix("sp1") {
                spAddress = item.name
            } else if item.name == "npub", let v = item.value {
                npub = v
            } else if item.name == "relays", let v = item.value {
                relays = v.components(separatedBy: ",")
                    .compactMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
            }
        }
        return (spAddress, npub, relays)
    }

    // MARK: - NIP-17 Gift Wrap construction

    private func buildGiftWrap(
        content: String,
        senderPrivKey: Data,
        recipientPubKey: Data
    ) throws -> NostrEvent {

        let senderPub = try Secp256k1Helper.publicKey(from: senderPrivKey)
        let recipientXOnly = Secp256k1Helper.xOnlyKey(recipientPubKey).hexString

        // Rumour (kind 14, unsigned)
        let rumour = NostrEvent(
            pubkey: Secp256k1Helper.xOnlyKey(senderPub).hexString,
            createdAt: Int(Date().timeIntervalSince1970),
            kind: 14,
            tags: [["p", recipientXOnly]],
            content: content
        )

        // Seal (kind 13): encrypt rumour to recipient, sign with sender key
        let rumourJSON = try JSONEncoder().encode(rumour)
        let rumourString = String(data: rumourJSON, encoding: .utf8)!
        let encryptedRumour = try NIP44.encrypt(
            plaintext: rumourString,
            senderPrivKey: senderPrivKey,
            recipientPubKey: recipientPubKey
        )
        var sealEvent = NostrEvent(
            pubkey: Secp256k1Helper.xOnlyKey(senderPub).hexString,
            createdAt: Int(Date().timeIntervalSince1970),
            kind: 13,
            tags: [],
            content: encryptedRumour
        )
        try sealEvent.sign(with: senderPrivKey)

        // Gift Wrap (kind 1059): encrypt seal with ephemeral key
        let ephemeralPriv = Data.randomBytes(count: 32)
        let ephemeralPub  = try Secp256k1Helper.publicKey(from: ephemeralPriv)
        let sealJSON   = try JSONEncoder().encode(sealEvent)
        let sealString = String(data: sealJSON, encoding: .utf8)!
        let encryptedSeal = try NIP44.encrypt(
            plaintext: sealString,
            senderPrivKey: ephemeralPriv,
            recipientPubKey: recipientPubKey
        )
        var wrapEvent = NostrEvent(
            pubkey: Secp256k1Helper.xOnlyKey(ephemeralPub).hexString,
            createdAt: Int(Date().timeIntervalSince1970),
            kind: 1059,
            tags: [["p", recipientXOnly]],
            content: encryptedSeal
        )
        try wrapEvent.sign(with: ephemeralPriv)
        return wrapEvent
    }

    // MARK: - Relay communication

    private func publishToRelays(_ eventJSON: Data) async throws {
        let message = "[\"EVENT\",\(String(data: eventJSON, encoding: .utf8)!)]"
        for relay in relays {
            // Use URLSession WebSocket task
            let session = URLSession.shared
            let task = session.webSocketTask(with: relay)
            task.resume()
            try await task.send(.string(message))
            task.cancel()
        }
    }

    private func subscribeOnRelay(
        relay: URL,
        filter: NostrFilter,
        recipientNsec: Data,
        handler: @escaping (SilentPaymentNotification) async -> Void
    ) async {
        let session = URLSession.shared
        let task = session.webSocketTask(with: relay)
        task.resume()

        let subId = UUID().uuidString.prefix(8)
        let filterJSON = (try? JSONEncoder().encode(filter)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let req = "[\"REQ\",\"\(subId)\",\(filterJSON)]"
        try? await task.send(.string(req))

        // Listen for events
        while true {
            guard let message = try? await task.receive() else { break }
            if case .string(let text) = message {
                if let notification = try? parseGiftWrap(text, recipientNsec: recipientNsec) {
                    await handler(notification)
                }
            }
        }
    }

    private func parseGiftWrap(_ json: String, recipientNsec: Data) throws -> SilentPaymentNotification? {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
              arr.count >= 3,
              let type = arr[0] as? String, type == "EVENT",
              let eventDict = arr[2] as? [String: Any],
              let kind = eventDict["kind"] as? Int, kind == 1059,
              let wrapContent = eventDict["content"] as? String,
              let wrapPubHex  = eventDict["pubkey"] as? String
        else { return nil }

        let wrapPub = Data(hexString: wrapPubHex) ?? Data()
        let wrapPubCompressed = Data([0x02]) + wrapPub

        // Decrypt gift wrap → seal
        let sealJSON = try NIP44.decrypt(
            ciphertext: wrapContent,
            recipientPrivKey: recipientNsec,
            senderPubKey: wrapPubCompressed
        )
        guard let sealData = sealJSON.data(using: .utf8),
              let sealDict = try? JSONSerialization.jsonObject(with: sealData) as? [String: Any],
              let sealContent = sealDict["content"] as? String,
              let sealPubHex  = sealDict["pubkey"]  as? String
        else { return nil }

        let sealPubCompressed = Data([0x02]) + (Data(hexString: sealPubHex) ?? Data())

        // Decrypt seal → rumour
        let rumourJSON = try NIP44.decrypt(
            ciphertext: sealContent,
            recipientPrivKey: recipientNsec,
            senderPubKey: sealPubCompressed
        )
        guard let rumourData = rumourJSON.data(using: .utf8),
              let rumourDict = try? JSONSerialization.jsonObject(with: rumourData) as? [String: Any],
              let contentStr = rumourDict["content"] as? String,
              let contentData = contentStr.data(using: .utf8)
        else { return nil }

        return try? JSONDecoder().decode(SilentPaymentNotification.self, from: contentData)
    }
}

// MARK: - NIP-44 Encryption (v2 — ChaCha20 + HMAC-SHA256)
// Minimal implementation of NIP-44 v2 for sealed DMs.
// For production, use a fully audited NIP-44 library.

private enum NIP44 {

    static func encrypt(plaintext: String, senderPrivKey: Data, recipientPubKey: Data) throws -> String {
        let conversationKey = try conversationKey(senderPrivKey: senderPrivKey, recipientPubKey: recipientPubKey)
        let nonce = Data.randomBytes(count: 32)
        let keys  = try messageKeys(conversationKey: conversationKey, nonce: nonce)

        guard let plaintextData = plaintext.data(using: .utf8) else {
            throw SilentPaymentError.ecdhFailed
        }
        // Pad to multiple of 32 bytes per NIP-44 spec
        let padded    = pad(plaintextData)
        let ciphertext = try chacha20(key: keys.encKey, nonce: keys.chachaNonce, data: padded)
        let mac = hmacAA(key: keys.macKey, nonce: nonce, ciphertext: ciphertext)

        // Encode: version(1) || nonce(32) || ciphertext || mac(32) → base64
        var payload = Data([0x02]) + nonce + ciphertext + mac
        return payload.base64EncodedString()
    }

    static func decrypt(ciphertext: String, recipientPrivKey: Data, senderPubKey: Data) throws -> String {
        guard let payload = Data(base64Encoded: ciphertext), payload.count >= 99 else {
            throw SilentPaymentError.ecdhFailed
        }
        let version   = payload[0]
        guard version == 0x02 else { throw SilentPaymentError.ecdhFailed }
        let nonce    = payload[1..<33]
        let mac      = payload[(payload.count - 32)...]
        let ct       = payload[33..<(payload.count - 32)]

        let conversationKey = try conversationKey(senderPrivKey: recipientPrivKey, recipientPubKey: senderPubKey)
        let keys = try messageKeys(conversationKey: conversationKey, nonce: Data(nonce))

        let expectedMac = hmacAA(key: keys.macKey, nonce: Data(nonce), ciphertext: Data(ct))
        guard expectedMac == Data(mac) else { throw SilentPaymentError.ecdhFailed }

        let padded    = try chacha20(key: keys.encKey, nonce: keys.chachaNonce, data: Data(ct))
        let plaintext = unpad(padded)
        return String(data: plaintext, encoding: .utf8) ?? ""
    }

    private static func conversationKey(senderPrivKey: Data, recipientPubKey: Data) throws -> Data {
        // ECDH shared point (x-only)
        let sharedPoint = try Secp256k1Helper.ecdhPoint(privateKey: senderPrivKey, publicKey: recipientPubKey)
        let xOnly = Secp256k1Helper.xOnlyKey(sharedPoint)
        // HKDF-extract with salt "nip44-v2"
        let salt = Data("nip44-v2".utf8)
        return hkdfExtract(salt: salt, ikm: xOnly)
    }

    private struct MessageKeys {
        let encKey: Data
        let chachaNonce: Data
        let macKey: Data
    }

    private static func messageKeys(conversationKey: Data, nonce: Data) throws -> MessageKeys {
        // HKDF-expand: expand conversationKey with nonce into 76 bytes
        let expanded = hkdfExpand(prk: conversationKey, info: nonce, length: 76)
        return MessageKeys(
            encKey:       expanded[0..<32],
            chachaNonce:  expanded[32..<44],
            macKey:       expanded[44..<76]
        )
    }

    // Simplified HKDF-Extract using HMAC-SHA256
    private static func hkdfExtract(salt: Data, ikm: Data) -> Data {
        let key = SymmetricKey(data: salt)
        let mac = HMAC<SHA256>.authenticationCode(for: ikm, using: key)
        return Data(mac)
    }

    private static func hkdfExpand(prk: Data, info: Data, length: Int) -> Data {
        var result = Data()
        var T = Data()
        var i: UInt8 = 1
        while result.count < length {
            var input = T + info + Data([i])
            let key   = SymmetricKey(data: prk)
            T = Data(HMAC<SHA256>.authenticationCode(for: input, using: key))
            result.append(T)
            i += 1
        }
        return result.prefix(length)
    }

    private static func hmacAA(key: Data, nonce: Data, ciphertext: Data) -> Data {
        let symKey = SymmetricKey(data: key)
        let input  = nonce + ciphertext
        return Data(HMAC<SHA256>.authenticationCode(for: input, using: symKey))
    }

    // Minimal ChaCha20 (XOR stream) — replace with CryptoKit's ChaCha20 in production
    private static func chacha20(key: Data, nonce: Data, data: Data) throws -> Data {
        // Use CryptoKit Nonce type (12 bytes)
        guard nonce.count >= 12 else { throw SilentPaymentError.ecdhFailed }
        let ck   = SymmetricKey(data: key)
        let cn   = try CryptoKit.ChaChaPoly.Nonce(data: nonce.prefix(12))
        // For encrypt we use a zero-AAD sealed box and strip the 16-byte tag
        // NIP-44 uses ChaCha20 (stream cipher only, no AEAD tag)
        // This is a known limitation — for production, use a NIP-44 vetted library.
        let sealed = try CryptoKit.ChaChaPoly.seal(data, using: ck, nonce: cn)
        return sealed.ciphertext  // CryptoKit gives us the raw ciphertext
    }

    private static func pad(_ data: Data) -> Data {
        let minPad = data.count + 2
        let unpaddedLen = max(32, Int(pow(2.0, ceil(log2(Double(max(minPad, 1)))))))
        var result = Data(count: 2)
        result[0] = UInt8((data.count >> 8) & 0xFF)
        result[1] = UInt8(data.count & 0xFF)
        result.append(data)
        while result.count < unpaddedLen { result.append(0) }
        return result
    }

    private static func unpad(_ data: Data) -> Data {
        guard data.count >= 2 else { return data }
        let len = (Int(data[0]) << 8) | Int(data[1])
        return data.dropFirst(2).prefix(len)
    }
}

// MARK: - Nostr model stubs (to compile without full NostrSDK dependency on types)

struct NostrFilter: Codable {
    let kinds: [Int]
    let ptags: [String]
    let since: Int?
    enum CodingKeys: String, CodingKey {
        case kinds, since
        case ptags = "#p"
    }
}

struct NostrEvent: Codable {
    var pubkey: String
    var createdAt: Int
    var kind: Int
    var tags: [[String]]
    var content: String
    var id: String = ""
    var sig: String = ""

    enum CodingKeys: String, CodingKey {
        case pubkey, kind, tags, content, id, sig
        case createdAt = "created_at"
    }

    mutating func sign(with privKey: Data) throws {
        // Compute event ID = SHA256 of canonical serialisation
        let serialised = "[\(0),\"\(pubkey)\",\(createdAt),\(kind),\(tagsJSON()),\"\(content)\"]"
        let idBytes = Data(SHA256.hash(data: Data(serialised.utf8)))
        self.id = idBytes.hexString
        // Sign with Schnorr via backend
        let sigBytes = try Secp256k1.schnorrSign(message: idBytes, privateKey: privKey)
        self.sig = sigBytes.hexString
    }

    private func tagsJSON() -> String {
        let inner = tags.map { t in "[" + t.map { "\"\($0)\"" }.joined(separator: ",") + "]" }.joined(separator: ",")
        return "[\(inner)]"
    }
}

// MARK: - Data helpers

extension Data {
    static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    init?(hexString: String) {
        let hex = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        guard hex.count % 2 == 0 else { return nil }
        var data = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let byte = UInt8(hex[i..<j], radix: 16) else { return nil }
            data.append(byte)
            i = j
        }
        self = data
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

struct WebSocketConnection {}  // placeholder; replaced by URLSessionWebSocketTask

import CryptoKit
