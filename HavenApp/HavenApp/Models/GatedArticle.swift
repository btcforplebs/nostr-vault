import Foundation
import CryptoKit

/// A long-form article whose body is sold for a zap ("zap N sats to unlock").
///
/// There is no merged NIP for this. Fanfares proposed one as NIP-108
/// (nostr-protocol/nips#827, closed unmerged) and what they ship today is
/// assembled from standard parts, which is what lets any client unlock it:
///
/// - the event carries `["encrypted", "aes-256-gcm", <base64>, <key URL>]`
///   and `["price", "42", "SATS"]`; `content` is only a teaser plus a link;
/// - payment is an ordinary NIP-57 zap receipt carrying the article's `a`
///   coordinate, from the reader's own pubkey, so a zap sent from any client
///   counts;
/// - the key comes from the key URL behind NIP-98 HTTP auth: the server checks
///   the receipts for the signing pubkey and answers 402 until they cover the
///   price, then returns the AES key as 64 hex characters;
/// - the base64 blob is WebCrypto's AES-GCM layout: a 12-byte IV, then the
///   ciphertext with the 16-byte tag appended.
struct GatedArticle: Equatable {
    /// Base64 of IV ‖ ciphertext ‖ tag.
    let ciphertext: String
    /// Where the author's tag says the key lives. This is also the `u` the
    /// NIP-98 event must name, even when the request goes to a proxy.
    let keyURL: URL
    let priceSats: Int
    /// Who the price is paid to, and how much each must receive.
    let shares: [Share]

    struct Share: Equatable {
        let pubkey: String
        let relay: String?
        let sats: Int
    }

    /// nil for an ordinary article, or for a gated one we can't act on (no key
    /// URL, an algorithm we don't speak, no usable price).
    init?(kind: Int, pubkey: String, tags: [[String]]) {
        guard kind == 30023,
              let enc = tags.first(where: { $0.first == "encrypted" }),
              enc.count >= 4, enc[1].lowercased() == "aes-256-gcm",
              !enc[2].isEmpty,
              let keyURL = URL(string: enc[3]), keyURL.scheme == "https"
        else { return nil }

        guard let priceTag = tags.first(where: { $0.first == "price" && $0.count >= 2 }),
              let amount = Int(priceTag[1].trimmingCharacters(in: .whitespaces)), amount > 0
        else { return nil }
        // Only sats are something a zap can pay. A fiat price needs a rate we
        // don't have, so it stays a link out.
        let currency = priceTag.count >= 3 ? priceTag[2].uppercased() : "SATS"
        guard currency == "SATS" || currency == "SAT" else { return nil }

        self.ciphertext = enc[2]
        self.keyURL = keyURL
        self.priceSats = amount
        self.shares = Self.split(price: amount, authorPubkey: pubkey, tags: tags)
    }

    /// Splits the price across the event's NIP-57 `zap` tags by weight, the way
    /// Fanfares' own payment check does: a recipient listed twice has its
    /// weights summed, no `zap` tag means the author takes it all, and each
    /// share rounds UP, so paying every share always covers the check.
    static func split(price: Int, authorPubkey: String, tags: [[String]]) -> [Share] {
        var order: [String] = []
        var weights: [String: Int] = [:]
        var relays: [String: String] = [:]
        for tag in tags where tag.first == "zap" && tag.count >= 2 {
            let pubkey = tag[1].lowercased()
            guard pubkey.count == 64, pubkey.allSatisfy(\.isHexDigit) else { continue }
            // Fanfares reads a missing, zero or unparseable weight as 1.
            let weight = tag.count >= 4 ? max(Int(tag[3]) ?? 1, 1) : 1
            if weights[pubkey] == nil { order.append(pubkey) }
            weights[pubkey, default: 0] += weight
            if relays[pubkey] == nil, tag.count >= 3, !tag[2].isEmpty { relays[pubkey] = tag[2] }
        }
        let total = order.reduce(0) { $0 + (weights[$1] ?? 0) }
        guard total > 0 else { return [Share(pubkey: authorPubkey, relay: nil, sats: price)] }
        return order.map { pubkey in
            let weight = weights[pubkey] ?? 1
            let sats = total == price ? weight : Int((Double(weight) / Double(total) * Double(price)).rounded(.up))
            return Share(pubkey: pubkey, relay: relays[pubkey], sats: sats)
        }
    }

    /// Relays the zap receipt should also land on, so the key server can find
    /// it: the ones the author named in their `zap` tags.
    var receiptRelays: [String] {
        var seen = Set<String>()
        return shares.compactMap(\.relay).filter { seen.insert($0.lowercased()).inserted }
    }

    /// The URL to send the key request to.
    ///
    /// Fanfares' tag names its backend, which wants a private API key; its web
    /// app reaches the backend through its own public proxy, and so must we.
    /// The NIP-98 `u` still names the tag's URL — that's what the proxy checks.
    var requestURL: URL {
        if keyURL.host?.lowercased() == "api.fanfares.live" {
            return URL(string: "https://fanfares.io/api" + keyURL.path) ?? keyURL
        }
        return keyURL
    }

    /// The tags of the NIP-98 (kind 27235) event that asks for the key. Its
    /// `content` is the article's naddr.
    var httpAuthTags: [[String]] {
        [["u", keyURL.absoluteString], ["method", "GET"]]
    }

    /// Decrypts the body with the key the server returned. nil when the key
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

    /// The NIP-19 `naddr` TLV payload for an article, entries in the order
    /// nostr-tools writes them (kind, author, relay, d), so the bech32 string
    /// we sign is byte-identical to the one Fanfares' own site signs.
    static func naddrTLV(identifier: String, relay: String?, pubkey: String, kind: Int) -> Data? {
        guard let author = Data(gatedHex: pubkey), author.count == 32 else { return nil }
        func entry(_ type: UInt8, _ value: Data) -> Data? {
            guard value.count <= 255 else { return nil }
            return Data([type, UInt8(value.count)]) + value
        }
        var k = UInt32(kind).bigEndian
        var out = Data([3, 4]) + Data(bytes: &k, count: 4)
        out += Data([2, 32]) + author
        if let relay, !relay.isEmpty, let r = entry(1, Data(relay.utf8)) { out += r }
        guard let d = entry(0, Data(identifier.utf8)) else { return nil }
        out += d
        return out
    }
}

/// Teaser text a gated article ships in `content`, minus the "zap to unlock …
/// <link>" call to action that the lock panel replaces.
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
