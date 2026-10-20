import Foundation

/// Checksum-validating decode for the one place a bad npub does lasting damage:
/// the auto-follow list, whose entries are published as p-tags in a signed
/// kind-3 contact list.
///
/// `Bech32.decode` in WebSocketClient.swift deliberately skips checksum
/// validation, and for most of its callers that is fine — a malformed nevent
/// simply fails to resolve and nothing is written down. A malformed npub in the
/// follow list is different: it decodes to *something*, and that something is
/// published to relays under the user's key and stays in their contact list.
///
/// Both failure modes are real and both are in the shipped starter packs:
///   - a typo'd npub still yields 32 plausible bytes, so the user follows a
///     pubkey nobody chose;
///   - an npub containing a later "1" splits at the wrong separator, because
///     the decoder takes the *last* one, and yields a 3-byte "pubkey" that goes
///     into a p-tag as-is.
///
/// Keeping this self-contained (no dependency on Bech32) is deliberate: it is
/// mirrored into MediaLogicTests so the rule is covered by tests.
enum NpubValidation {

    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")

    /// The 32-byte hex pubkey for a well-formed `npub1…`, or nil.
    ///
    /// Rejects a wrong human-readable part, a failed checksum, and any payload
    /// that is not exactly 32 bytes.
    static func hexPubkey(fromNpub npub: String) -> String? {
        hexKey(npub, hrp: "npub")
    }

    /// The 32-byte hex secret key for a well-formed `nsec1…`, or nil.
    ///
    /// Same rules as `hexPubkey(fromNpub:)`. A mistyped nsec still decodes to
    /// 32 bytes under the lenient decoder, and importing it replaces the
    /// stored key with one nobody owns.
    static func hexSecretKey(fromNsec nsec: String) -> String? {
        hexKey(nsec, hrp: "nsec")
    }

    private static func hexKey(_ bech32: String, hrp: String) -> String? {
        let trimmed = bech32.trimmingCharacters(in: .whitespacesAndNewlines)

        // Mixed case is not merely ugly, it makes the checksum meaningless.
        guard trimmed == trimmed.lowercased() || trimmed == trimmed.uppercased() else { return nil }
        let lower = trimmed.lowercased()

        // The separator is the last "1", but the human-readable part must still
        // be exactly the expected one — that is what catches an npub with a
        // stray "1" in its payload, which otherwise splits in the wrong place.
        guard let separator = lower.lastIndex(of: "1") else { return nil }
        guard String(lower[..<separator]) == hrp else { return nil }

        let payload = lower[lower.index(after: separator)...]
        var values = [Int]()
        values.reserveCapacity(payload.count)
        for character in payload {
            guard let index = charset.firstIndex(of: character) else { return nil }
            values.append(index)
        }
        guard values.count > 6 else { return nil }

        guard checksum(hrp: hrp, values: values) == 1 else { return nil }

        // Drop the 6 checksum characters, then 5-bit groups back to bytes. The
        // remainder bits must be zero padding, or the string is not a faithful
        // encoding of the bytes it claims.
        var accumulator = 0
        var bits = 0
        var bytes = [UInt8]()
        for value in values.dropLast(6) {
            accumulator = (accumulator << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((accumulator >> bits) & 0xff))
            }
        }
        guard bits < 5, (accumulator << (8 - bits)) & 0xff == 0 else { return nil }
        guard bytes.count == 32 else { return nil }

        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Keeps the well-formed npubs, in order, dropping duplicates.
    static func validNpubs(_ npubs: [String]) -> [String] {
        var seenHex = Set<String>()
        return npubs.filter { npub in
            guard let hex = hexPubkey(fromNpub: npub) else { return false }
            return seenHex.insert(hex).inserted
        }
    }

    private static func checksum(hrp: String, values: [Int]) -> Int {
        var input = hrp.unicodeScalars.map { Int($0.value) >> 5 }
        input.append(0)
        input += hrp.unicodeScalars.map { Int($0.value) & 31 }
        input += values
        return polymod(input)
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
}
