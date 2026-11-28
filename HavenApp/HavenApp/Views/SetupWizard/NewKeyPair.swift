import Foundation

/// A brand-new Nostr key pair for the New to Nostr path. Made silently when
/// that way in is picked, so the people step can leave this key out and the
/// key step only has to show it. Nothing is saved here: the wizard encrypts
/// the nsec once the lock step has a password.
enum NewKeyPair {
    /// nil when the engine could not make one.
    static func generate() -> (npub: String, nsec: String)? {
        guard let resultCStr = GenerateKeyPairC() else { return nil }
        // The engine's C string (malloc'd, holds the secret key): ours to free.
        defer { free(resultCStr) }
        let parts = String(cString: resultCStr).split(separator: ":")
        guard parts.count == 2,
              let secData = Bech32.hexToData(String(parts[0])),
              let pubData = Bech32.hexToData(String(parts[1])),
              let npub = Bech32.encode(hrp: "npub", data: pubData),
              let nsec = Bech32.encode(hrp: "nsec", data: secData) else { return nil }
        return (npub, nsec)
    }
}
