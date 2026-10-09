import Foundation

/// What someone pasted or scanned into the "I use Nostr" identity field.
/// One field takes everything, and what it holds decides the mode: a public
/// key or name@domain means read-only, a private key or a signer app means
/// you can post. That's what used to be the Browse / Full Setup choice.
///
/// Recognises the shape only. The caller still checks a key's checksum
/// (`Bech32.hasValidChecksum`) and resolves name@domain over the network.
enum IdentityInput: Equatable {
    case empty
    /// `npub1…`: read-only.
    case publicKey(String)
    /// `name@domain` or a bare `domain.tld`: resolves to a public key, read-only.
    case nip05(String)
    /// `nsec1…`: can post.
    case secretKey(String)
    /// `ncryptsec1…`: a password-protected private key (NIP-49), can post.
    case encryptedSecretKey(String)
    /// `bunker://…`: a signer app (NIP-46), can post.
    case remoteSigner(BunkerURI.Info)
    /// 64 hex characters. Refused: it could be a public or a private key,
    /// and guessing wrong would show someone's private key as their identity.
    case hexKey
    case unrecognised

    init(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // QR codes and links often carry the NIP-21 scheme.
        if text.lowercased().hasPrefix("nostr:") { text = String(text.dropFirst(6)) }
        let lower = text.lowercased()

        if text.isEmpty {
            self = .empty
        } else if lower.hasPrefix("bunker:") {
            self = BunkerURI.parse(text).map(IdentityInput.remoteSigner) ?? .unrecognised
        } else if lower.hasPrefix("nsec1") {
            self = .secretKey(lower)
        } else if lower.hasPrefix("ncryptsec1") {
            self = .encryptedSecretKey(lower)
        } else if lower.hasPrefix("npub1") {
            self = .publicKey(lower)
        } else if lower.count == 64, lower.allSatisfy(\.isHexDigit) {
            self = .hexKey
        } else if Self.looksLikeNIP05(lower) {
            self = .nip05(lower)
        } else {
            self = .unrecognised
        }
    }

    /// Whether this identity can sign: post, DM and zap.
    var canPost: Bool {
        switch self {
        case .secretKey, .encryptedSecretKey, .remoteSigner: return true
        default: return false
        }
    }

    /// The setup mode it leads to, as stored in `HavenConfig.setupMode`.
    /// nil while the field isn't usable yet.
    var setupMode: String? {
        switch self {
        case .publicKey, .nip05: return "browse"
        case .secretKey, .encryptedSecretKey, .remoteSigner: return "full"
        case .empty, .hexKey, .unrecognised: return nil
        }
    }

    /// One plain line under the field, so nobody needs the words
    /// "browse mode" or "nsec" to know what they've got.
    var hint: String? {
        switch self {
        case .empty: return nil
        case .publicKey, .nip05: return "You can read everything. Add your key later in Settings to post."
        case .secretKey, .encryptedSecretKey: return "You can post, message and zap. Your key stays on this device."
        case .remoteSigner: return "You can post, message and zap. Your signer app approves each one."
        case .hexKey: return "Paste the npub or nsec version of this key."
        case .unrecognised: return "Paste an npub, name@domain, nsec, or a bunker:// link."
        }
    }

    /// user@domain.tld, or a bare domain.tld (NIP-05 `_@domain`).
    private static func looksLikeNIP05(_ text: String) -> Bool {
        guard !text.contains(" "), !text.contains("/"), text.contains(".") else { return false }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return false }
        if parts.count == 2, parts[0].isEmpty { return false }
        guard let domain = parts.last, domain.contains("."),
              !domain.hasPrefix("."), !domain.hasSuffix(".") else { return false }
        return true
    }
}
