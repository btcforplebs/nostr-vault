import Foundation

/// Finds a real secret key (`nsec1…`) in text that is about to be published,
/// or in a profile we already loaded (Logen 2026-11-20: 144 people pasted
/// their nsec into a sign-up name box, RESEARCH/NV_PUBLIC_NSEC_ACCOUNTS).
///
/// Only a key that would work counts: `nsec1` and 58 bech32 characters whose
/// BIP-173 checksum is right, all one case, carrying exactly 32 bytes. The
/// prefix alone, a cut-off key or a typo is not one.
///
/// A key found here is never logged, printed, stored or sent. It lives only
/// in local values for as long as a check or a pubkey derivation takes.
/// Android's `SecretKeyLeak.kt` and the web's `secret-key-leak.js` are the
/// same rule.
enum SecretKeyLeak {
    /// Shown when a publish is refused. No override.
    static let blockMessage = "This is a secret key. Publishing it lets anyone post as you."
    /// Shown on the profile of an account whose key is out in the open.
    static let publicKeyLabel = "Key is public. Anyone can post as this account"

    /// The error a publish path throws, so the composer shows `blockMessage`
    /// and keeps the text.
    struct Blocked: LocalizedError, Equatable {
        var errorDescription: String? { SecretKeyLeak.blockMessage }
    }

    /// `nsec1` then exactly 58 bech32 data characters (52 for 32 bytes, 6 for
    /// the checksum), either case. A `nostr:` prefix is just text before it.
    private static let pattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: "nsec1[02-9ac-hj-np-z]{58}", options: [.caseInsensitive])

    /// Whether `text` holds a working secret key anywhere in it.
    static func containsSecretKey(_ text: String) -> Bool {
        !secretKeys(in: text, stopAtFirst: true).isEmpty
    }

    /// An event's content or any tag value. A kind 0's content is the profile
    /// JSON, so this covers every profile field.
    static func containsSecretKey(content: String, tags: [[String]]) -> Bool {
        containsSecretKey(content) || tags.contains { $0.contains(where: containsSecretKey) }
    }

    /// Kinds the signer does not check: a repost (6, 16) carries someone
    /// else's note as it already is on the relays, and adds nothing of yours.
    static let exemptKinds: Set<Int> = [6, 16]

    /// The x-only pubkeys (hex) of every working key in `text`, one each.
    /// `derive` turns 32 secret bytes into the pubkey hex (the app passes the
    /// Go core's GetPublicKeyC; tests pass their own).
    static func derivedPubkeys(in text: String, derive: (Data) -> String?) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for key in secretKeys(in: text, stopAtFirst: false) {
            // The Go core answers 00..00, with no error, for the zero key and
            // for the curve order n: no account has that pubkey.
            guard let pub = derive(key)?.lowercased(), pub.count == 64, pub != zeroPubkey,
                  seen.insert(pub).inserted else { continue }
            out.append(pub)
        }
        return out
    }

    /// Every string field of a parsed profile, for one that came from the
    /// disk cache rather than a fresh kind 0.
    static func profileText(_ p: FeedProfile) -> String {
        [p.name, p.displayName, p.about, p.nip05, p.lud16, p.lud06, p.website,
         p.pictureURL?.absoluteString, p.bannerURL?.absoluteString]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    // MARK: - Private

    private static let zeroPubkey = String(repeating: "0", count: 64)

    private static func secretKeys(in text: String, stopAtFirst: Bool) -> [Data] {
        // Most text has no "nsec1" at all: skip the regex for it.
        guard text.range(of: "nsec1", options: .caseInsensitive) != nil, let pattern else { return [] }
        let ns = text as NSString
        var found: [Data] = []
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let key = decode(ns.substring(with: match.range)) else { continue }
            found.append(key)
            if stopAtFirst { break }
        }
        return found
    }

    /// The 32 secret bytes, or nil unless `token` is a valid nsec.
    static func decode(_ token: String) -> Data? {
        let lower = token.lowercased()
        // Bech32 is one case: a mixed-case string is not a valid encoding.
        guard token == lower || token == token.uppercased(),
              lower.hasPrefix("nsec1"), lower.count == 63,
              Bech32.hasValidChecksum(lower),
              let decoded = Bech32.decode(lower), decoded.hrp == "nsec", decoded.data.count == 32 else { return nil }
        return decoded.data
    }
}
