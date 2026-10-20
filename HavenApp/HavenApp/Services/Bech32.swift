import Foundation

// MARK: - Bech32 Encoding/Decoding

struct Bech32 {
    static let alphabet = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

    struct Result {
        let hrp: String
        let data: Data

        var hexString: String {
            return data.map { String(format: "%02x", $0) }.joined()
        }
    }

    static func decode(_ bechString: String) -> Result? {
        guard !bechString.isEmpty, bechString.count <= 1000 else { return nil } // Nevents can be long

        let lower = bechString.lowercased()
        guard let pos = lower.lastIndex(of: "1"), pos != lower.startIndex, pos != lower.index(before: lower.endIndex) else { return nil }

        let hrp = String(lower[..<pos])
        let dataString = String(lower[lower.index(after: pos)...])

        var data = [UInt8]()
        for char in dataString {
            guard let index = alphabet.firstIndex(of: char) else { return nil }
            data.append(UInt8(alphabet.distance(from: alphabet.startIndex, to: index)))
        }

        guard data.count >= 6 else { return nil }
        // For simplicity, we'll skip full checksum validation in this helper if it's for internal use,
        // but real Nostr libs use it.
        let coreData = Array(data.prefix(data.count - 6))

        // Convert from base32 (5-bit) to base256 (8-bit)
        guard let result = convertBits(data: coreData, from: 5, to: 8, pad: false) else { return nil }
        return Result(hrp: hrp, data: Data(result))
    }

    /// Whether `bechString` carries a valid bech32 checksum. `decode` skips
    /// it, so a mistyped or altered string still decodes to *something*;
    /// callers that will act on the payload (an LNURL to pay) check here.
    static func hasValidChecksum(_ bechString: String) -> Bool {
        let lower = bechString.lowercased()
        guard let pos = lower.lastIndex(of: "1"), pos != lower.startIndex else { return false }
        var data = [UInt8]()
        for char in lower[lower.index(after: pos)...] {
            guard let index = alphabet.firstIndex(of: char) else { return false }
            data.append(UInt8(alphabet.distance(from: alphabet.startIndex, to: index)))
        }
        guard data.count >= 6 else { return false }
        return polymod(expandHrp(String(lower[..<pos])) + data) == 1
    }

    static func encode(hrp: String, data: Data) -> String? {
        guard let converted = convertBits(data: Array(data), from: 8, to: 5, pad: true) else { return nil }

        // Simple Bech32 checksum (NIP-19 uses standard Bech32 for most, or Bech32m depending on spec,
        // but standard Bech32 is common for notes/npubs)
        let checksum = createChecksum(hrp: hrp, data: converted)
        let combined = converted + checksum

        var result = hrp + "1"
        for value in combined {
            let index = alphabet.index(alphabet.startIndex, offsetBy: Int(value))
            result.append(alphabet[index])
        }
        return result
    }

    // MARK: - TLV Helper
    /// One NIP-19 TLV entry, or nil when `data` is over 255 bytes: the length
    /// is a single byte. Relay-supplied values (a d tag) can be any length.
    static func tlvEntry(type: UInt8, data: Data) -> Data? {
        guard let length = UInt8(exactly: data.count) else { return nil }
        var result = Data([type, length])
        result.append(data)
        return result
    }

    /// Like `tlvEntry`, but an oversized entry is left out (empty Data)
    /// instead of trapping. Callers that must not lose the entry use
    /// `tlvEntry` and bail on nil.
    static func encodeTLV(type: UInt8, data: Data) -> Data {
        tlvEntry(type: type, data: data) ?? Data()
    }

    /// NIP-19 `nevent` for an event id and author (both hex). The kind entry
    /// is optional in NIP-19 and is left out when `kind` does not fit its
    /// 4 bytes; a relay can send any integer there.
    static func encodeNevent(idHex: String, pubkeyHex: String, kind: Int) -> String? {
        guard let idData = hexToData(idHex), let pubData = hexToData(pubkeyHex),
              let idEntry = tlvEntry(type: 0, data: idData),
              let authorEntry = tlvEntry(type: 2, data: pubData) else { return nil }
        var tlv = idEntry + authorEntry
        if let kind32 = UInt32(exactly: kind) {
            tlv.append(encodeTLV(type: 3, data: withUnsafeBytes(of: kind32.bigEndian) { Data($0) }))
        }
        return encode(hrp: "nevent", data: tlv)
    }

    // MARK: - Private Helpers

    private static func convertBits(data: [UInt8], from: Int, to: Int, pad: Bool) -> [UInt8]? {
        var acc = 0
        var bits = 0
        var result = [UInt8]()
        let maxv = (1 << to) - 1

        for value in data {
            acc = (acc << from) | Int(value)
            bits += from
            while bits >= to {
                bits -= to
                result.append(UInt8((acc >> bits) & maxv))
            }
        }

        if pad {
            if bits > 0 {
                result.append(UInt8((acc << (to - bits)) & maxv))
            }
        } else if bits >= from || ((acc << (to - bits)) & maxv) != 0 {
            return nil
        }

        return result
    }

    private static func createChecksum(hrp: String, data: [UInt8]) -> [UInt8] {
        let values = expandHrp(hrp) + data + [0, 0, 0, 0, 0, 0]
        let mod = polymod(values) ^ 1
        var result = [UInt8]()
        for i in 0..<6 {
            result.append(UInt8((mod >> (5 * (5 - i))) & 31))
        }
        return result
    }

    private static func expandHrp(_ hrp: String) -> [UInt8] {
        var result = [UInt8]()
        for char in hrp.utf8 {
            result.append(UInt8(char >> 5))
        }
        result.append(0)
        for char in hrp.utf8 {
            result.append(UInt8(char & 31))
        }
        return result
    }

    private static func polymod(_ values: [UInt8]) -> Int {
        let generator = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var chk = 1
        for value in values {
            let top = chk >> 25
            chk = (chk & 0x1ffffff) << 5 ^ Int(value)
            for i in 0..<5 {
                if (top >> i) & 1 == 1 {
                    chk ^= generator[i]
                }
            }
        }
        return chk
    }

    static func hexToData(_ hex: String) -> Data? {
        var data = Data()
        var tempHex = hex
        if tempHex.count % 2 != 0 { return nil }

        while !tempHex.isEmpty {
            let sub = tempHex.prefix(2)
            tempHex = String(tempHex.dropFirst(2))
            if let byte = UInt8(sub, radix: 16) {
                data.append(byte)
            } else {
                return nil
            }
        }
        return data
    }
}
