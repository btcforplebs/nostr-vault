// Sources/SilentPaymentsKit/Core/Bech32m.swift
//
// Bech32m codec per BIP-350.
// Silent Payment addresses use bech32m with HRP "sp" and version byte 0x00.
// Format: sp1 || bech32m( [0x00] || scanPub[33] || spendPub[33] ) = 66 data bytes

import Foundation

// MARK: - Bech32m

public enum Bech32m {

    static let charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
    static let generator: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
    static let bech32mConst: UInt32 = 0x2bc830a3

    // MARK: Encode

    /// Encode `data` (5-bit groups) with the given HRP.
    public static func encode(hrp: String, data: [UInt8]) -> String {
        var combined = data
        combined.append(contentsOf: createChecksum(hrp: hrp, data: data))
        var result = hrp + "1"
        for byte in combined {
            result.append(charset[charset.index(charset.startIndex, offsetBy: Int(byte))])
        }
        return result
    }

    // MARK: Decode

    public static func decode(_ str: String) throws -> (hrp: String, data: [UInt8]) {
        let lower = str.lowercased()
        guard let sep = lower.lastIndex(of: "1") else {
            throw SilentPaymentError.bech32DecodingFailed
        }
        let hrp   = String(lower[..<sep])
        let dataPart = String(lower[lower.index(after: sep)...])

        var data = [UInt8]()
        for c in dataPart {
            guard let idx = charset.firstIndex(of: c) else {
                throw SilentPaymentError.bech32DecodingFailed
            }
            data.append(UInt8(charset.distance(from: charset.startIndex, to: idx)))
        }

        guard data.count >= 6 else { throw SilentPaymentError.bech32DecodingFailed }
        guard verifyChecksum(hrp: hrp, data: data) else {
            throw SilentPaymentError.bech32DecodingFailed
        }
        return (hrp, Array(data.dropLast(6)))
    }

    // MARK: Silent Payment specific helpers

    /// Encode a silent payment address from scan + spend public keys.
    /// version byte 0 prepended before conversion to 5-bit groups.
    public static func encodeSilentPayment(scanPubKey: Data, spendPubKey: Data) throws -> String {
        guard scanPubKey.count == 33, spendPubKey.count == 33 else {
            throw SilentPaymentError.bech32EncodingFailed
        }
        var payload = Data([0x00])   // version byte
        payload.append(scanPubKey)
        payload.append(spendPubKey)
        // convertbits: 8 → 5
        let fiveBit = try convertBits(Array(payload), from: 8, to: 5, pad: true)
        return encode(hrp: "sp", data: fiveBit)
    }

    /// Decode a silent payment address into (scanPubKey: 33B, spendPubKey: 33B).
    public static func decodeSilentPayment(_ address: String) throws -> (scanPubKey: Data, spendPubKey: Data) {
        let (hrp, data) = try decode(address)
        guard hrp == "sp" else {
            throw SilentPaymentError.invalidAddress("HRP must be 'sp', got '\(hrp)'")
        }
        guard !data.isEmpty, data[0] == 0 else {
            throw SilentPaymentError.invalidAddress("Unknown version byte")
        }
        let eightBit = try convertBits(Array(data.dropFirst()), from: 5, to: 8, pad: false)
        guard eightBit.count == 66 else {
            throw SilentPaymentError.invalidAddress("Expected 66 payload bytes, got \(eightBit.count)")
        }
        let scanPub  = Data(eightBit[0..<33])
        let spendPub = Data(eightBit[33..<66])
        return (scanPub, spendPub)
    }

    // MARK: Internal

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        var chk: UInt32 = 1
        for v in values {
            let top = chk >> 25
            chk = (chk & 0x1ffffff) << 5 ^ UInt32(v)
            for i in 0..<5 {
                chk ^= ((top >> i) & 1) != 0 ? generator[i] : 0
            }
        }
        return chk
    }

    private static func hrpExpand(_ hrp: String) -> [UInt8] {
        var result = hrp.unicodeScalars.map { UInt8($0.value >> 5) }
        result.append(0)
        result += hrp.unicodeScalars.map { UInt8($0.value & 31) }
        return result
    }

    private static func createChecksum(hrp: String, data: [UInt8]) -> [UInt8] {
        var values = hrpExpand(hrp) + data + [0, 0, 0, 0, 0, 0]
        let polymod = self.polymod(values) ^ bech32mConst
        return (0..<6).map { UInt8((polymod >> (5 * (5 - $0))) & 31) }
    }

    private static func verifyChecksum(hrp: String, data: [UInt8]) -> Bool {
        return polymod(hrpExpand(hrp) + data) == bech32mConst
    }

    static func convertBits(_ data: [UInt8], from: Int, to: Int, pad: Bool) throws -> [UInt8] {
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
            throw SilentPaymentError.bech32DecodingFailed
        }
        return result
    }
}
