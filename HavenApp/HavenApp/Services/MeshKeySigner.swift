import Foundation
import Security

/// Signs with this device's own mesh key (the engine's, made by
/// FipsMeshService / MacFipsMeshService), never the owner's: the copy start
/// and Blossom over the mesh (MeshKeyAuth). The key is read per call and
/// never held; a missing key is the engine's to make, so nothing is signed.
enum MeshKeySigner {
    /// A signed event as the base64 an `Authorization: Nostr` header carries,
    /// or nil when this device has no mesh key or signing failed.
    static func authorization(kind: Int, content: String, tags: [[String]]) -> String? {
        guard let event = sign(kind: kind, content: content, tags: tags),
              let json = try? JSONEncoder().encode(event) else { return nil }
        return json.base64EncodedString()
    }

    static func sign(kind: Int, content: String, tags: [[String]]) -> NostrEvent? {
        guard let sk = secretHex(), let pk = publicHex(secretHex: sk) else { return nil }
        let unsigned = EventPublisher.buildUnsignedEvent(pubkey: pk, kind: kind, content: content, tags: tags)
        guard let json = try? JSONSerialization.data(withJSONObject: unsigned),
              let jsonString = String(data: json, encoding: .utf8),
              let signed = EventPublisher.signWithGoBackend(eventJSON: jsonString, secretKey: sk),
              signed.pubkey == pk, signed.kind == kind else { return nil }
        return signed
    }

    static func publicHex(secretHex: String) -> String? {
        guard let pk = withCStrings([secretHex], { p in GetPublicKeyC(p[0]) }) else { return nil }
        defer { free(pk) }
        return String(cString: pk).lowercased()
    }

    /// The engine's key, read only.
    static func secretHex() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: MeshIdentityReset.keychainService,
            kSecAttrAccount as String: "mesh-nsec",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let nsec = String(data: data, encoding: .utf8),
              let decoded = Bech32.decode(nsec), decoded.hrp == "nsec", decoded.data.count == 32 else { return nil }
        return decoded.hexString
    }
}
