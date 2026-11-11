import Foundation

extension QuoteReference {
    /// Every quote reference in `content`, resolved to the id the app looks
    /// events up by: a 64-hex event id for `note1`/`nevent1`, and a
    /// `"naddr:<kind>:<pubkey>:<d-tag>"` coordinate for `naddr1`.
    ///
    /// This lives beside `QuoteReference` rather than inside it because bech32
    /// decoding is app-target code; the parsing it feeds is pure and tested.
    /// It is the single definition — a feed note and a relay-tab event must not
    /// disagree about what a note quotes.
    static func resolvedIdentifiers(in content: String) -> [String] {
        identifiers(in: content).compactMap { identifier -> String? in
            guard let decoded = Bech32.decode(identifier) else { return nil }
            if identifier.hasPrefix("note1") {
                return decoded.hexString
            }
            if identifier.hasPrefix("nevent1") {
                return eventID(fromNeventTLV: decoded.data)
            }
            if identifier.hasPrefix("naddr1") {
                return coordinate(fromNaddrTLV: decoded.data)
            }
            return nil
        }
    }

    /// The pointer a bare `note1…` / `nevent1…` identifier (an optional
    /// `nostr:` prefix allowed) decodes to, or nil for anything else.
    static func eventPointer(from identifier: String) -> EventPointer? {
        var bech = identifier.lowercased()
        if bech.hasPrefix("nostr:") { bech.removeFirst("nostr:".count) }
        guard let decoded = Bech32.decode(bech) else { return nil }
        if bech.hasPrefix("note1") {
            return decoded.data.count == 32 ? EventPointer(id: decoded.hexString) : nil
        }
        return bech.hasPrefix("nevent1") ? eventPointer(fromNeventTLV: decoded.data) : nil
    }

    /// The pointers of every `nostr:note1…` / `nostr:nevent1…` in `content`.
    static func eventPointers(in content: String) -> [EventPointer] {
        identifiers(in: content).compactMap { eventPointer(from: $0) }
    }

    /// The coordinate of a NIP-53 live stream (kind 30311) that a web link
    /// points at — `zap.stream/naddr1…`, `shosho.live/live/naddr1…`,
    /// `njump.me/naddr1…`. Any host, because the naddr in the path is what
    /// names the stream; nil for anything else.
    static func liveStreamCoordinate(in url: URL) -> String? {
        for component in url.pathComponents where component.lowercased().hasPrefix("naddr1") {
            guard let decoded = Bech32.decode(component.lowercased()),
                  let coordinate = coordinate(fromNaddrTLV: decoded.data),
                  parseCoordinate(coordinate)?.kind == 30311 else { continue }
            return coordinate
        }
        return nil
    }

    /// The hex pubkey behind a `npub1…`/`nprofile1…` mention, or nil — so a
    /// mention that cannot be read opens nothing rather than a blank profile.
    static func profilePubkey(fromBech32 identifier: String) -> String? {
        let id = identifier.lowercased()
        guard id.hasPrefix("npub1") || id.hasPrefix("nprofile1"),
              let decoded = Bech32.decode(id) else { return nil }
        return profilePubkey(hrp: decoded.hrp, payload: decoded.data)
    }

    /// An article paragraph or list item split into the text left once its
    /// quote references are cut out, and the ids of what they quote, so the
    /// reader draws each one as a card instead of a bare `nostr:nevent1…`
    /// (Logen, 2026-11-11). A markdown link to a reference (`[label](nostr:…)`)
    /// keeps its label as text. Nil when the text quotes nothing.
    static func articleQuoteSplit(_ text: String) -> (text: String, ids: [String])? {
        let ids = resolvedIdentifiers(in: text)
        guard !ids.isEmpty else { return nil }
        var rest = prefixBare(text)
        // A link keeps its label as text; a bare reference goes.
        for (regex, template) in [(articleQuoteLinkRegex, "$1"), (articleQuoteRegex, "")] {
            rest = regex.stringByReplacingMatches(in: rest, range: NSRange(location: 0, length: (rest as NSString).length), withTemplate: template)
        }
        rest = rest.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return (rest.trimmingCharacters(in: .whitespaces), ids)
    }

    private static let articleQuoteRegex = try! NSRegularExpression(
        pattern: #"nostr:(?:note1|nevent1|naddr1)[a-z0-9]+"#, options: .caseInsensitive)
    private static let articleQuoteLinkRegex = try! NSRegularExpression(
        pattern: #"\[([^\]]*)\]\(\s*nostr:(?:note1|nevent1|naddr1)[a-z0-9]+\s*\)"#, options: .caseInsensitive)
}
