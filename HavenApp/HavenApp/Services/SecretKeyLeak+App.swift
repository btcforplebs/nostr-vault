import Foundation

/// The app half of `SecretKeyLeak`: the pubkey is derived with the Go core
/// (GetPublicKeyC), which the MediaLogic test package does not link.
extension SecretKeyLeak {
    /// The pubkeys of every working key in `text`, derived in memory.
    static func derivedPubkeys(in text: String) -> [String] {
        derivedPubkeys(in: text, derive: goPubkey)
    }

    /// A kind 0 we fetched (its raw content, so every field counts): any
    /// working key in it marks that key's account as public. Nothing is
    /// fetched for this and nothing about the key is kept.
    static func noteProfileContent(_ content: String) {
        PublicKeyRegistry.shared.mark(derivedPubkeys(in: content))
    }

    /// Profiles read back from the disk cache, which keeps only the parsed
    /// fields.
    static func noteProfiles<S: Sequence>(_ profiles: S) where S.Element == FeedProfile {
        var found: [String] = []
        for profile in profiles {
            let text = profileText(profile)
            guard text.range(of: "nsec1", options: .caseInsensitive) != nil else { continue }
            found.append(contentsOf: derivedPubkeys(in: text))
        }
        PublicKeyRegistry.shared.mark(found)
    }

    /// The signer's last line: a publish carrying a working key is refused
    /// and the person told why. Composers check first so their text stays
    /// and their own error line shows; this catches every other path.
    static func refuses(kind: Int, content: String, tags: [[String]]) -> Bool {
        guard !exemptKinds.contains(kind), containsSecretKey(content: content, tags: tags) else { return false }
        Task { @MainActor in
            ErrorNotificationManager.shared.show(blockMessage)
        }
        return true
    }

    private static func goPubkey(_ secret: Data) -> String? {
        let hex = secret.map { String(format: "%02x", $0) }.joined()
        guard let pkCStr = withCStrings([hex], { p in GetPublicKeyC(p[0]) }) else { return nil }
        defer { free(pkCStr) }
        return String(cString: pkCStr)
    }
}
