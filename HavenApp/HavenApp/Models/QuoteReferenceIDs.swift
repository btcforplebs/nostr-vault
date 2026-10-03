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
}
