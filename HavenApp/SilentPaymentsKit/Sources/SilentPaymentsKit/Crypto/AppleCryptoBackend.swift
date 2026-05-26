// Sources/SilentPaymentsKit/Crypto/AppleCryptoBackend.swift
//
// Backend using Apple's CryptoKit + manual field arithmetic.
// Zero external dependencies — ships with every iOS/macOS device.
//
// ⚠️  CryptoKit does NOT expose raw secp256k1 point multiplication publicly.
//     It uses P-256 (NIST) for ECDH, not secp256k1.
//     This backend implements the secp256k1 field arithmetic we need in pure Swift
//     for the operations CryptoKit can't do, and delegates SHA-256 to CryptoKit.
//
//     The pure-Swift secp256k1 math here is derived from the well-audited
//     reference implementation in bip340-py / noble-secp256k1.
//     This backend is suitable for: unit tests, simulator builds, CI without
//     external package dependencies.

import Foundation
import CryptoKit

public struct AppleCryptoBackend: Secp256k1Backend {

    public init() {}

    // secp256k1 field parameters
    private static let p = FieldElement(
        hex: "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F")!
    private static let n = FieldElement(
        hex: "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141")!
    private static let Gx = FieldElement(
        hex: "79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798")!
    private static let Gy = FieldElement(
        hex: "483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8")!
    private static let G  = Point(x: Gx, y: Gy)

    // MARK: - Keys

    public func privateKeyToPublicKey(_ privateKey: Data) throws -> Data {
        let k = try scalarFromData(privateKey)
        let P = try Self.G.multiply(k)
        return try P.toCompressed()
    }

    public func negatePrivateKey(_ privateKey: Data) throws -> Data {
        let k = try scalarFromData(privateKey)
        let neg = (Self.n.value - k) % Self.n.value
        return padTo32(neg)
    }

    // MARK: - Scalar ops on private keys

    public func addTweakToPrivateKey(_ privateKey: Data, tweak: Data) throws -> Data {
        let k = try scalarFromData(privateKey)
        let t = try scalarFromData(tweak)
        let result = (k + t) % Self.n.value
        guard result != 0 else { throw SilentPaymentError.tweakFailed }
        return padTo32(result)
    }

    public func multiplyPrivateKey(_ privateKey: Data, scalar: Data) throws -> Data {
        let k = try scalarFromData(privateKey)
        let s = try scalarFromData(scalar)
        let result = (k * s) % Self.n.value
        guard result != 0 else { throw SilentPaymentError.tweakFailed }
        return padTo32(result)
    }

    public func sumPrivateKeys(_ privateKeys: [Data]) throws -> Data {
        guard !privateKeys.isEmpty else { throw SilentPaymentError.invalidPrivateKey }
        var acc: BigUInt = []
        for key in privateKeys {
            acc = (acc + (try scalarFromData(key))) % Self.n.value
        }
        guard acc != 0 else { throw SilentPaymentError.invalidPrivateKey }
        return padTo32(acc)
    }

    // MARK: - Scalar ops on public keys

    public func addTweakToPublicKey(_ publicKey: Data, tweak: Data) throws -> Data {
        let P  = try parseCompressed(publicKey)
        let t  = try scalarFromData(tweak)
        let tG = try Self.G.multiply(t)
        let Q  = try P.add(tG)
        return try Q.toCompressed()
    }

    public func multiplyPublicKey(_ publicKey: Data, scalar: Data) throws -> Data {
        let P = try parseCompressed(publicKey)
        let s = try scalarFromData(scalar)
        let Q = try P.multiply(s)
        return try Q.toCompressed()
    }

    public func combinePublicKeys(_ keys: [Data]) throws -> Data {
        guard !keys.isEmpty else { throw SilentPaymentError.invalidPublicKey }
        var acc = try parseCompressed(keys[0])
        for keyData in keys.dropFirst() {
            let next = try parseCompressed(keyData)
            acc = try acc.add(next)
        }
        return try acc.toCompressed()
    }

    public func subtractPublicKeys(_ a: Data, _ b: Data) throws -> Data {
        let A  = try parseCompressed(a)
        let B  = try parseCompressed(b)
        let nB = B.negate()
        return try A.add(nB).toCompressed()
    }

    // MARK: - Predicates

    public func hasOddY(_ publicKey: Data) -> Bool {
        publicKey.count == 33 && publicKey[0] == 0x03
    }

    // MARK: - Signing (Schnorr BIP-340 — simplified, not constant time)

    public func schnorrSign(message: Data, privateKey: Data) throws -> Data {
        guard message.count == 32 else { throw SilentPaymentError.invalidPrivateKey }
        var d = try scalarFromData(privateKey)
        let P = try Self.G.multiply(d)
        // Negate if odd Y
        if P.y.value % 2 != 0 {
            d = (Self.n.value - d) % Self.n.value
        }
        // k = H_BIP340/nonce(bytes(d) || m)
        var nonceInput = padTo32(d) + message
        let kHash = Data(SHA256.hash(data: nonceInput))   // simplified; BIP-340 uses tagged hash
        var k = BigUInt(kHash.map { $0 }) % Self.n.value
        let R = try Self.G.multiply(k)
        if R.y.value % 2 != 0 {
            k = (Self.n.value - k) % Self.n.value
        }
        let rx = padTo32(R.x.value)
        // e = H_BIP340/challenge(bytes(R) || bytes(P) || m)
        let Pcompressed = try P.toCompressed()
        let ePre = rx + Pcompressed.dropFirst() + message  // simplified
        let eHash = Data(SHA256.hash(data: ePre))
        let e = BigUInt(eHash.map { $0 }) % Self.n.value
        let s = (k + e * d) % Self.n.value
        return rx + padTo32(s)
    }

    // MARK: - Internal types

    // Minimal big integer using [UInt64] limbs (little-endian, base 2^64)
    // Sufficient for secp256k1 256-bit arithmetic.
    typealias BigUInt = [UInt64]

    struct FieldElement {
        let value: BigUInt

        init(_ v: BigUInt) { self.value = v }
        init?(hex: String) {
            guard let v = BigUInt(hexString: hex) else { return nil }
            self.value = v
        }
    }

    struct Point {
        let x: FieldElement
        let y: FieldElement
        var isInfinity: Bool { x.value.isEmpty && y.value.isEmpty }

        static let infinity = Point(x: FieldElement([]), y: FieldElement([]))

        func negate() -> Point {
            guard !isInfinity else { return self }
            let ny = modSub([0], y.value, p: AppleCryptoBackend.p.value)
            return Point(x: x, y: FieldElement(ny))
        }

        func toCompressed() throws -> Data {
            let prefix: UInt8 = (y.value.last ?? 0) % 2 == 0 ? 0x02 : 0x03
            var bytes = [prefix]
            bytes.append(contentsOf: bigUIntToBytes(x.value, length: 32))
            return Data(bytes)
        }

        func add(_ other: Point) throws -> Point {
            if isInfinity { return other }
            if other.isInfinity { return self }
            let p = AppleCryptoBackend.p.value
            if x.value == other.x.value {
                if y.value == other.y.value { return try double() }
                return .infinity
            }
            // λ = (y2-y1) * modInv(x2-x1)
            let dy = modSub(other.y.value, y.value, p: p)
            let dx = modSub(other.x.value, x.value, p: p)
            let lam = modMul(dy, modInv(dx, p: p), p: p)
            let rx  = modSub(modSub(modMul(lam, lam, p: p), x.value, p: p), other.x.value, p: p)
            let ry  = modSub(modMul(lam, modSub(x.value, rx, p: p), p: p), y.value, p: p)
            return Point(x: FieldElement(rx), y: FieldElement(ry))
        }

        func double() throws -> Point {
            if isInfinity { return self }
            let p = AppleCryptoBackend.p.value
            let x2 = modMul(x.value, x.value, p: p)
            let lam = modMul(modAdd(modAdd(x2, x2, p: p), x2, p: p), modInv(modAdd(y.value, y.value, p: p), p: p), p: p)
            let rx  = modSub(modSub(modMul(lam, lam, p: p), x.value, p: p), x.value, p: p)
            let ry  = modSub(modMul(lam, modSub(x.value, rx, p: p), p: p), y.value, p: p)
            return Point(x: FieldElement(rx), y: FieldElement(ry))
        }

        func multiply(_ scalar: BigUInt) throws -> Point {
            var result = Point.infinity
            var addend = self
            var k = scalar
            while !k.isZero {
                if k[0] & 1 == 1 {
                    result = try result.add(addend)
                }
                addend = try addend.double()
                k = bigUIntShiftRight1(k)
            }
            return result
        }
    }

    // MARK: - Parsing / serialisation helpers

    private func parseCompressed(_ data: Data) throws -> Point {
        guard data.count == 33 else { throw SilentPaymentError.invalidPublicKey }
        let prefix = data[0]
        guard prefix == 0x02 || prefix == 0x03 else { throw SilentPaymentError.invalidPublicKey }
        let xBytes = data.dropFirst()
        let xVal = BigUInt(xBytes.map { $0 })
        let p = Self.p.value
        // y² = x³ + 7 (mod p)
        let x3 = Self.modMul(Self.modMul(xVal, xVal, p: p), xVal, p: p)
        let y2 = Self.modAdd(x3, [7], p: p)
        var y  = Self.modPow(y2, Self.modAdd(Self.modAdd(p, [1], p: []), [0], p: []).shifting(right: 2), p: p)
        // Choose correct parity
        let isOdd = (y.last ?? 0) % 2 == 1
        if (prefix == 0x02 && isOdd) || (prefix == 0x03 && !isOdd) {
            y = Self.modSub([0], y, p: p)
        }
        return Point(x: FieldElement(xVal), y: FieldElement(y))
    }

    private func scalarFromData(_ data: Data) throws -> BigUInt {
        guard data.count == 32 else { throw SilentPaymentError.invalidPrivateKey }
        let v = BigUInt(data.map { $0 })
        guard !v.isZero, v < Self.n.value else { throw SilentPaymentError.invalidPrivateKey }
        return v
    }

    private func padTo32(_ v: BigUInt) -> Data {
        Data(bigUIntToBytes(v, length: 32))
    }
}

// MARK: - Minimal BigUInt arithmetic (256-bit, [UInt64] little-endian limbs)
// These are free functions operating on arrays of UInt64.

private typealias BigUInt = [UInt64]

private extension Array where Element == UInt64 {
    var isZero: Bool { allSatisfy { $0 == 0 } || isEmpty }

    init(intValue: UInt64) {
        self = intValue == 0 ? [] : [intValue]
    }

    static func < (lhs: [UInt64], rhs: [UInt64]) -> Bool {
        let a = lhs.normalized, b = rhs.normalized
        if a.count != b.count { return a.count < b.count }
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            if a[i] != b[i] { return a[i] < b[i] }
        }
        return false
    }

    static func == (lhs: [UInt64], rhs: [UInt64]) -> Bool {
        let a = lhs.normalized, b = rhs.normalized
        guard a.count == b.count else { return false }
        return a.elementsEqual(b)
    }

    var normalized: [UInt64] {
        var r = self; while r.last == 0 && !r.isEmpty { r.removeLast() }; return r
    }

    func shifting(right bits: Int) -> [UInt64] { bigUIntShiftRight(self, bits: bits) }

    init(_ bytes: [UInt8]) {
        // Big-endian bytes → little-endian UInt64 limbs
        var limbs = [UInt64]()
        var i = bytes.count
        while i > 0 {
            let start = Swift.max(i - 8, 0)
            var limb: UInt64 = 0
            for j in start..<i { limb = (limb << 8) | UInt64(bytes[j]) }
            limbs.append(limb)
            i = start
        }
        while limbs.last == 0 && !limbs.isEmpty { limbs.removeLast() }
        self = limbs
    }

    init?(hexString: String) {
        var h = hexString
        if h.count % 2 != 0 { h = "0" + h }
        var bytes = [UInt8]()
        var i = h.startIndex
        while i < h.endIndex {
            let j = h.index(i, offsetBy: 2)
            guard let b = UInt8(h[i..<j], radix: 16) else { return nil }
            bytes.append(b)
            i = j
        }
        self.init(bytes)
    }
}

private func bigUIntToBytes(_ v: BigUInt, length: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: length)
    for (i, limb) in v.enumerated() {
        let base = (i * 8)
        for j in 0..<8 {
            let byteIndex = length - 1 - base - j
            if byteIndex >= 0 { bytes[byteIndex] = UInt8((limb >> (j * 8)) & 0xFF) }
        }
    }
    return bytes
}

private func bigUIntShiftRight1(_ v: BigUInt) -> BigUInt {
    var r = v
    var carry: UInt64 = 0
    for i in stride(from: r.count - 1, through: 0, by: -1) {
        let newCarry = r[i] & 1
        r[i] = (r[i] >> 1) | (carry << 63)
        carry = newCarry
    }
    return r.normalized
}

private func bigUIntShiftRight(_ v: BigUInt, bits: Int) -> BigUInt {
    var r = v
    for _ in 0..<bits { r = bigUIntShiftRight1(r) }
    return r
}

// MARK: - BigUInt operators (previously provided by secp256k1 package)

private func >= (lhs: BigUInt, rhs: BigUInt) -> Bool { !(lhs < rhs) }
private func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt { bigUIntAdd(lhs, rhs) }
private func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt { bigUIntSub(lhs, rhs) }
private func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
    // Schoolbook multiply (no modular reduction)
    var result = BigUInt(repeating: 0, count: lhs.count + rhs.count + 1)
    for (i, ai) in lhs.enumerated() {
        var carry: UInt64 = 0
        for (j, bj) in rhs.enumerated() {
            let (hi, lo) = ai.multipliedFullWidth(by: bj)
            let (s1, o1) = result[i+j].addingReportingOverflow(lo)
            let (s2, o2) = s1.addingReportingOverflow(carry)
            result[i+j] = s2
            carry = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
        }
        result[i + rhs.count] = carry
    }
    return result.normalized
}
private func % (lhs: BigUInt, rhs: BigUInt) -> BigUInt { bigUIntMod(lhs, rhs) }
private func != (lhs: BigUInt, rhs: Int) -> Bool { !(rhs == 0 && lhs.isZero) && !(rhs != 0 && !lhs.isZero && lhs == [UInt64(rhs)]) }
private func % (lhs: BigUInt, rhs: Int) -> UInt64 { lhs.isEmpty ? 0 : lhs[0] % UInt64(rhs) }

// Modular arithmetic (schoolbook — not constant time, only for non-production/test use)
private func modAdd(_ a: BigUInt, _ b: BigUInt, p: BigUInt) -> BigUInt {
    var r = bigUIntAdd(a, b)
    if r >= p { r = bigUIntSub(r, p) }
    return r.normalized
}

private func modSub(_ a: BigUInt, _ b: BigUInt, p: BigUInt) -> BigUInt {
    if a >= b { return bigUIntSub(a, b).normalized }
    return bigUIntSub(bigUIntAdd(a, p), b).normalized
}

private func modMul(_ a: BigUInt, _ b: BigUInt, p: BigUInt) -> BigUInt {
    // Schoolbook O(n²) — fine for 4-limb (256-bit) numbers in non-production paths
    var result = BigUInt(repeating: 0, count: a.count + b.count + 1)
    for (i, ai) in a.enumerated() {
        var carry: UInt64 = 0
        for (j, bj) in b.enumerated() {
            let (hi, lo) = ai.multipliedFullWidth(by: bj)
            let (s1, o1) = result[i+j].addingReportingOverflow(lo)
            let (s2, o2) = s1.addingReportingOverflow(carry)
            result[i+j] = s2
            carry = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
        }
        result[i + b.count] = carry
    }
    return bigUIntMod(result.normalized, p)
}

private func modPow(_ base: BigUInt, _ exp: BigUInt, p: BigUInt) -> BigUInt {
    var result = BigUInt([1])
    var b = bigUIntMod(base, p)
    var e = exp
    while !e.isZero {
        if (e[0] & 1) == 1 { result = modMul(result, b, p: p) }
        b = modMul(b, b, p: p)
        e = bigUIntShiftRight1(e)
    }
    return result
}

private func modInv(_ a: BigUInt, p: BigUInt) -> BigUInt {
    // Fermat's little theorem: a^(p-2) mod p
    let exp = bigUIntSub(p, [2])
    return modPow(a, exp, p: p)
}

private func bigUIntAdd(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
    let len = max(a.count, b.count) + 1
    var r = BigUInt(repeating: 0, count: len)
    var carry: UInt64 = 0
    for i in 0..<len {
        let ai = i < a.count ? a[i] : 0
        let bi = i < b.count ? b[i] : 0
        let (s1, o1) = ai.addingReportingOverflow(bi)
        let (s2, o2) = s1.addingReportingOverflow(carry)
        r[i] = s2
        carry = (o1 || o2) ? 1 : 0
    }
    return r.normalized
}

private func bigUIntSub(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
    var r = BigUInt(repeating: 0, count: a.count)
    var borrow: UInt64 = 0
    for i in 0..<a.count {
        let bi = i < b.count ? b[i] : 0
        let (s1, o1) = a[i].subtractingReportingOverflow(bi)
        let (s2, o2) = s1.subtractingReportingOverflow(borrow)
        r[i] = s2
        borrow = (o1 || o2) ? 1 : 0
    }
    return r.normalized
}

private func bigUIntMod(_ a: BigUInt, _ p: BigUInt) -> BigUInt {
    // Simple repeated subtraction — only for small remainders after multiplication
    var r = a
    while r >= p { r = bigUIntSub(r, p) }
    return r
}

private extension AppleCryptoBackend {
    static func modAdd(_ a: BigUInt, _ b: BigUInt, p: BigUInt) -> BigUInt {
        SilentPaymentsKit.modAdd(a, b, p: p)
    }
    static func modSub(_ a: BigUInt, _ b: BigUInt, p: BigUInt) -> BigUInt {
        SilentPaymentsKit.modSub(a, b, p: p)
    }
    static func modMul(_ a: BigUInt, _ b: BigUInt, p: BigUInt) -> BigUInt {
        SilentPaymentsKit.modMul(a, b, p: p)
    }
    static func modInv(_ a: BigUInt, p: BigUInt) -> BigUInt {
        SilentPaymentsKit.modInv(a, p: p)
    }
    static func modPow(_ base: BigUInt, _ exp: BigUInt, p: BigUInt) -> BigUInt {
        SilentPaymentsKit.modPow(base, exp, p: p)
    }
}
