import Foundation

/// Who a shared profile link names: the `npub` / `nprofile` identifiers in
/// what was shared, in the order the review card tries them (the link first,
/// then the text, then the selection), each once. Pure and fixture-tested;
/// Android's ProfileShareTarget.kt finds the same list. Decoding to a pubkey
/// is the platform's own NIP-19 decoder (here `QuoteReference.target`), which
/// checks the checksum, so a mistyped or made-up identifier names nobody.
enum ProfileShareTarget {
    private static let bech32 = "[qpzry9x8gf2tvdw0s3jn54khce6mua7l]"
    /// The same shapes the classifier offers Profile for (NVShareClassifier).
    private static let pattern = "\\b(?:npub1\(bech32){58}|nprofile1\(bech32){20,})\\b"
    /// More than this many is a list of people, not a profile link.
    static let maxIdentifiers = 20

    static func identifiers(url: String?, text: String?, selection: String?) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var out: [String] = []
        for field in [url, text, selection] {
            guard let s = field, !s.isEmpty else { continue }
            for m in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                guard let r = Range(m.range, in: s) else { continue }
                let id = String(s[r])
                if !out.contains(id) { out.append(id) }
                if out.count == maxIdentifiers { return out }
            }
        }
        return out
    }

    /// `npub1abcdefgh…uvwxyz`: shown under the name, so a copycat with the
    /// same name doesn't look identical (Tron, #1617).
    static func shortNpub(_ npub: String) -> String {
        npub.count > 20 ? "\(npub.prefix(12))…\(npub.suffix(6))" : npub
    }

    /// The hex pubkeys those identifiers name, each once, in the same order.
    static func pubkeys(url: String?, text: String?, selection: String?) -> [String] {
        var out: [String] = []
        for id in identifiers(url: url, text: text, selection: selection) {
            guard case .profile(let hex)? = QuoteReference.target(ofBech32: id) else { continue }
            let key = hex.lowercased()
            if !out.contains(key) { out.append(key) }
        }
        return out
    }
}
