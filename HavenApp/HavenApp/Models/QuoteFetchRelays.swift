import Foundation

/// Where to ask for a quoted note our own relays and feed relays don't
/// have: the relay hint in the quoting note's `nevent`, then the quoted
/// author's write relays from their kind 10002. On 2026-11-27 a quote whose
/// only hint (nostr.mom) was down sat only on nostr-02.yakihonne.com, the 7th
/// of 9 relays in its author's list, and the quote card never filled.
/// Loopback and LAN hints are dropped: they point at our own device.
enum QuoteFetchRelays {
    /// Write relays asked per author: enough to reach the 7th of 9.
    static let maxAuthorRelays = 8

    /// The relay hints (TLV type 1) of every `nevent` in `content` naming `id`.
    static func hints(for id: String, in content: String) -> [String] {
        QuoteReference.identifiers(in: content).flatMap { identifier -> [String] in
            var bech = identifier.lowercased()
            if bech.hasPrefix("nostr:") { bech.removeFirst("nostr:".count) }
            guard bech.hasPrefix("nevent1"), let decoded = Bech32.decode(bech),
                  QuoteReference.eventID(fromNeventTLV: decoded.data) == id else { return [] }
            return QuoteReference.tlvEntries(decoded.data)
                .filter { $0.type == 1 }
                .compactMap { String(data: $0.value, encoding: .utf8) }
        }
    }

    /// The quoted note's author, as the quoting note's `nevent` names it.
    static func author(for id: String, in content: String) -> String? {
        QuoteReference.eventPointers(in: content).first { $0.id == id && $0.author != nil }?.author
    }

    /// Hints first, then up to `maxAuthorRelays` of `authorWrite` (nil when
    /// the author's list isn't known), minus anything in `asked` and anything
    /// outsiders can't reach. Compared without case or a trailing slash.
    static func relays(hints: [String], authorWrite: [String]?, asked: [String]) -> [String] {
        func key(_ s: String) -> String {
            var k = s.trimmingCharacters(in: .whitespaces).lowercased()
            while k.hasSuffix("/") { k.removeLast() }
            return k
        }
        var seen = Set(asked.map(key))
        var out: [String] = []
        for url in hints.compactMap(ParentLookupRelays.reachableHint) where seen.insert(key(url)).inserted {
            out.append(url)
        }
        var fromAuthor = 0
        for url in (authorWrite ?? []).compactMap(ParentLookupRelays.reachableHint)
        where fromAuthor < maxAuthorRelays && seen.insert(key(url)).inserted {
            out.append(url); fromAuthor += 1
        }
        return out
    }
}
