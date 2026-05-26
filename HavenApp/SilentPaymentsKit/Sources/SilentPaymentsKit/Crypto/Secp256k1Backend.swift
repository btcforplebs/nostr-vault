// Sources/SilentPaymentsKit/Crypto/Secp256k1Backend.swift
//
// The single protocol every layer of SilentPaymentsKit talks to.
// Swap the active backend at compile time (or runtime) without touching
// Sender, Receiver, Adapters, or Wallet code.
//
// Required operations for BIP-352:
//   • privKey → pubKey
//   • scalar × point  (ECDH raw point, not hashed)
//   • point + scalar·G  (key tweak)
//   • privKey + scalar  (mod n)
//   • privKey × scalar  (mod n)   ← needed for input_hash·a
//   • point + point     (key combine)
//   • negate privKey
//   • hasOddY

import Foundation

// MARK: - Protocol

public protocol Secp256k1Backend: Sendable {

    // MARK: Keys

    /// Derive the 33-byte compressed public key from a 32-byte private key.
    func privateKeyToPublicKey(_ privateKey: Data) throws -> Data

    /// Negate a private key: (-k) mod n  (32 bytes → 32 bytes)
    func negatePrivateKey(_ privateKey: Data) throws -> Data

    // MARK: Scalar operations on private keys

    /// (a + tweak) mod n  — add a 32-byte scalar to a private key
    func addTweakToPrivateKey(_ privateKey: Data, tweak: Data) throws -> Data

    /// (a × scalar) mod n  — multiply a private key by a 32-byte scalar
    func multiplyPrivateKey(_ privateKey: Data, scalar: Data) throws -> Data

    /// (a1 + a2 + … + an) mod n
    func sumPrivateKeys(_ privateKeys: [Data]) throws -> Data

    // MARK: Scalar operations on public keys

    /// P + tweak·G  — add scalar tweak to a compressed public key (33 bytes)
    func addTweakToPublicKey(_ publicKey: Data, tweak: Data) throws -> Data

    /// scalar × P  — multiply a compressed public key by a scalar (33 bytes)
    func multiplyPublicKey(_ publicKey: Data, scalar: Data) throws -> Data

    /// P1 + P2  — add two compressed public keys (point addition)
    func combinePublicKeys(_ keys: [Data]) throws -> Data

    /// P1 - P2  — subtract two compressed public keys (P1 + (-P2))
    func subtractPublicKeys(_ a: Data, _ b: Data) throws -> Data

    // MARK: Predicates

    /// Returns true if the compressed public key's Y coordinate is odd (prefix 0x03).
    func hasOddY(_ publicKey: Data) -> Bool

    // MARK: Signing (needed by Nostr event signing)

    /// Schnorr sign `message` (32-byte hash) with `privateKey`. Returns 64-byte signature.
    func schnorrSign(message: Data, privateKey: Data) throws -> Data
}

// MARK: - Convenience shim so call-sites stay identical to the old enum

/// The active backend. Set once at startup (or override in tests).
/// Defaults to LibsecrBackend (raw C libsecp256k1 via 21-DOT-DEV/swift-secp256k1).
public final class Secp256k1 {
    public static var backend: any Secp256k1Backend = LibsecrBackend()

    // Forward all call-sites that used the old `Secp256k1Helper` enum:

    static func publicKey(from priv: Data) throws -> Data {
        try backend.privateKeyToPublicKey(priv)
    }
    static func negatePrivKey(_ priv: Data) throws -> Data {
        try backend.negatePrivateKey(priv)
    }
    static func addTweakToPrivKey(_ priv: Data, tweak: Data) throws -> Data {
        try backend.addTweakToPrivateKey(priv, tweak: tweak)
    }
    static func multiplyPrivKey(_ priv: Data, scalar: Data) throws -> Data {
        try backend.multiplyPrivateKey(priv, scalar: scalar)
    }
    static func sumPrivateKeys(_ keys: [Data]) throws -> Data {
        try backend.sumPrivateKeys(keys)
    }
    static func addTweakToPubKey(_ pub: Data, tweak: Data) throws -> Data {
        try backend.addTweakToPublicKey(pub, tweak: tweak)
    }
    static func multiplyPubKey(_ pub: Data, scalar: Data) throws -> Data {
        try backend.multiplyPublicKey(pub, scalar: scalar)
    }
    static func sumPublicKeys(_ keys: [Data]) throws -> Data {
        try backend.combinePublicKeys(keys)
    }
    static func subtractPubKeys(_ a: Data, _ b: Data) throws -> Data {
        try backend.subtractPublicKeys(a, b)
    }
    static func hasOddY(_ pub: Data) -> Bool {
        backend.hasOddY(pub)
    }
    static func schnorrSign(message: Data, privateKey: Data) throws -> Data {
        try backend.schnorrSign(message: message, privateKey: privateKey)
    }
    /// ECDH: multiply public key by private key scalar to get shared point.
    static func ecdhPoint(privateKey: Data, publicKey: Data) throws -> Data {
        try backend.multiplyPublicKey(publicKey, scalar: privateKey)
    }
    // Pure-Swift helpers that don't need a backend:
    static func xOnlyKey(_ compressed: Data) -> Data {
        compressed.count == 33 ? compressed.dropFirst() : compressed
    }
    static func p2trScriptPubKey(xOnlyKey: Data) -> Data {
        Data([0x51, 0x20]) + xOnlyKey
    }
}
