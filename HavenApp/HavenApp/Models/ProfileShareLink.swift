import Foundation

/// A profile's public address, https://nostrvault.app/p/<npub>: what Share
/// profile puts in its QR code and copies, and what the website's /p/ page
/// serves. Android writes the same address (ProfileShareLink.kt).
///
/// Reading one back is `NostrURI(string:)`, which takes this form beside
/// `nostr:` links, so a scanned code, a pasted link and a link handed over by
/// the system all land on the same profile.
enum ProfileShareLink {
    static let site = "https://nostrvault.app"

    /// The address for an npub. Nil for anything that is not an npub, so a
    /// hex key or a secret key never ends up in a shared link.
    static func url(npub: String) -> URL? {
        let id = npub.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard id.hasPrefix("npub1"), id.count > 5,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return URL(string: "\(site)/p/\(id)")
    }

    /// The app link the website's "Open in Nostr Vault" button uses, so no
    /// other Nostr app answers it: nostrvault://p/<npub>.
    static func appURL(npub: String) -> URL? {
        url(npub: npub).flatMap { URL(string: "nostrvault://p/\($0.lastPathComponent)") }
    }

    /// The npub or nprofile a nostrvault.app/p/ address (or the website's
    /// nostrvault://p/ app link) names, lowercased. Nil for any other
    /// address, host or path.
    static func profileID(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else { return nil }
        var parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if scheme == "nostrvault" {
            // nostrvault://p/<id>: "p" is the host.
            guard host == "p" else { return nil }
            parts.insert("p", at: 0)
        } else {
            guard scheme == "https" || scheme == "http",
                  host == "nostrvault.app" || host == "www.nostrvault.app" else { return nil }
        }
        guard parts.count == 2, parts[0] == "p" else { return nil }
        let id = parts[1].lowercased()
        guard id.hasPrefix("npub1") || id.hasPrefix("nprofile1"),
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return id
    }
}
