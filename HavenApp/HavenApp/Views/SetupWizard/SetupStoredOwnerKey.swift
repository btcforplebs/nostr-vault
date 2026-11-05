import Foundation

/// Reads the owner key saved in config and says whether it belongs to `npub`
/// (SetupOwnerKey.Stored), and clears it. Never logs the key.
enum SetupStoredOwnerKey {
    static func stored(in config: HavenConfig, for npub: String) -> SetupOwnerKey.Stored {
        let plain = config.ownerNsec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !config.ownerNcryptsec.isEmpty || !plain.isEmpty else { return .none }
        var hexKey: String?
        if !config.ownerNcryptsec.isEmpty {
            guard let password = NIP49Service.getPasswordFromKeychain(),
                  let hex = try? config.getDecryptedHexKey(password: password) else { return .unreadable }
            hexKey = hex
        } else {
            hexKey = NpubValidation.hexSecretKey(fromNsec: plain)
                ?? (plain.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil ? plain : nil)
        }
        // Only a proven mismatch clears. If the key or the npub can't be read
        // (e.g. an npub typo that the lenient form check let through), keep it.
        guard let hexKey, let expected = NpubValidation.hexPubkey(fromNpub: npub.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .unreadable
        }
        guard let pk = withCStrings([hexKey], { p in GetPublicKeyC(p[0]) }) else { return .unreadable }
        let derived = String(cString: pk)
        free(pk)
        return derived.lowercased() == expected.lowercased() ? .matches : .other
    }

    static func clear(in config: inout HavenConfig) {
        config.ownerNcryptsec = ""
        config.ownerNsec = ""
        _ = NIP49Service.deletePasswordFromKeychain()
    }
}
