import Foundation
import CryptoKit

/// An Iris hashtree photo link in a note: `htree://nhash1…/<name>`.
///
/// The nhash (bech32, TLV 0 = the encrypted blob's sha256, 5 = the key) is a
/// permalink to one encrypted blob. Phase 1 reads only what a photo up to
/// 2 MiB is: one blob, CHK-encrypted, where the key IS the sha256 of the
/// plain file. So the link already names the photo the way Blossom does, and
/// the vault keeps it under that hash. A 33-byte key starts with its suite
/// byte (1 = chk-v1); a 32-byte one is legacy CHK. rnd-v1 keys (no plain hash
/// in the link), links without a key, and chunked files or folders (phase 2)
/// are not read: they stay text.
///
/// Source: hashtree c5e41a5 `docs/HTS-01.md`, `ts/packages/hashtree/src/
/// {nhash,encryption,crypto}.ts`. Web: `web-vault/src/net/htree.js`.
/// Fixture: `docs/HTREE_VECTORS.json`.
struct HtreeLink: Equatable {
    /// sha256 of the encrypted blob: what a server is asked for.
    var blobHash: String
    /// The 32-byte CHK key, which is the plain file's sha256.
    var chk: Data
    /// The file name after the nhash, decoded; may be empty.
    var name: String

    /// The plain file's sha256: its Blossom name, and the vault's.
    var sha256: String { chk.map { String(format: "%02x", $0) }.joined() }
    /// Lowercase, no dot; "" when the name has none.
    var ext: String { (name as NSString).pathExtension.lowercased() }

    static let scheme = "htree"
    /// Iris's own upload server: every htree photo seen so far is only there.
    static let irisServers = ["https://upload.iris.to"]
    /// Phase 1 reads one blob: a photo up to 2 MiB, plus the GCM tag.
    static let maxPlainBytes = 2 << 20
    static let maxBlobBytes = maxPlainBytes + 16

    /// `htree://` links in a note's text, with their file name.
    static let regex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"htree://nhash1[02-9ac-hj-np-z]{20,}(?:/[^\s<>"]*)?"#,
        options: .caseInsensitive
    )

    static func isURI(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme
    }

    /// nil for anything phase 1 can't show.
    init?(_ url: URL) {
        guard Self.isURI(url) else { return nil }
        let rest = url.absoluteString.dropFirst(Self.scheme.count + 3)
        let parts = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let code = String(parts[0]).lowercased()
        guard code.hasPrefix("nhash1"), Bech32.hasValidChecksum(code),
              let decoded = Bech32.decode(code), decoded.hrp == "nhash",
              let tlv = Self.parse(decoded.data),
              let key = tlv.key
        else { return nil }
        switch key.count {
        case 32: chk = key
        case 33 where key.first == 1: chk = key.dropFirst()
        default: return nil
        }
        chk = Data(chk)
        blobHash = tlv.hash
        let rawName = parts.count > 1 ? String(parts[1].split(whereSeparator: { $0 == "?" || $0 == "#" }).first ?? "") : ""
        name = rawName.removingPercentEncoding ?? rawName
    }

    /// The nhash's TLV: hash (hex) and key, or nil when malformed.
    static func parse(_ data: Data) -> (hash: String, key: Data?)? {
        let bytes = [UInt8](data)
        if bytes.count == 32 { return (bytes.map { String(format: "%02x", $0) }.joined(), nil) }
        var hash: String?, key: Data?, at = 0
        while at < bytes.count {
            guard at + 2 <= bytes.count else { return nil }
            let t = bytes[at], l = Int(bytes[at + 1])
            at += 2
            guard at + l <= bytes.count else { return nil }
            let value = Array(bytes[at..<at + l])
            at += l
            if t == 0, l == 32, hash == nil { hash = value.map { String(format: "%02x", $0) }.joined() }
            if t == 5, key == nil { key = Data(value) }
        }
        return hash.map { ($0, key) }
    }

    /// Where to ask, in order: Iris, the author's list, ours. Each is
    /// `<server>/<blob hash>`, once each, https only.
    func candidates(authorServers: [String], ownServers: [String]) -> [URL] {
        var seen = Set<String>()
        return (Self.irisServers + authorServers + ownServers).compactMap(BlossomURI.serverURL).compactMap { base in
            let blob = base.appendingPathComponent(blobHash)
            return seen.insert(blob.absoluteString.lowercased()).inserted ? blob : nil
        }
    }

    /// The photo from a fetched blob: checked against the blob hash,
    /// decrypted, checked against the plain hash, and only when it is a
    /// picture. nil for anything else.
    func open(_ blob: Data) -> (data: Data, mime: String)? {
        guard blob.count <= Self.maxBlobBytes, Self.hex(SHA256.hash(data: blob)) == blobHash,
              let plain = Self.decryptChk(blob, key: chk),
              Self.hex(SHA256.hash(data: plain)) == sha256,
              let mime = Self.sniffImage(plain)
        else { return nil }
        return (plain, mime)
    }

    /// CHK decrypt: AES-256-GCM, key HKDF-SHA256(chk, salt "hashtree-chk",
    /// info "encryption-key"), all-zero nonce, tag at the end.
    static func decryptChk(_ cipher: Data, key chk: Data) -> Data? {
        guard cipher.count >= 16 else { return nil }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: chk),
                                         salt: Data("hashtree-chk".utf8),
                                         info: Data("encryption-key".utf8),
                                         outputByteCount: 32)
        guard let nonce = try? AES.GCM.Nonce(data: Data(count: 12)),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: cipher.dropLast(16), tag: cipher.suffix(16))
        else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    /// "image/…" from the first bytes, or nil: only pictures are drawn,
    /// whatever the name says.
    static func sniffImage(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(12))
        let ascii = { (from: Int, to: Int) -> String in
            b.count >= to ? String(decoding: b[from..<to], as: UTF8.self) : ""
        }
        if b.count >= 3, b[0] == 0xff, b[1] == 0xd8, b[2] == 0xff { return "image/jpeg" }
        if b.count >= 8, b[0..<8] == [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] { return "image/png" }
        if ascii(0, 6) == "GIF87a" || ascii(0, 6) == "GIF89a" { return "image/gif" }
        if ascii(0, 4) == "RIFF", ascii(8, 12) == "WEBP" { return "image/webp" }
        if ascii(4, 8) == "ftyp", ["avif", "avis"].contains(ascii(8, 12)) { return "image/avif" }
        return nil
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
