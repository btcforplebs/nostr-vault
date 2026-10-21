import CryptoKit
import Foundation

/// Mainnet address check for the Bitcoin sweep, which sends the whole balance
/// and cannot be undone. A truncated paste or a one-character slip must not
/// reach the broadcast.
///
/// Accepts what the Go sweep (haven-go/bitcoin.go, btcutil with MainNetParams)
/// can pay: P2PKH (1…), P2SH (3…), segwit v0 (bc1q…, 20 or 32 bytes, bech32)
/// and taproot (bc1p…, 32 bytes, bech32m). Testnet and regtest addresses,
/// later witness versions and anything failing its checksum are rejected.
///
/// Pure Foundation + CryptoKit so MediaLogicTests compiles it as-is.
enum BitcoinAddress {

    enum Kind: Equatable {
        case p2pkh, p2sh, p2wpkh, p2wsh, p2tr
    }

    /// The address with surrounding whitespace removed, if it is a valid
    /// mainnet address; nil otherwise. Send this, not the raw field text.
    static func normalizedMainnet(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return mainnetKind(trimmed) == nil ? nil : trimmed
    }

    static func mainnetKind(_ address: String) -> Kind? {
        if address.lowercased().hasPrefix("bc1") {
            return segwitKind(address)
        }
        return base58Kind(address)
    }

    // MARK: - Segwit (BIP173 / BIP350)

    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    private static let bech32Const = 1
    private static let bech32mConst = 0x2bc8_30a3

    private static func segwitKind(_ address: String) -> Kind? {
        guard address == address.lowercased() || address == address.uppercased(),
              address.count <= 90 else { return nil }
        let lower = address.lowercased()
        guard let separator = lower.lastIndex(of: "1"),
              String(lower[..<separator]) == "bc" else { return nil }

        var values = [Int]()
        for character in lower[lower.index(after: separator)...] {
            guard let index = charset.firstIndex(of: character) else { return nil }
            values.append(index)
        }
        guard values.count >= 7 else { return nil }

        let version = values[0]
        let check = polymod(hrpExpand("bc") + values)
        // v0 uses bech32; v1+ uses bech32m. The wrong one is a bad address.
        guard check == (version == 0 ? bech32Const : bech32mConst) else { return nil }
        guard let program = fiveToEight(Array(values.dropFirst().dropLast(6))) else { return nil }

        switch (version, program.count) {
        case (0, 20): return .p2wpkh
        case (0, 32): return .p2wsh
        case (1, 32): return .p2tr
        default: return nil
        }
    }

    private static func hrpExpand(_ hrp: String) -> [Int] {
        let scalars = hrp.unicodeScalars.map { Int($0.value) }
        return scalars.map { $0 >> 5 } + [0] + scalars.map { $0 & 31 }
    }

    private static func polymod(_ values: [Int]) -> Int {
        let generator = [0x3b6a_57b2, 0x2650_8e6d, 0x1ea1_19fa, 0x3d42_33dd, 0x2a14_62b3]
        var check = 1
        for value in values {
            let top = check >> 25
            check = ((check & 0x1ff_ffff) << 5) ^ value
            for index in 0..<5 where (top >> index) & 1 == 1 {
                check ^= generator[index]
            }
        }
        return check
    }

    /// 5-bit groups to bytes; leftover bits must be fewer than 5 and zero.
    private static func fiveToEight(_ values: [Int]) -> [UInt8]? {
        var accumulator = 0
        var bits = 0
        var bytes = [UInt8]()
        for value in values {
            accumulator = (accumulator << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((accumulator >> bits) & 0xff))
            }
        }
        guard bits < 5, (accumulator << (8 - bits)) & 0xff == 0 else { return nil }
        return bytes
    }

    // MARK: - Base58Check

    private static let base58Alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    private static func base58Kind(_ address: String) -> Kind? {
        guard (25...35).contains(address.count) else { return nil }

        // Big-endian base-58 to base-256, one digit at a time.
        var bytes = [UInt8]()
        for character in address {
            guard let digit = base58Alphabet.firstIndex(of: character) else { return nil }
            var carry = digit
            for index in bytes.indices.reversed() {
                carry += Int(bytes[index]) * 58
                bytes[index] = UInt8(carry & 0xff)
                carry >>= 8
            }
            while carry > 0 {
                bytes.insert(UInt8(carry & 0xff), at: 0)
                carry >>= 8
            }
        }
        let leadingZeros = address.prefix { $0 == "1" }.count
        bytes = [UInt8](repeating: 0, count: leadingZeros) + bytes.drop { $0 == 0 }

        guard bytes.count == 25 else { return nil }
        let body = Data(bytes[0..<21])
        let checksum = Array(SHA256.hash(data: Data(SHA256.hash(data: body)))).prefix(4)
        guard Array(checksum) == Array(bytes[21..<25]) else { return nil }

        switch bytes[0] {
        case 0x00: return .p2pkh
        case 0x05: return .p2sh
        default: return nil
        }
    }
}
