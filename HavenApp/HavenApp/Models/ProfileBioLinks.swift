import Foundation

/// The links in a profile bio, so each one is tappable where it stands.
///
/// The bio is shown as written: nothing is shortened, and markdown is not
/// read (a bio's `*stars*` stay stars). Only the links get a `.link`
/// attribute; a tap then goes through `InAppBrowser.route`, the same entry
/// point post links use, so "Open links in Nostr Vault", the mesh-only gate
/// and the ask-before-leaving-the-mesh rule all apply.
///
/// Links found: `http(s)://` URLs (IPv4 and bracketed IPv6 hosts included)
/// and a bare `<npub>.fips[/path]`, which opens as `http://<npub>.fips/…`.
/// A `.onion` address stays text: the app does not reach Tor.
enum ProfileBioLinks {
    struct Link: Equatable {
        let range: Range<String.Index>
        let url: URL
    }

    /// `http(s)://` + a bracketed IPv6 host or a plain host[:port], then an
    /// optional path/query/fragment. Not glued to a preceding word.
    private static let webRegex = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_])https?://(?:\[[0-9A-Fa-f:.]+\](?::\d+)?|[^\s/?#<>"\[\]()]+)(?:[/?#][^\s<>"]*)?"#,
        options: .caseInsensitive)

    /// A bare `<npub>.fips`, not part of a longer name or a URL.
    private static let bareFipsRegex = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_./:@-])npub1[02-9ac-hj-np-z]{58}\.fips(?![\p{L}\p{N}_-])(?:[/?#][^\s<>"]*)?"#,
        options: .caseInsensitive)

    static func links(in bio: String) -> [Link] {
        let whole = NSRange(bio.startIndex..., in: bio)
        var found: [Link] = []
        for match in webRegex.matches(in: bio, range: whole) {
            guard let range = trimmed(match.range, in: bio) else { continue }
            let text = String(bio[range])
            guard let url = URL(string: text), let host = url.host, !host.isEmpty,
                  !isOnion(host) else { continue }
            found.append(Link(range: range, url: url))
        }
        for match in bareFipsRegex.matches(in: bio, range: whole) {
            guard let range = trimmed(match.range, in: bio),
                  !found.contains(where: { $0.range.overlaps(range) }) else { continue }
            let text = String(bio[range])
            guard let url = URL(string: "http://" + text),
                  FipsURL.npub(inFipsHost: url.host) != nil else { continue }
            found.append(Link(range: range, url: url))
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// The bio as written, with each link marked.
    static func attributed(_ bio: String) -> AttributedString {
        var out = AttributedString(bio)
        for link in links(in: bio) {
            guard let lower = AttributedString.Index(link.range.lowerBound, within: out),
                  let upper = AttributedString.Index(link.range.upperBound, within: out) else { continue }
            out[lower..<upper].link = link.url
        }
        return out
    }

    // MARK: - Edges

    private static func isOnion(_ host: String) -> Bool {
        let bare = host.lowercased().hasSuffix(".") ? String(host.lowercased().dropLast()) : host.lowercased()
        return bare == "onion" || bare.hasSuffix(".onion")
    }

    /// Drops sentence punctuation after a link, and a closing bracket the
    /// link did not open (`(https://a.b)` but `…/Foo_(bar)` keeps its own).
    private static func trimmed(_ nsRange: NSRange, in bio: String) -> Range<String.Index>? {
        guard let range = Range(nsRange, in: bio) else { return nil }
        var end = range.upperBound
        while end > range.lowerBound {
            let last = bio[bio.index(before: end)]
            let text = bio[range.lowerBound..<end]
            if ".,;:!?'\"".contains(last) {
                end = bio.index(before: end)
            } else if last == ")", text.filter({ $0 == ")" }).count > text.filter({ $0 == "(" }).count {
                end = bio.index(before: end)
            } else if last == "]", text.filter({ $0 == "]" }).count > text.filter({ $0 == "[" }).count {
                end = bio.index(before: end)
            } else {
                break
            }
        }
        // A scheme and nothing else is not a link.
        guard end > range.lowerBound, !bio[range.lowerBound..<end].lowercased().hasSuffix("://") else { return nil }
        return range.lowerBound..<end
    }
}
