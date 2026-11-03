import Foundation
import CryptoKit

/// A private copy (Share Portal, lane B): a file kept encrypted in the
/// person's own vault, findable again from any of their devices.
///
/// - The file is sealed with AES-256-GCM under a fresh random key and nonce.
///   The blob is `ciphertext ‖ 16-byte tag` (the nonce is kept in the
///   record), so the vault only ever holds bytes nobody can read.
/// - The blob goes to this device's vault only: no outside Blossom server.
/// - The key lives in one NIP-78 record per copy (kind 30078), its content
///   this `Record` as JSON, NIP-44 encrypted to the account's own key, sent
///   to the vault only. The `d` tag is a random id, so the tags say nothing
///   about the file.
///
/// Pure, so it is unit tested against the shared fixtures
/// (`Fixtures/SharePortal/private-copy-cases.json`); Android's
/// PrivateCopyRecord.kt reads and writes the same bytes.
enum PrivateCopyRecord {
    static let kind = 30078
    static let dPrefix = "nv-private-copy:"
    static let algorithm = "aes-256-gcm"
    /// A bigger file is refused before it is read: sealing happens in memory.
    static let maxBytes = 100_000_000

    struct Record: Equatable {
        var name: String
        var mime: String
        /// Bytes of the file before sealing.
        var size: Int
        /// sha256 of the sealed blob: its name in the vault.
        var x: String
        /// sha256 of the file itself.
        var ox: String
        var key: String
        var nonce: String
        var source: String?
        var title: String?
        var savedAt: Int
    }

    // MARK: Event

    static func dTag(id: String) -> String { dPrefix + id }

    static func tags(id: String) -> [[String]] {
        [["d", dTag(id: id)], ["client", "Nostr Vault"], ["encryption", "nip44"]]
    }

    /// The same slot with nothing in it: the copy was deleted.
    static func clearedTags(id: String) -> [[String]] {
        [["d", dTag(id: id)], ["deleted", "true"]]
    }

    /// The copy id of a private-copy event, or nil when it is not one.
    static func id(kind: Int, tags: [[String]]) -> String? {
        guard kind == self.kind,
              let d = tags.first(where: { $0.count >= 2 && $0[0] == "d" })?[1],
              d.hasPrefix(dPrefix) else { return nil }
        let id = String(d.dropFirst(dPrefix.count))
        return NVShareLimits.isValidID(id) ? id : nil
    }

    static func isCleared(content: String, tags: [[String]]) -> Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || tags.contains { $0.count >= 2 && $0[0] == "deleted" && $0[1] == "true" }
    }

    /// NIP-44 output is base64 of a version byte 2 and more; anything else
    /// must never be published as a record.
    static func isCiphertext(_ s: String) -> Bool {
        guard let data = Data(base64Encoded: s), data.count >= 99 else { return false }
        return data.first == 2
    }

    // MARK: Record JSON

    static func encode(_ r: Record) -> String {
        var dict: [String: Any] = [
            "v": 1, "name": r.name, "mime": r.mime, "size": r.size, "x": r.x, "ox": r.ox,
            "alg": algorithm, "key": r.key, "nonce": r.nonce, "saved_at": r.savedAt,
        ]
        if let s = r.source { dict["source"] = s }
        if let t = r.title { dict["title"] = t }
        let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Decodes and validates a decrypted record. Nil for anything off.
    static func decode(_ json: String) -> Record? {
        guard let data = json.data(using: .utf8),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (d["v"] as? NSNumber)?.intValue == 1, d["alg"] as? String == algorithm,
              let name = d["name"] as? String, NVShareLimits.isValidFileName(name),
              let mime = d["mime"] as? String, !mime.isEmpty, mime.utf16.count <= 255,
              let size = (d["size"] as? NSNumber)?.intValue, size >= 0, size <= maxBytes,
              let x = d["x"] as? String, isHex(x, 64),
              let ox = d["ox"] as? String, isHex(ox, 64),
              let key = d["key"] as? String, isHex(key, 64),
              let nonce = d["nonce"] as? String, isHex(nonce, 24),
              let savedAt = (d["saved_at"] as? NSNumber)?.intValue else { return nil }
        let source = (d["source"] as? String).flatMap { NVShareLimits.cap($0, NVShareLimits.url) }
        let title = (d["title"] as? String).flatMap { NVShareLimits.cap($0, NVShareLimits.title) }
        return Record(name: name, mime: mime, size: size, x: x.lowercased(), ox: ox.lowercased(),
                      key: key.lowercased(), nonce: nonce.lowercased(), source: source, title: title, savedAt: savedAt)
    }

    // MARK: Sealing

    struct Sealed {
        let blob: Data
        let key: String
        let nonce: String
        let x: String
        let ox: String
    }

    /// Seals `plain` under a new random key and nonce.
    static func seal(_ plain: Data) throws -> Sealed {
        let key = SymmetricKey(size: .bits256)
        let nonce = AES.GCM.Nonce()
        return try seal(plain, key: key.withUnsafeBytes { Data($0) }, nonce: Data(nonce))
    }

    /// Seals with a given key and nonce. For the fixtures; the app always
    /// uses `seal(_:)`.
    static func seal(_ plain: Data, key: Data, nonce: Data) throws -> Sealed {
        let box = try AES.GCM.seal(plain, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce))
        let blob = box.ciphertext + box.tag
        return Sealed(blob: blob, key: hex(key), nonce: hex(nonce), x: sha256(blob), ox: sha256(plain))
    }

    enum OpenError: Error { case badRecord, wrongBlob, wrongFile }

    /// The file back from its blob. Refuses a blob or file whose hash is
    /// not the record's.
    static func open(_ blob: Data, record: Record) throws -> Data {
        guard sha256(blob) == record.x else { throw OpenError.wrongBlob }
        guard let key = unhex(record.key), let nonceData = unhex(record.nonce), blob.count >= 16 else {
            throw OpenError.badRecord
        }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceData),
                                        ciphertext: blob.dropLast(16), tag: blob.suffix(16))
        let plain = try AES.GCM.open(box, using: SymmetricKey(data: key))
        guard sha256(plain) == record.ox else { throw OpenError.wrongFile }
        return plain
    }

    // MARK: Hex

    static func sha256(_ data: Data) -> String { hex(Data(SHA256.hash(data: data))) }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static func unhex(_ s: String) -> Data? {
        guard s.count % 2 == 0 else { return nil }
        var out = Data(capacity: s.count / 2)
        var it = s.makeIterator()
        while let a = it.next(), let b = it.next() {
            guard let byte = UInt8(String([a, b]), radix: 16) else { return nil }
            out.append(byte)
        }
        return out
    }

    static func isHex(_ s: String, _ count: Int) -> Bool {
        s.count == count && s.allSatisfy { $0.isHexDigit && $0.isASCII }
    }
}
