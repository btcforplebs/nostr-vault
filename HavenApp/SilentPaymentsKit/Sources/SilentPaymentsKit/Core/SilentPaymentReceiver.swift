// Sources/SilentPaymentsKit/Core/SilentPaymentReceiver.swift
//
// BIP-352 Receiver / Scanner — routes entirely through Secp256k1.backend,
// no direct dependency on any secp256k1 Swift package.

import Foundation
import CryptoKit

public struct SilentPaymentReceiver {

    // MARK: - Fast path: scan with pre-computed tweak (from Nostr notification)
    //
    // Sender provides:  tweak = input_hash · (sum of input public keys), 33-byte compressed point
    // Receiver computes: shared_secret = bscan · tweak

    public static func scanWithTweak(
        keyPair: SilentPaymentKeyPair,
        tweak: Data,                    // 33-byte compressed public key
        taprootOutputs: [Data],         // 32-byte x-only keys from the transaction
        labels: [UInt32] = []
    ) throws -> [SilentPaymentOutput] {
        let sharedPoint = try Secp256k1.multiplyPubKey(tweak, scalar: keyPair.scanPrivateKey)
        return try findOutputs(keyPair: keyPair, sharedPoint: sharedPoint,
                               taprootOutputs: taprootOutputs, labels: labels)
    }

    // MARK: - Full scan from raw transaction inputs (no notification)
    //
    // Receiver side only has public keys — uses public-key scalar multiplication
    // to reproduce the tweak point without needing the input private keys.

    public static func scanWithInputs(
        keyPair: SilentPaymentKeyPair,
        inputs: [(outpoint: Data, publicKey: Data)],   // (36-byte outpoint, 33-byte compressed pubkey)
        taprootOutputs: [Data],
        labels: [UInt32] = []
    ) throws -> [SilentPaymentOutput] {
        guard !inputs.isEmpty else { return [] }

        // A = A1 + A2 + ... + An
        let A = try Secp256k1.sumPublicKeys(inputs.map(\.publicKey))

        // Lexicographically smallest outpoint (BIP-352 requirement)
        let smallestOutpoint = inputs.map(\.outpoint)
            .sorted { $0.lexicographicallyPrecedes($1) }
            .first!

        // input_hash = H_BIP0352/Inputs(outpointL || A)
        let inputHash = TaggedHash.inputsHash(smallestOutpoint + A)

        // tweakPoint = input_hash · A   (scalar × public key)
        let tweakPoint = try Secp256k1.multiplyPubKey(A, scalar: inputHash)

        // shared_secret = bscan · tweakPoint
        let sharedPoint = try Secp256k1.multiplyPubKey(tweakPoint, scalar: keyPair.scanPrivateKey)

        return try findOutputs(keyPair: keyPair, sharedPoint: sharedPoint,
                               taprootOutputs: taprootOutputs, labels: labels)
    }

    // MARK: - Output matching loop (BIP-352 §Scanning)

    private static func findOutputs(
        keyPair: SilentPaymentKeyPair,
        sharedPoint: Data,
        taprootOutputs: [Data],   // 32-byte x-only keys
        labels: [UInt32]
    ) throws -> [SilentPaymentOutput] {

        // Pre-compute label lookup: xOnly(label_point) → m
        // label_point = hash(bscan || m) · G
        var labelLookup = [Data: UInt32]()
        for m in labels {
            let preimage   = keyPair.scanPrivateKey + ser32(m)
            let labelScalar = TaggedHash.labelHash(preimage)
            // Generate label_point = labelScalar · G  (G = pubkey of privkey 1)
            let G           = try Secp256k1.publicKey(from: generatorScalar)
            let labelPoint  = try Secp256k1.addTweakToPubKey(G, tweak: labelScalar)
            // Actually: labelScalar·G directly = pubkey of labelScalar
            let labelPointDirect = try Secp256k1.publicKey(from: labelScalar)
            labelLookup[Secp256k1.xOnlyKey(labelPointDirect)] = m
        }

        let outputSet = Set(taprootOutputs.map { $0.hexString })
        var results   = [SilentPaymentOutput]()
        var k: UInt32 = 0

        while true {
            // t_k = H_BIP0352/SharedSecret(sharedPoint || ser32(k))
            let tk     = TaggedHash.sharedSecret(sharedPoint + ser32(k))
            // P_k = Bspend + t_k·G
            let Pk     = try Secp256k1.addTweakToPubKey(keyPair.spendPublicKey, tweak: tk)
            let xOnlyPk = Secp256k1.xOnlyKey(Pk)

            if outputSet.contains(xOnlyPk.hexString) {
                // Direct (unlabeled) match
                let spendPriv = try Secp256k1.addTweakToPrivKey(keyPair.spendPrivateKey, tweak: tk)
                results.append(SilentPaymentOutput(
                    taprootXOnlyKey: xOnlyPk,
                    spendPrivateKey: spendPriv,
                    outputIndex: k,
                    label: nil
                ))
                k += 1
                continue
            }

            // Check for labeled outputs: output_key - P_k should equal a known label point
            var foundLabel = false
            for xOnlyOutput in taprootOutputs {
                guard xOnlyOutput != xOnlyPk else { continue }
                // Reconstruct full compressed keys (try even Y first; odd Y handled below)
                let outFull = Data([0x02]) + xOnlyOutput
                let PkFull  = Data([0x02]) + xOnlyPk
                // diff = outFull - PkFull
                if let diff = try? Secp256k1.subtractPubKeys(outFull, PkFull) {
                    let diffXOnly = Secp256k1.xOnlyKey(diff)
                    if let m = labelLookup[diffXOnly] {
                        let spendPriv = try labeledSpendKey(keyPair: keyPair, tk: tk, m: m)
                        results.append(SilentPaymentOutput(
                            taprootXOnlyKey: xOnlyOutput,
                            spendPrivateKey: spendPriv,
                            outputIndex: k,
                            label: m
                        ))
                        foundLabel = true
                        k += 1
                        break
                    }
                }
            }

            if !foundLabel { break }
        }

        return results
    }

    // MARK: - Labeled spend key
    // spend_key = bspend + tk + hash(bscan || m)  mod n
    private static func labeledSpendKey(
        keyPair: SilentPaymentKeyPair,
        tk: Data,
        m: UInt32
    ) throws -> Data {
        let labelScalar = TaggedHash.labelHash(keyPair.scanPrivateKey + ser32(m))
        let step1 = try Secp256k1.addTweakToPrivKey(keyPair.spendPrivateKey, tweak: tk)
        return try Secp256k1.addTweakToPrivKey(step1, tweak: labelScalar)
    }

    // MARK: - Helpers

    /// Generator scalar: private key = 1 → public key = G
    private static let generatorScalar = Data([
        0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
        0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,1
    ])

    static func ser32(_ k: UInt32) -> Data {
        Data([UInt8((k>>24)&0xFF), UInt8((k>>16)&0xFF), UInt8((k>>8)&0xFF), UInt8(k&0xFF)])
    }
}


