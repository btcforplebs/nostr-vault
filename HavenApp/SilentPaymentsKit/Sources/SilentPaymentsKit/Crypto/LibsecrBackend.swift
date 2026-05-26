// Sources/SilentPaymentsKit/Crypto/LibsecrBackend.swift
//
// Backend that calls libsecp256k1 directly via the system C library
// (bundled in Bitcoin Core, available as a Swift Package via 21-DOT-DEV/swift-secp256k1).
//
// To use:
//   1. Add to Package.swift dependencies:
//      .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1.git", from: "0.1.0")
//   2. Add product "LibSecp256k1" to your target.
//   3. Set Secp256k1.backend = LibsecrBackend() at app startup.
//
// This backend uses the raw C API, making it immune to Swift wrapper API changes.
// The C API (secp256k1.h) has been stable since 2014 and is consensus-critical.

import Foundation

// Conditional compilation: only compiled if libsecp256k1 is available
#if canImport(libsecp256k1)
import libsecp256k1

public struct LibsecrBackend: Secp256k1Backend {

    private let ctx: OpaquePointer

    public init() {
        // SECP256K1_CONTEXT_SIGN | SECP256K1_CONTEXT_VERIFY
        ctx = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_SIGN | SECP256K1_CONTEXT_VERIFY))!
        // Randomise context to protect against side-channel attacks
        var seed = Data.randomBytes(count: 32)
        seed.withUnsafeBytes { _ = secp256k1_context_randomize(ctx, $0.bindMemory(to: UInt8.self).baseAddress!) }
    }

    // MARK: - Keys

    public func privateKeyToPublicKey(_ privateKey: Data) throws -> Data {
        var pubkey = secp256k1_pubkey()
        let result = privateKey.withUnsafeBytes { privBytes -> Int32 in
            secp256k1_ec_pubkey_create(ctx, &pubkey, privBytes.bindMemory(to: UInt8.self).baseAddress!)
        }
        guard result == 1 else { throw SilentPaymentError.invalidPrivateKey }
        return try serializeCompressed(pubkey)
    }

    public func negatePrivateKey(_ privateKey: Data) throws -> Data {
        var key = [UInt8](privateKey)
        let result = secp256k1_ec_seckey_negate(ctx, &key)
        guard result == 1 else { throw SilentPaymentError.invalidPrivateKey }
        return Data(key)
    }

    // MARK: - Scalar ops on private keys

    public func addTweakToPrivateKey(_ privateKey: Data, tweak: Data) throws -> Data {
        var key = [UInt8](privateKey)
        let result = tweak.withUnsafeBytes { tweakBytes -> Int32 in
            secp256k1_ec_seckey_tweak_add(ctx, &key, tweakBytes.bindMemory(to: UInt8.self).baseAddress!)
        }
        guard result == 1 else { throw SilentPaymentError.tweakFailed }
        return Data(key)
    }

    public func multiplyPrivateKey(_ privateKey: Data, scalar: Data) throws -> Data {
        var key = [UInt8](privateKey)
        let result = scalar.withUnsafeBytes { scalarBytes -> Int32 in
            secp256k1_ec_seckey_tweak_mul(ctx, &key, scalarBytes.bindMemory(to: UInt8.self).baseAddress!)
        }
        guard result == 1 else { throw SilentPaymentError.tweakFailed }
        return Data(key)
    }

    public func sumPrivateKeys(_ privateKeys: [Data]) throws -> Data {
        guard !privateKeys.isEmpty else { throw SilentPaymentError.invalidPrivateKey }
        var acc = [UInt8](privateKeys[0])
        for key in privateKeys.dropFirst() {
            let result = key.withUnsafeBytes { kb -> Int32 in
                secp256k1_ec_seckey_tweak_add(ctx, &acc, kb.bindMemory(to: UInt8.self).baseAddress!)
            }
            guard result == 1 else { throw SilentPaymentError.invalidPrivateKey }
        }
        return Data(acc)
    }

    // MARK: - Scalar ops on public keys

    public func addTweakToPublicKey(_ publicKey: Data, tweak: Data) throws -> Data {
        var pub = try parseCompressed(publicKey)
        let result = tweak.withUnsafeBytes { tweakBytes -> Int32 in
            secp256k1_ec_pubkey_tweak_add(ctx, &pub, tweakBytes.bindMemory(to: UInt8.self).baseAddress!)
        }
        guard result == 1 else { throw SilentPaymentError.tweakFailed }
        return try serializeCompressed(pub)
    }

    public func multiplyPublicKey(_ publicKey: Data, scalar: Data) throws -> Data {
        var pub = try parseCompressed(publicKey)
        let result = scalar.withUnsafeBytes { sb -> Int32 in
            secp256k1_ec_pubkey_tweak_mul(ctx, &pub, sb.bindMemory(to: UInt8.self).baseAddress!)
        }
        guard result == 1 else { throw SilentPaymentError.tweakFailed }
        return try serializeCompressed(pub)
    }

    public func combinePublicKeys(_ keys: [Data]) throws -> Data {
        guard !keys.isEmpty else { throw SilentPaymentError.invalidPublicKey }
        var pubkeys = try keys.map { try parseCompressed($0) }
        var combined = secp256k1_pubkey()
        let result = pubkeys.withUnsafeMutableBufferPointer { buf -> Int32 in
            var ptrs = (0..<buf.count).map { i -> UnsafePointer<secp256k1_pubkey>? in
                UnsafePointer(buf.baseAddress! + i)
            }
            return secp256k1_ec_pubkey_combine(ctx, &combined, &ptrs, buf.count)
        }
        guard result == 1 else { throw SilentPaymentError.invalidPublicKey }
        return try serializeCompressed(combined)
    }

    public func subtractPublicKeys(_ a: Data, _ b: Data) throws -> Data {
        var bPub = try parseCompressed(b)
        let negResult = secp256k1_ec_pubkey_negate(ctx, &bPub)
        guard negResult == 1 else { throw SilentPaymentError.tweakFailed }
        let negBData = try serializeCompressed(bPub)
        return try combinePublicKeys([a, negBData])
    }

    // MARK: - Predicates

    public func hasOddY(_ publicKey: Data) -> Bool {
        publicKey.count == 33 && publicKey[0] == 0x03
    }

    // MARK: - Signing (Schnorr / BIP-340)

    public func schnorrSign(message: Data, privateKey: Data) throws -> Data {
        var keypair = secp256k1_keypair()
        let kpResult = privateKey.withUnsafeBytes { kb -> Int32 in
            secp256k1_keypair_create(ctx, &keypair, kb.bindMemory(to: UInt8.self).baseAddress!)
        }
        guard kpResult == 1 else { throw SilentPaymentError.invalidPrivateKey }

        var sig = [UInt8](repeating: 0, count: 64)
        let aux = Data.randomBytes(count: 32)
        let sigResult = message.withUnsafeBytes { msgBytes -> Int32 in
            aux.withUnsafeBytes { auxBytes -> Int32 in
                secp256k1_schnorrsig_sign32(
                    ctx, &sig,
                    msgBytes.bindMemory(to: UInt8.self).baseAddress!,
                    &keypair,
                    auxBytes.bindMemory(to: UInt8.self).baseAddress!
                )
            }
        }
        guard sigResult == 1 else { throw SilentPaymentError.tweakFailed }
        return Data(sig)
    }

    // MARK: - Helpers

    private func parseCompressed(_ data: Data) throws -> secp256k1_pubkey {
        var pub = secp256k1_pubkey()
        let result = data.withUnsafeBytes { bytes -> Int32 in
            secp256k1_ec_pubkey_parse(
                ctx, &pub,
                bytes.bindMemory(to: UInt8.self).baseAddress!,
                data.count
            )
        }
        guard result == 1 else { throw SilentPaymentError.invalidPublicKey }
        return pub
    }

    private func serializeCompressed(_ pub: secp256k1_pubkey) throws -> Data {
        var pub = pub
        var output = [UInt8](repeating: 0, count: 33)
        var outputLen = 33
        secp256k1_ec_pubkey_serialize(ctx, &output, &outputLen, &pub, UInt32(SECP256K1_EC_COMPRESSED))
        return Data(output)
    }

    // Note: ctx is never destroyed — the backend is a long-lived singleton.
}
#else
// Stub so the file compiles even without libsecp256k1 — the backend just isn't available.
public struct LibsecrBackend: Secp256k1Backend {
    public init() {}
    public func privateKeyToPublicKey(_ p: Data) throws -> Data { throw SilentPaymentError.invalidPrivateKey }
    public func negatePrivateKey(_ p: Data) throws -> Data { throw SilentPaymentError.invalidPrivateKey }
    public func addTweakToPrivateKey(_ p: Data, tweak: Data) throws -> Data { throw SilentPaymentError.tweakFailed }
    public func multiplyPrivateKey(_ p: Data, scalar: Data) throws -> Data { throw SilentPaymentError.tweakFailed }
    public func sumPrivateKeys(_ keys: [Data]) throws -> Data { throw SilentPaymentError.invalidPrivateKey }
    public func addTweakToPublicKey(_ p: Data, tweak: Data) throws -> Data { throw SilentPaymentError.tweakFailed }
    public func multiplyPublicKey(_ p: Data, scalar: Data) throws -> Data { throw SilentPaymentError.tweakFailed }
    public func combinePublicKeys(_ keys: [Data]) throws -> Data { throw SilentPaymentError.invalidPublicKey }
    public func subtractPublicKeys(_ a: Data, _ b: Data) throws -> Data { throw SilentPaymentError.tweakFailed }
    public func hasOddY(_ p: Data) -> Bool { false }
    public func schnorrSign(message: Data, privateKey: Data) throws -> Data { throw SilentPaymentError.invalidPrivateKey }
}
#endif
