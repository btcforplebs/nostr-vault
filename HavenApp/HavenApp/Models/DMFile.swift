import Foundation
import CryptoKit

/// A photo in a DM as a NIP-17 kind 15 file message (DM privacy, Tron 2026-11-14; the twin of web-vault
/// `net/dm-file.js`, PR #2075). A plain photo link in a DM is public: anyone with the link sees the photo. So the
/// file is encrypted with a fresh AES-GCM key before it goes up; the server holds only ciphertext, named by its
/// hash (`x`), and the key and nonce travel inside the sealed message, where only the two people can read them.
///
/// On this device a file message is kept as its link with what opens it in the fragment
/// (`<url>#nv-dm=<base64url JSON>`): the thread, the inbox and the cache carry a message as text, and a fragment
/// never leaves in a request. `DM_FILE_VECTORS.json` (Fixtures/DMFile) is the shared fixture with Android and web.
enum DMFile {
    static let marker = "#nv-dm="
    /// A download stops here: a link from someone that streams forever must not fill the phone (web: MAX_FILE).
    static let maxFileBytes = 60 * 1024 * 1024
    /// A video goes out at most this big once compressed (DM videos, Logen 2026-11-15): the send says so when it
    /// isn't, and a received video downloads up to this plus its 16-byte GCM tag.
    static let maxVideoBytes = 100 * 1024 * 1024

    static func videoFits(byteCount: Int) -> Bool { byteCount <= maxVideoBytes }

    /// Where a download of this file stops (photos keep the web's MAX_FILE).
    static func maxDownloadBytes(_ s: Sealed) -> Int { s.isVideo ? maxVideoBytes + 16 : maxFileBytes }

    /// The extension an opened copy is kept under, so the image and video readers know what it is.
    static func fileExtension(_ mime: String) -> String {
        switch mime.lowercased() {
        case "image/gif": return "gif"
        case "image/png": return "png"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        case let m where m.hasPrefix("image/"): return "jpg"
        case "video/quicktime": return "mov"
        case "video/webm": return "webm"
        case let m where m.hasPrefix("video/"): return "mp4"
        default: return "bin"
        }
    }

    /// What opens a file message: where it is and its key, nonce, hashes and type.
    struct Sealed: Equatable {
        let url: URL
        let key: String
        let nonce: String
        /// sha256 of the ciphertext (what the server holds); checked before decrypting.
        let x: String?
        /// sha256 of the original file; checked after decrypting.
        let ox: String?
        let mime: String

        var isImage: Bool { mime.lowercased().hasPrefix("image/") }
        var isVideo: Bool { mime.lowercased().hasPrefix("video/") }
    }

    /// A file encrypted for sending. Hex strings, lowercase.
    struct Encrypted {
        let cipher: Data
        let key: String
        let nonce: String
        let x: String
        let ox: String
    }

    enum Refusal: Error, Equatable {
        case algorithm, key, nonce, x, decrypt, ox, tooLarge
    }

    // MARK: Crypto

    /// Encrypt with a fresh 256-bit key and 96-bit nonce (12 bytes, as the web sends).
    static func encrypt(_ plain: Data) throws -> Encrypted {
        try encrypt(plain, key: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }, nonce: AES.GCM.Nonce().withUnsafeBytes { Data($0) })
    }

    /// Encrypt with the given key and nonce (tests check fixed vectors with this). Ciphertext = encrypted bytes || 16-byte tag, no AAD.
    static func encrypt(_ plain: Data, key: Data, nonce: Data) throws -> Encrypted {
        guard key.count == 32 else { throw Refusal.key }
        guard let n = try? AES.GCM.Nonce(data: nonce) else { throw Refusal.nonce }
        let box = try AES.GCM.seal(plain, using: SymmetricKey(data: key), nonce: n)
        let cipher = box.ciphertext + box.tag
        return Encrypted(cipher: cipher, key: hex(key), nonce: hex(nonce), x: sha256Hex(cipher), ox: sha256Hex(plain))
    }

    /// The original bytes. Refuses in the fixture's order: x (when given), then the GCM tag, then ox (when given).
    static func decrypt(_ cipher: Data, key: String, nonce: String, x: String?, ox: String?) throws -> Data {
        guard isHex64(key), let k = unhex(key) else { throw Refusal.key }
        guard isNonce(nonce), let nb = unhex(nonce), let n = try? AES.GCM.Nonce(data: nb) else { throw Refusal.nonce }
        if let x, sha256Hex(cipher) != x.lowercased() { throw Refusal.x }
        guard cipher.count >= 16 else { throw Refusal.decrypt }
        let plain: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: n, ciphertext: cipher.dropLast(16), tag: cipher.suffix(16))
            plain = try AES.GCM.open(box, using: SymmetricKey(data: k))
        } catch { throw Refusal.decrypt }
        if let ox, sha256Hex(plain) != ox.lowercased() { throw Refusal.ox }
        return plain
    }

    static func decrypt(_ cipher: Data, _ sealed: Sealed) throws -> Data {
        try decrypt(cipher, key: sealed.key, nonce: sealed.nonce, x: sealed.x, ox: sealed.ox)
    }

    // MARK: Message

    /// What an unwrapped NIP-17 rumor reads as on this device: a kind 14 its text, a kind 15 its file link (or bare
    /// URL); nil for any other kind, or a kind 15 that names no https file (not a message).
    static func messageContent(kind: Int, content: String, tags: [[String]]) -> String? {
        switch kind {
        case 14: return content
        case 15: return Self.content(ofRumorContent: content, tags: tags)
        default: return nil
        }
    }

    /// The kind 15 rumor's file tags (after its p tag), in the web's order.
    static func tags(_ enc: Encrypted, mime: String, dim: String? = nil) -> [[String]] {
        var tags: [[String]] = [
            ["file-type", isMime(mime) ? mime : "application/octet-stream"],
            ["encryption-algorithm", "aes-gcm"],
            ["decryption-key", enc.key],
            ["decryption-nonce", enc.nonce],
            ["x", enc.x],
            ["ox", enc.ox],
            ["size", String(enc.cipher.count)],
        ]
        if let dim { tags.append(["dim", dim]) }
        return tags
    }

    /// A received kind 15 as this device keeps it: its link with what opens it; the bare URL when it isn't encrypted
    /// the way this reads (it then shows as an old photo link would); nil when its content isn't an https URL.
    static func content(ofRumorContent content: String, tags: [[String]]) -> String? {
        let raw = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isBareHTTPS(raw), let url = URL(string: raw) else { return nil }
        func tag(_ name: String) -> String? { tags.first { $0.count >= 2 && $0[0] == name }?[1] }
        let alg = (tag("encryption-algorithm") ?? "").lowercased()
        let key = (tag("decryption-key") ?? "").lowercased(), nonce = (tag("decryption-nonce") ?? "").lowercased()
        guard alg == "aes-gcm", isHex64(key), isNonce(nonce) else { return raw }
        let x = (tag("x") ?? "").lowercased(), ox = (tag("ox") ?? "").lowercased()
        let mime = tag("file-type") ?? ""
        return link(Sealed(url: url, key: key, nonce: nonce, x: isHex64(x) ? x : nil, ox: isHex64(ox) ? ox : nil,
                           mime: isMime(mime) ? mime : "application/octet-stream"))
    }

    // MARK: Link

    /// "<url>#nv-dm=…": the message as this device keeps and shows it. The web keeps {k,n,x,m}; this adds o (ox).
    static func link(_ s: Sealed) -> String {
        var fields = ["\"k\":\"\(s.key)\"", "\"n\":\"\(s.nonce)\""]
        if let x = s.x { fields.append("\"x\":\"\(x)\"") }
        fields.append("\"m\":\"\(s.mime)\"")
        if let ox = s.ox { fields.append("\"o\":\"\(ox)\"") }
        return s.url.absoluteString + marker + base64url("{" + fields.joined(separator: ",") + "}")
    }

    static func isLink(_ s: String) -> Bool {
        guard let r = s.range(of: marker), isBareHTTPS(String(s[..<r.lowerBound])) else { return false }
        let tail = s[r.upperBound...]
        return !tail.isEmpty && tail.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func parseLink(_ s: String) -> Sealed? {
        guard isLink(s), let r = s.range(of: marker), let url = URL(string: String(s[..<r.lowerBound])),
              let json = unbase64url(String(s[r.upperBound...])),
              let d = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let k = d["k"] as? String, isHex64(k), let n = d["n"] as? String, isNonce(n) else { return nil }
        let x = d["x"] as? String, ox = d["o"] as? String
        if let x, !isHex64(x) { return nil }
        if let ox, !isHex64(ox) { return nil }
        let m = d["m"] as? String ?? ""
        return Sealed(url: url, key: k, nonce: n, x: x, ox: ox, mime: isMime(m) ? m : "application/octet-stream")
    }

    /// The name this device keeps an opened copy under: the hash, key and nonce together, not the hash alone.
    /// AES-GCM doesn't tie a ciphertext to one key, so a message naming a hash already opened in another chat
    /// must not be handed that chat's photo.
    static func openedName(_ s: Sealed) -> String {
        sha256Hex(Data(((s.x ?? s.url.absoluteString) + "|" + s.key + "|" + s.nonce).utf8))
    }

    /// The message as a preview or a notification shows it: a file link becomes "Photo", "Video" or "File", so the key in
    /// its fragment is never drawn on a lock screen.
    static func displayText(_ content: String) -> String {
        guard content.contains(marker) else { return content }
        return content.components(separatedBy: "\n").map { line in
            line.split(separator: " ", omittingEmptySubsequences: false).map { word in
                guard let s = parseLink(String(word)) else { return String(word) }
                return s.isImage ? String(localized: "Photo") : s.isVideo ? String(localized: "Video") : String(localized: "File")
            }.joined(separator: " ")
        }.joined(separator: "\n")
    }

    // MARK: Helpers

    static func sha256Hex(_ d: Data) -> String { hex(Data(SHA256.hash(data: d))) }
    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    static func unhex(_ s: String) -> Data? {
        guard s.count % 2 == 0 else { return nil }
        var out = Data(capacity: s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }

    private static func isHexChars(_ s: String) -> Bool { s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) } }
    static func isHex64(_ s: String) -> Bool { s.count == 64 && isHexChars(s) }
    /// 12 bytes (ours, and GCM's usual) or 16 (Amethyst and some other NIP-17 apps), as the web reads.
    static func isNonce(_ s: String) -> Bool { (s.count == 24 || s.count == 32) && isHexChars(s) }
    private static func isMime(_ s: String) -> Bool {
        s.range(of: "^[a-zA-Z]+/[a-zA-Z0-9.+-]+$", options: .regularExpression) != nil
    }
    private static func isBareHTTPS(_ s: String) -> Bool {
        s.range(of: "^https://[^\\s#]+$", options: .regularExpression) != nil
    }
    private static func base64url(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    private static func unbase64url(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }
}
