import Foundation
import CryptoKit

/// A long-form article whose body is sold for a zap elsewhere (Fanfares'
/// "zap N sats to unlock"). The app shows it as locked and never pays for it;
/// it only opens one with a key an earlier version stored.
///
/// There is no merged NIP for this (Fanfares' NIP-108, nostr-protocol/nips#827,
/// closed unmerged). The event carries
/// `["encrypted", "aes-256-gcm", <base64>, <key URL>]` and
/// `["price", "42", "SATS"]`; `content` is only a teaser plus a link. The
/// base64 blob is WebCrypto's AES-GCM layout: a 12-byte IV, then the
/// ciphertext with the 16-byte tag appended.
struct GatedArticle: Equatable {
    /// Base64 of IV ‖ ciphertext ‖ tag.
    let ciphertext: String
    let priceSats: Int

    /// nil for an ordinary article, or for a gated one we can't act on (no key
    /// URL, an algorithm we don't speak, no usable price).
    init?(kind: Int, pubkey: String, tags: [[String]]) {
        guard kind == 30023,
              let enc = tags.first(where: { $0.first == "encrypted" }),
              enc.count >= 4, enc[1].lowercased() == "aes-256-gcm",
              !enc[2].isEmpty,
              URL(string: enc[3])?.scheme == "https"
        else { return nil }

        guard let priceTag = tags.first(where: { $0.first == "price" && $0.count >= 2 }),
              let amount = Int(priceTag[1].trimmingCharacters(in: .whitespaces)), amount > 0
        else { return nil }
        // Only sats are something a zap can pay. A fiat price needs a rate we
        // don't have, so it stays a link out.
        let currency = priceTag.count >= 3 ? priceTag[2].uppercased() : "SATS"
        guard currency == "SATS" || currency == "SAT" else { return nil }

        self.ciphertext = enc[2]
        self.priceSats = amount
    }

    /// Decrypts the body with a stored key. nil when the key
    /// isn't 32 bytes of hex or doesn't open the box — a wrong key and a
    /// corrupted body look the same, and both mean "don't show anything".
    func decrypt(keyHex: String) -> String? {
        let hex = keyHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count == 64, let keyData = Data(gatedHex: hex),
              let blob = Data(base64Encoded: ciphertext, options: .ignoreUnknownCharacters),
              blob.count > 12 + 16 else { return nil }
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: blob.prefix(12)),
                ciphertext: blob.dropFirst(12).dropLast(16),
                tag: blob.suffix(16)
            )
            let plain = try AES.GCM.open(box, using: SymmetricKey(data: keyData))
            return String(data: plain, encoding: .utf8)
        } catch {
            return nil
        }
    }

}

/// Teaser text a gated article ships in `content`, minus the "zap to unlock …
/// <link>" call to action, which the app doesn't offer.
enum GatedArticleTeaser {
    static func strip(_ content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        guard let cta = lines.lastIndex(where: { $0.range(of: "to unlock", options: .caseInsensitive) != nil }) else {
            return content
        }
        return lines[..<cta].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Data {
    init?(gatedHex: String) {
        let chars = Array(gatedHex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = Self.nibble(chars[i]), let lo = Self.nibble(chars[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
            i += 2
        }
        self.init(bytes)
    }

    static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 65...70: return c - 55
        case 97...102: return c - 87
        default: return nil
        }
    }
}
