// Sources/SilentPaymentsKit/Core/CryptoHelpers.swift
//
// Tagged hashes (pure CryptoKit, no external dependency) +
// a thin alias so existing call-sites compile unchanged.
// All secp256k1 operations now route through Secp256k1.backend (see Crypto/).

import Foundation
import CryptoKit

// MARK: - Tagged SHA-256 (BIP-340 style)
// Pure CryptoKit — no external dependency, never needs swapping.

enum TaggedHash {
    /// BIP-340 tagged hash: SHA256(SHA256(tag) || SHA256(tag) || data)
    static func hash(tag: String, data: Data) -> Data {
        let tagBytes  = Data(tag.utf8)
        let tagHash   = Data(SHA256.hash(data: tagBytes))
        let preimage  = tagHash + tagHash + data
        return Data(SHA256.hash(data: preimage))
    }

    static func inputsHash(_ data: Data)  -> Data { hash(tag: "BIP0352/Inputs",       data: data) }
    static func sharedSecret(_ data: Data) -> Data { hash(tag: "BIP0352/SharedSecret", data: data) }
    static func labelHash(_ data: Data)   -> Data { hash(tag: "BIP0352/Label",         data: data) }
    static func nostrSPScan(_ data: Data)  -> Data { hash(tag: "nostr-sp/scan",        data: data) }
    static func nostrSPSpend(_ data: Data) -> Data { hash(tag: "nostr-sp/spend",       data: data) }
}

// MARK: - Secp256k1Helper
// Backward-compat alias so Sender/Receiver/Adapters need no changes.
// All calls delegate to the active Secp256k1.backend.

typealias Secp256k1Helper = Secp256k1

// MARK: - Outpoint helpers (BIP-352 uses LE serialisation)

extension Data {
    static func leUInt32(_ value: UInt32) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: 4)
    }

    func lexicographicallyPrecedes(_ other: Data) -> Bool {
        for (a, b) in zip(self, other) {
            if a != b { return a < b }
        }
        return self.count < other.count
    }
}
