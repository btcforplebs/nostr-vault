import Foundation

/// Reading a BOLT-11 invoice's human-readable part.
///
/// Only the amount, which is all the app needs: enough to tell you what a zap
/// was worth, and what you are about to pay before you tap the button.
enum Bolt11 {

    /// What an invoice says it is worth.
    enum Amount: Equatable {
        /// At least one whole sat.
        case sats(Int)
        /// A well-formed invoice that names no amount you could show — either
        /// an amountless invoice ("pay me what you like") or one worth less
        /// than a sat.
        case unspecified
        /// Not a BOLT-11 invoice, or not one we can read.
        case unreadable
    }

    /// 1 BTC = 100_000_000_000 msat.
    private static let msatPerBTC = 100_000_000_000

    static func amount(_ invoice: String) -> Amount {
        switch parse(invoice) {
        case .msat(let msat, _): return sats(msat: msat)
        case .unspecified: return .unspecified
        case .unreadable: return .unreadable
        }
    }

    /// The exact amount in millisatoshis, or nil for an amountless or
    /// unreadable invoice. For checking an invoice against the amount that was
    /// asked for — `amount` rounds down to whole sats, which would let a
    /// service add up to 999 msat unnoticed.
    static func msat(_ invoice: String) -> Int? {
        if case .msat(let m, exact: true) = parse(invoice), m > 0, m < 21_000_000 * msatPerBTC { return m }
        return nil
    }

    /// `exact` is false for a pico amount that is not a whole msat.
    private enum Parsed { case msat(Int, exact: Bool), unspecified, unreadable }

    private static func parse(_ invoice: String) -> Parsed {
        let lower = invoice.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // The bech32 data charset excludes `1`, so the last `1` is the
        // separator — unambiguously. Reading digits forward from the network
        // prefix instead turns an amountless invoice's separator into an
        // amount, whose size is then decided by the first character of the
        // payload: `lnbc1qqq…` reads as 1 BTC, `lnbc1u3q…` as 100 sats.
        guard let separator = lower.lastIndex(of: "1"),
              lower.index(after: separator) < lower.endIndex
        else { return .unreadable }

        let hrp = lower[lower.startIndex..<separator]
        guard let network = ["lnbcrt", "lnbc", "lntbs", "lntb"].first(where: { hrp.hasPrefix($0) })
        else { return .unreadable }

        var rest = hrp[hrp.index(hrp.startIndex, offsetBy: network.count)...]
        let digits = rest.prefix(while: \.isNumber)
        rest = rest.dropFirst(digits.count)
        // No digits is an amountless invoice; more than one trailing character
        // is not a multiplier.
        guard rest.count <= 1 else { return .unreadable }
        guard !digits.isEmpty else { return .unspecified }
        // Digits that will not fit an Int are junk, not an amountless invoice.
        guard let value = Int(digits) else { return .unreadable }

        let perUnit: Int
        switch rest.first {
        case "m": perUnit = msatPerBTC / 1_000
        case "u": perUnit = msatPerBTC / 1_000_000
        case "n": perUnit = msatPerBTC / 1_000_000_000
        // Pico-BTC is a tenth of a msat; a valid pico amount is a multiple of 10.
        case "p": return .msat(value / 10, exact: value % 10 == 0)
        case nil: perUnit = msatPerBTC
        default: return .unreadable
        }

        // Reported rather than `*`, which traps: the digit run comes off the
        // wire and nothing upstream bounds its length.
        let (msat, overflowed) = value.multipliedReportingOverflow(by: perUnit)
        guard !overflowed else { return .unreadable }
        return .msat(msat, exact: true)
    }

    /// Sats, or nil for anything that does not state at least one.
    static func sats(_ invoice: String) -> Int? {
        if case .sats(let n) = amount(invoice) { return n }
        return nil
    }

    private static func sats(msat: Int) -> Amount {
        // 21 million BTC is the whole supply; at or past it the invoice is junk.
        guard msat >= 1_000 else { return .unspecified }
        guard msat < 21_000_000 * msatPerBTC else { return .unreadable }
        return .sats(msat / 1_000)
    }

    // MARK: - Payment hash

    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")

    /// The invoice's payment hash (tagged field `p`), as lowercase hex.
    ///
    /// The one identifier a wallet's history and a zap receipt both carry —
    /// what lets a payment be matched to the receipt that says who sent it.
    /// Checksum is not verified: this only reads, and a receipt whose bolt11
    /// is corrupt simply matches nothing.
    static func paymentHash(_ invoice: String) -> String? {
        let lower = invoice.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let separator = lower.lastIndex(of: "1") else { return nil }
        var words: [UInt8] = []
        for ch in lower[lower.index(after: separator)...] {
            guard let v = charset.firstIndex(of: ch) else { return nil }
            words.append(UInt8(v))
        }
        // timestamp (7) … tagged fields … signature (104) + checksum (6)
        guard words.count > 7 + 104 + 6 else { return nil }
        let end = words.count - 104 - 6
        var i = 7
        while i + 3 <= end {
            let type = words[i]
            let length = Int(words[i + 1]) << 5 | Int(words[i + 2])
            i += 3
            guard i + length <= end else { return nil }
            if type == 1 && length == 52 {
                // 52 five-bit words = 260 bits; the hash is the first 256.
                var bytes: [UInt8] = []
                var acc = 0, bits = 0
                for w in words[i..<(i + length)] {
                    acc = (acc << 5) | Int(w)
                    bits += 5
                    if bits >= 8 {
                        bits -= 8
                        bytes.append(UInt8((acc >> bits) & 0xff))
                        acc &= (1 << bits) - 1
                    }
                }
                guard bytes.count >= 32 else { return nil }
                return bytes.prefix(32).map { String(format: "%02x", $0) }.joined()
            }
            i += length
        }
        return nil
    }
}
