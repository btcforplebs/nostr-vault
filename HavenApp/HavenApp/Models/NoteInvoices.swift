import Foundation

/// Lightning invoices pasted into a note, so the feed can draw each as a card
/// you can pay instead of a wall of bech32.
enum NoteInvoices {

    /// One invoice as it sits in the note.
    struct Match: Equatable {
        /// Exactly as written — `lightning:` prefix and case included — so the
        /// formatter can cut it out of the text.
        let raw: String
        /// Lowercased and prefix-free: what the wallet is handed.
        let invoice: String
        let details: Bolt11.Details
    }

    // Network prefix, optional amount, separator, then a data part long enough
    // to hold a timestamp and a signature. Case-insensitive: bech32 may be
    // written all upper-case, which QR codes favour.
    private static let regex = try! NSRegularExpression(
        pattern: #"(?<![0-9a-z])(?:lightning:(?://)?)?(ln(?:bcrt|bc|tbs|tb)[0-9]*[munp]?1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{117,})(?![0-9a-z])"#,
        options: [.caseInsensitive]
    )

    /// Every readable invoice in `content`, in order, each once. Text that
    /// only looks like an invoice stays text.
    static func find(in content: String) -> [Match] {
        // Most notes have none; skip the regex for them.
        guard content.range(of: "ln", options: .caseInsensitive) != nil else { return [] }
        let ns = content as NSString
        var seen = Set<String>()
        return regex.matches(in: content, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let invoice = ns.substring(with: m.range(at: 1)).lowercased()
            guard seen.insert(invoice).inserted, let details = Bolt11.details(invoice) else { return nil }
            return Match(raw: ns.substring(with: m.range), invoice: invoice, details: details)
        }
    }

    /// `content` with the given invoices cut out — every time each appears —
    /// the way media URLs are cut for their thumbnails.
    static func strip(_ matches: [Match], from content: String) -> String {
        guard !matches.isEmpty else { return content }
        let cut = Set(matches.map(\.invoice))
        let ns = content as NSString
        var result = content
        for m in regex.matches(in: content, range: NSRange(location: 0, length: ns.length)).reversed()
        where cut.contains(ns.substring(with: m.range(at: 1)).lowercased()) {
            result = (result as NSString).replacingCharacters(in: m.range, with: "")
        }
        return result
    }
}
