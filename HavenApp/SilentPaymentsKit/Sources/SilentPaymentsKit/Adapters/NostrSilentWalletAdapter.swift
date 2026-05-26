// Sources/SilentPaymentsKit/Adapters/NostrSilentWalletAdapter.swift
//
// Nostr Silent Wallet (NSW) — two core operations:
//
//   1. npub  → sp1... address  (anyone can call this, no private key needed)
//   2. nsec  → SilentPaymentKeyPair (for scanning and spending found outputs)
//
// Math (trbouma: https://gist.github.com/trbouma/77648ebe1005b181b67d1c4b42c7f31d):
//
//   P = d·G                        (Nostr pubkey, compressed 33 bytes)
//   t_scan  = H_tag("nostr-sp/scan",  P)
//   t_spend = H_tag("nostr-sp/spend", P)
//   ScanPub  = P + t_scan·G
//   SpendPub = P + t_spend·G
//   scan_priv  = (d + t_scan)  mod n
//   spend_priv = (d + t_spend) mod n
//   sp1... = bech32m(0x00 || ScanPub || SpendPub)

import Foundation
import CryptoKit

public struct NostrSilentWalletAdapter {

    // MARK: - npub → sp1 address
    //
    // The primary "puzzle piece": given any npub representation,
    // deterministically derive the corresponding Silent Payment address.
    // No private key is required — any sender can call this.

    /// Derive the `sp1...` Silent Payment address from any npub representation.
    ///
    /// Accepts:
    ///   - `npub1...`   bech32-encoded Nostr public key (most common)
    ///   - 64-char hex  x-only public key (32 bytes)
    ///   - 66-char hex  compressed public key (33 bytes, 02/03 prefix)
    ///   - Raw `Data`   32-byte x-only or 33-byte compressed
    ///
    /// - Returns: `sp1...` address string + the two public keys for use in sending.
    public static func spAddress(fromNpub npub: String) throws -> SilentPaymentAddress {
        let compressed = try resolveNpubToCompressed(npub)
        return try deriveAddress(fromCompressedPubKey: compressed)
    }

    /// Same as above but accepts raw bytes directly.
    /// Pass either 32-byte x-only or 33-byte compressed.
    public static func spAddress(fromNpubBytes bytes: Data) throws -> SilentPaymentAddress {
        let compressed = try normaliseToCompressed(bytes)
        return try deriveAddress(fromCompressedPubKey: compressed)
    }

    // MARK: - nsec → SilentPaymentKeyPair (for receiving / sweeping)

    /// Derive a full BIP-352 key pair from a Nostr private key.
    /// Accepts `nsec1...` bech32 string or raw 32-byte Data.
    public static func keyPair(fromNsec nsec: String) throws -> SilentPaymentKeyPair {
        let raw = try decodeNsec(nsec)
        return try keyPair(fromNsecBytes: raw)
    }

    public static func keyPair(fromNsecBytes nsecBytes: Data) throws -> SilentPaymentKeyPair {
        guard nsecBytes.count == 32 else {
            throw SilentPaymentError.nostrKeyDerivationFailed
        }
        // P = d·G
        let P = try Secp256k1.publicKey(from: nsecBytes)

        let tScan  = TaggedHash.nostrSPScan(P)
        let tSpend = TaggedHash.nostrSPSpend(P)

        let scanPub  = try Secp256k1.addTweakToPubKey(P, tweak: tScan)
        let spendPub = try Secp256k1.addTweakToPubKey(P, tweak: tSpend)
        let scanPriv  = try Secp256k1.addTweakToPrivKey(nsecBytes, tweak: tScan)
        let spendPriv = try Secp256k1.addTweakToPrivKey(nsecBytes, tweak: tSpend)

        let spAddressStr = try Bech32m.encodeSilentPayment(scanPubKey: scanPub, spendPubKey: spendPub)
        let address = SilentPaymentAddress(
            scanPublicKey:  scanPub,
            spendPublicKey: spendPub,
            address: spAddressStr
        )
        return SilentPaymentKeyPair(
            scanPrivateKey:  scanPriv,
            scanPublicKey:   scanPub,
            spendPrivateKey: spendPriv,
            spendPublicKey:  spendPub,
            address: address
        )
    }

    // MARK: - Backward compat (old names)
    public static func deriveKeyPair(from nsecBytes: Data) throws -> SilentPaymentKeyPair {
        try keyPair(fromNsecBytes: nsecBytes)
    }
    public static func deriveAddress(from npubBytes: Data) throws -> SilentPaymentAddress {
        try spAddress(fromNpubBytes: npubBytes)
    }

    // MARK: - Nostr key bech32 encode/decode

    /// Decode `nsec1...` → raw 32-byte private key.
    public static func decodeNsec(_ nsec: String) throws -> Data {
        let (hrp, fiveBit) = try Bech32m.decode(nsec)
        guard hrp == "nsec" else { throw SilentPaymentError.nostrKeyDerivationFailed }
        let bytes = try Bech32m.convertBits(fiveBit, from: 5, to: 8, pad: false)
        guard bytes.count == 32 else { throw SilentPaymentError.nostrKeyDerivationFailed }
        return Data(bytes)
    }

    /// Decode `npub1...` → 33-byte compressed public key.
    public static func decodeNpub(_ npub: String) throws -> Data {
        let (hrp, fiveBit) = try Bech32m.decode(npub)
        guard hrp == "npub" else { throw SilentPaymentError.invalidPublicKey }
        let bytes = try Bech32m.convertBits(fiveBit, from: 5, to: 8, pad: false)
        guard bytes.count == 32 else { throw SilentPaymentError.invalidPublicKey }
        return Data([0x02]) + Data(bytes)   // Nostr x-only → compressed even-Y
    }

    /// Encode a 33-byte compressed public key as `npub1...` bech32 (x-only, strip prefix).
    public static func encodeNpub(_ compressedPubKey: Data) throws -> String {
        guard compressedPubKey.count == 33 else { throw SilentPaymentError.invalidPublicKey }
        let xOnly = compressedPubKey.dropFirst()
        let fiveBit = try Bech32m.convertBits(Array(xOnly), from: 8, to: 5, pad: true)
        return Bech32m.encode(hrp: "npub", data: fiveBit)
    }

    // MARK: - Internal

    private static func deriveAddress(fromCompressedPubKey P: Data) throws -> SilentPaymentAddress {
        let tScan  = TaggedHash.nostrSPScan(P)
        let tSpend = TaggedHash.nostrSPSpend(P)
        let scanPub  = try Secp256k1.addTweakToPubKey(P, tweak: tScan)
        let spendPub = try Secp256k1.addTweakToPubKey(P, tweak: tSpend)
        let spAddressStr = try Bech32m.encodeSilentPayment(scanPubKey: scanPub, spendPubKey: spendPub)
        return SilentPaymentAddress(
            scanPublicKey:  scanPub,
            spendPublicKey: spendPub,
            address: spAddressStr
        )
    }

    /// Accept npub1..., 64-hex (x-only), 66-hex (compressed), or raw Data string
    private static func resolveNpubToCompressed(_ input: String) throws -> Data {
        let s = input.trimmingCharacters(in: .whitespaces)

        // npub1... bech32
        if s.lowercased().hasPrefix("npub1") {
            return try decodeNpub(s)
        }

        // 66-char hex → 33-byte compressed
        if s.count == 66, let d = Data(hexString: s) {
            guard d[0] == 0x02 || d[0] == 0x03 else {
                throw SilentPaymentError.invalidPublicKey
            }
            return d
        }

        // 64-char hex → 32-byte x-only, assume even Y
        if s.count == 64, let d = Data(hexString: s) {
            return Data([0x02]) + d
        }

        throw SilentPaymentError.invalidPublicKey
    }

    private static func normaliseToCompressed(_ bytes: Data) throws -> Data {
        switch bytes.count {
        case 32:
            return Data([0x02]) + bytes          // x-only → even-Y compressed
        case 33:
            guard bytes[0] == 0x02 || bytes[0] == 0x03 else {
                throw SilentPaymentError.invalidPublicKey
            }
            return bytes
        default:
            throw SilentPaymentError.invalidPublicKey
        }
    }
}

