import Foundation

/// A NIP-21 `nostr:` link handed to the app from outside it — Safari, another
/// client, a QR code — or a nostrvault.app/p/ profile address
/// (`ProfileShareLink`). The app registers the `nostr` scheme so these open
/// here, the way Android's `nostr:` intent filter does.
///
/// Only names what the link points at; turning the bech32 into a hex id needs
/// the app's decoder and happens in the router. `nsec1` and anything else this
/// app has no screen for gives nil, so a pasted secret key is never acted on.
enum NostrURI: Equatable {
    /// `npub1…` / `nprofile1…`
    case profile(String)
    /// `note1…` / `nevent1…`
    case event(String)
    /// `naddr1…` — an addressable event (article, listing, live stream).
    case address(String)

    init?(url: URL) {
        self.init(string: url.absoluteString)
    }

    /// What was pasted into a search field: a `nostr:` link, or the same
    /// reference bare (`nevent1…`, `@npub1…`).
    init?(pasted raw: String) {
        var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("@") { body.removeFirst() }
        if !body.lowercased().hasPrefix("nostr:") { body = "nostr:" + body }
        self.init(string: body)
    }

    init?(string raw: String) {
        // A shared profile address (Share profile's QR code and link).
        if let id = ProfileShareLink.profileID(from: raw) {
            self = .profile(id)
            return
        }
        var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.lowercased().hasPrefix("nostr:") else { return nil }
        body = String(body.dropFirst("nostr:".count))
        // Some apps write `nostr://npub1…`.
        while body.hasPrefix("/") { body.removeFirst() }
        if let cut = body.firstIndex(where: { $0 == "?" || $0 == "#" || $0 == "/" }) {
            body = String(body[..<cut])
        }
        let id = body.lowercased()
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }

        if id.hasPrefix("npub1") || id.hasPrefix("nprofile1") {
            self = .profile(id)
        } else if id.hasPrefix("note1") || id.hasPrefix("nevent1") {
            self = .event(id)
        } else if id.hasPrefix("naddr1") {
            self = .address(id)
        } else {
            return nil
        }
    }
}
