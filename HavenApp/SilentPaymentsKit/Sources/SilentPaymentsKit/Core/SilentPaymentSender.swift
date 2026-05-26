// Sources/SilentPaymentsKit/Core/SilentPaymentSender.swift
//
// BIP-352 Sender Logic
// Given a set of inputs (private keys + outpoints) and a recipient's
// silent payment address, derives the unique one-time Taproot output key(s).

import Foundation
import CryptoKit

public struct SilentPaymentSender {

    // MARK: - Primary API

    /// Derive one or more P2TR output public keys for a silent payment.
    ///
    /// - Parameters:
    ///   - inputs:    All BIP-352-eligible inputs of the transaction being built.
    ///                (P2TR keys must already be negated if odd-Y — see BIP-352 §Inputs)
    ///   - recipient: The recipient's decoded silent payment address.
    ///   - count:     How many outputs to create for this recipient (usually 1).
    /// - Returns:     `count` 33-byte compressed public keys. Encode each as P2TR
    ///                (x-only, i.e. drop first byte, wrap in OP_1 PUSH32 script).
    ///
    /// - Note: If you have multiple recipients in the same tx, call this once per
    ///         recipient but **reuse the same `inputs` array** so the input_hash and
    ///         aggregate key are computed identically.
    public static func deriveOutputKeys(
        inputs: [SilentPaymentInput],
        recipient: SilentPaymentAddress,
        count: UInt32 = 1
    ) throws -> [Data] {

        // ── Step 1: Prepare private keys (negate P2TR odd-Y keys per BIP-352) ──
        let adjustedPrivKeys = try inputs.map { input -> Data in
            var priv = input.privateKey
            if input.inputType == .p2tr {
                let pub = try Secp256k1Helper.publicKey(from: priv)
                if Secp256k1Helper.hasOddY(pub) {
                    priv = try Secp256k1Helper.negatePrivKey(priv)
                }
            }
            return priv
        }

        // ── Step 2: a = sum of all eligible input private keys ──
        let a = try Secp256k1Helper.sumPrivateKeys(adjustedPrivKeys)
        let A = try Secp256k1Helper.publicKey(from: a)   // a·G

        // ── Step 3: input_hash = H_BIP352_Inputs(outpoint_L || A) ──
        //    outpoint_L = lexicographically smallest outpoint
        let sortedOutpoints = inputs.map(\.outpoint).sorted { $0.lexicographicallyPrecedes($1) }
        guard let smallestOutpoint = sortedOutpoints.first else {
            throw SilentPaymentError.noEligibleInputs
        }
        var inputHashPreimage = smallestOutpoint + A
        let inputHash = TaggedHash.inputsHash(inputHashPreimage)

        // ── Step 4: ECDH shared secret = input_hash · a · Bscan ──
        //    = (input_hash · a) · Bscan
        // Compute ecdh_input_key = input_hash * a (mod n)
        let ecdhInputKey = try multiplyScalar(scalar: inputHash, key: a)
        // Shared point = ecdhInputKey · Bscan (ECDH)
        let sharedPoint = try Secp256k1Helper.ecdhPoint(
            privateKey: ecdhInputKey,
            publicKey: recipient.scanPublicKey
        )

        // ── Step 5: For each output index k, derive Pk ──
        //    t_k = H_BIP352_SharedSecret(sharedPoint || ser_32(k))
        //    Pk = Bspend + t_k · G
        var results = [Data]()
        for k in 0..<count {
            var preimage = sharedPoint
            preimage.append(contentsOf: ser32(k))
            let tk = TaggedHash.sharedSecret(preimage)
            let outputPubKey = try Secp256k1Helper.addTweakToPubKey(
                recipient.spendPublicKey,
                tweak: tk
            )
            results.append(outputPubKey)
        }
        return results
    }

    // MARK: - Compute the "tweak" field for Nostr notification
    //
    // The tweak is the 33-byte compressed point: input_hash · a · G
    // (i.e. the aggregate input public key after input_hash scaling).
    // The receiver can use it to skip re-deriving from full tx inputs.
    public static func computeTweak(inputs: [SilentPaymentInput]) throws -> Data {
        let adjustedPrivKeys = try inputs.map { input -> Data in
            var priv = input.privateKey
            if input.inputType == .p2tr {
                let pub = try Secp256k1Helper.publicKey(from: priv)
                if Secp256k1Helper.hasOddY(pub) {
                    priv = try Secp256k1Helper.negatePrivKey(priv)
                }
            }
            return priv
        }
        let a = try Secp256k1Helper.sumPrivateKeys(adjustedPrivKeys)
        let A = try Secp256k1Helper.publicKey(from: a)

        let sortedOutpoints = inputs.map(\.outpoint).sorted { $0.lexicographicallyPrecedes($1) }
        guard let smallest = sortedOutpoints.first else { throw SilentPaymentError.noEligibleInputs }
        let inputHash = TaggedHash.inputsHash(smallest + A)
        let scaledPriv = try multiplyScalar(scalar: inputHash, key: a)
        // Return the public key of the scaled private key as the tweak
        return try Secp256k1Helper.publicKey(from: scaledPriv)
    }

    // MARK: - Internal: scalar × scalar mod n
    // We need (hash · privKey) mod n.
    private static func multiplyScalar(scalar: Data, key: Data) throws -> Data {
        try Secp256k1.multiplyPrivKey(key, scalar: scalar)
    }

    // MARK: - ser32(k): 4-byte big-endian integer serialisation
    private static func ser32(_ k: UInt32) -> [UInt8] {
        [
            UInt8((k >> 24) & 0xFF),
            UInt8((k >> 16) & 0xFF),
            UInt8((k >>  8) & 0xFF),
            UInt8( k        & 0xFF),
        ]
    }
}
