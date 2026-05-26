// Sources/SilentPaymentsKit/Core/SilentPaymentTypes.swift
//
// BIP-352 Silent Payments — Core Types
// Covers the full address format: sp1... bech32m(v0 || ScanPub || SpendPub)

import Foundation

// MARK: - Errors

public enum SilentPaymentError: Error, LocalizedError {
    case invalidPrivateKey
    case invalidPublicKey
    case invalidAddress(String)
    case ecdhFailed
    case hashingFailed
    case tweakFailed
    case noEligibleInputs
    case invalidOutpoint
    case bech32EncodingFailed
    case bech32DecodingFailed
    case nostrKeyDerivationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidPrivateKey:       return "Invalid private key bytes"
        case .invalidPublicKey:        return "Invalid public key bytes"
        case .invalidAddress(let s):   return "Invalid silent payment address: \(s)"
        case .ecdhFailed:              return "ECDH shared-secret computation failed"
        case .hashingFailed:           return "Tagged hash computation failed"
        case .tweakFailed:             return "EC key tweak failed"
        case .noEligibleInputs:        return "Transaction has no BIP-352 eligible inputs"
        case .invalidOutpoint:         return "Could not parse outpoint"
        case .bech32EncodingFailed:    return "Bech32m encoding failed"
        case .bech32DecodingFailed:    return "Bech32m decoding failed"
        case .nostrKeyDerivationFailed: return "NSW key derivation from npub failed"
        }
    }
}

// MARK: - Silent Payment Address

/// A decoded BIP-352 silent payment address (sp1...).
/// Encodes a scan public key and a spend public key.
public struct SilentPaymentAddress: Equatable, Hashable, CustomStringConvertible {
    /// 33-byte compressed scan public key (Bscan)
    public let scanPublicKey: Data
    /// 33-byte compressed spend public key (Bspend or labeled variant)
    public let spendPublicKey: Data
    /// The human-readable `sp1...` bech32m string
    public let address: String

    public var description: String { address }
}

// MARK: - Key Pairs

/// A full BIP-352 receiver key pair (scan + spend, both private and public).
public struct SilentPaymentKeyPair {
    public let scanPrivateKey: Data    // bscan  (32 bytes)
    public let scanPublicKey: Data     // Bscan  (33 bytes compressed)
    public let spendPrivateKey: Data   // bspend (32 bytes)
    public let spendPublicKey: Data    // Bspend (33 bytes compressed)
    public let address: SilentPaymentAddress

    public init(
        scanPrivateKey: Data,
        scanPublicKey: Data,
        spendPrivateKey: Data,
        spendPublicKey: Data,
        address: SilentPaymentAddress
    ) {
        self.scanPrivateKey = scanPrivateKey
        self.scanPublicKey = scanPublicKey
        self.spendPrivateKey = spendPrivateKey
        self.spendPublicKey = spendPublicKey
        self.address = address
    }
}

// MARK: - Transaction Input (for sender-side tweak)

/// Represents a BIP-352-eligible transaction input.
/// Only inputs with public keys (P2TR, P2WPKH, P2PKH, P2SH-P2WPKH) are eligible.
public struct SilentPaymentInput {
    /// The outpoint (txid LE 32 bytes + vout LE 4 bytes = 36 bytes)
    public let outpoint: Data
    /// The 32-byte private key scalar controlling this UTXO
    public let privateKey: Data
    /// Input type — affects key negation rules per BIP-352 §Inputs
    public let inputType: InputType

    public enum InputType {
        case p2tr       // Taproot (key-path only; x-only; negate if has_odd_y)
        case p2wpkh     // Native SegWit v0
        case p2shP2wpkh // Wrapped SegWit
        case p2pkh      // Legacy
    }

    public init(outpoint: Data, privateKey: Data, inputType: InputType) {
        self.outpoint = outpoint
        self.privateKey = privateKey
        self.inputType = inputType
    }
}

// MARK: - UTXO found by receiver scanning

public struct SilentPaymentOutput {
    /// The 32-byte x-only Taproot public key (the on-chain P2TR output key)
    public let taprootXOnlyKey: Data
    /// The private key scalar that can spend this output:
    ///   spend_priv = (bspend + t) mod n
    public let spendPrivateKey: Data
    /// The output index k in the BIP-352 output derivation
    public let outputIndex: UInt32
    /// Optional label m, if this was a labeled output
    public let label: UInt32?

    public init(taprootXOnlyKey: Data, spendPrivateKey: Data, outputIndex: UInt32, label: UInt32? = nil) {
        self.taprootXOnlyKey = taprootXOnlyKey
        self.spendPrivateKey = spendPrivateKey
        self.outputIndex = outputIndex
        self.label = label
    }
}

// MARK: - Notification payload (Nostr / out-of-band)

/// BIP-352 / NIP-SP notification message sent by the sender to the receiver.
/// Schema from https://delvingbitcoin.org/t/silent-payments-notifications-via-nostr/2203
public struct SilentPaymentNotification: Codable {
    /// Transaction ID (hex)
    public let txid: String
    /// 33-byte compressed aggregate input tweak (hex)
    public let tweak: String
    /// Optional confirming block hash (hex)
    public let blockhash: String?

    public init(txid: String, tweak: String, blockhash: String? = nil) {
        self.txid = txid
        self.tweak = tweak
        self.blockhash = blockhash
    }
}
