// Sources/SilentPaymentsKit/SilentPaymentWallet.swift
//
// SilentPaymentWallet — the high-level facade for iOS app integration.
//
// Supports three key sources:
//   1. BIP-32 HD wallet (standard Bitcoin wallet seed)
//   2. Nostr nsec (Nostr Silent Wallet — NSW)
//   3. Raw secp256k1 key pair (advanced / custom)
//
// Usage:
//   let wallet = try SilentPaymentWallet(source: .nostr(nsec: nsecBytes))
//   let address = wallet.address   // "sp1qq..."
//   let outputs = try await wallet.scanTransaction(txid: "...", tweak: tweakHex)

import Foundation

// MARK: - Key Source

public enum SilentPaymentKeySource {
    /// Standard Bitcoin wallet — BIP-32 seed + BIP-352 derivation path
    case bip32(masterKey: Data, chainCode: Data, network: BIP32Adapter.Network, account: UInt32)

    /// Nostr identity wallet (NSW) — derived deterministically from nsec
    case nostr(nsec: Data)

    /// Raw keys — bring your own scan/spend private keys
    case rawKeys(scanPrivKey: Data, spendPrivKey: Data)
}

// MARK: - Wallet

public final class SilentPaymentWallet {

    // MARK: Public properties

    public let keyPair: SilentPaymentKeyPair
    public var address: SilentPaymentAddress { keyPair.address }

    /// Labels this wallet has issued (m values, never use m=0 externally — reserved for change)
    public private(set) var labels: [UInt32: String] = [:]  // m → human label
    private var nextLabelM: UInt32 = 1

    // MARK: Init

    public init(source: SilentPaymentKeySource) throws {
        switch source {
        case .bip32(let masterKey, let chainCode, let network, let account):
            self.keyPair = try BIP32Adapter.deriveKeyPair(
                masterKey: masterKey,
                masterChainCode: chainCode,
                network: network,
                account: account
            )

        case .nostr(let nsec):
            self.keyPair = try NostrSilentWalletAdapter.deriveKeyPair(from: nsec)

        case .rawKeys(let scanPriv, let spendPriv):
            let scanPub  = try Secp256k1Helper.publicKey(from: scanPriv)
            let spendPub = try Secp256k1Helper.publicKey(from: spendPriv)
            let spStr    = try Bech32m.encodeSilentPayment(scanPubKey: scanPub, spendPubKey: spendPub)
            let addr     = SilentPaymentAddress(
                scanPublicKey: scanPub, spendPublicKey: spendPub, address: spStr
            )
            self.keyPair = SilentPaymentKeyPair(
                scanPrivateKey: scanPriv, scanPublicKey: scanPub,
                spendPrivateKey: spendPriv, spendPublicKey: spendPub,
                address: addr
            )
        }
    }

    // MARK: - Receiving: scan a transaction

    /// Fast scan using a Nostr notification tweak (avoids full input re-scan).
    ///
    /// - Parameters:
    ///   - notification:      The notification received from the sender.
    ///   - taprootOutputsHex: All x-only (32-byte) Taproot output keys in the tx, as hex strings.
    /// - Returns: Any outputs in this transaction that belong to this wallet.
    public func scanWithNotification(
        _ notification: SilentPaymentNotification,
        taprootOutputsHex: [String]
    ) throws -> [SilentPaymentOutput] {
        guard let tweakData = Data(hexString: notification.tweak) else {
            throw SilentPaymentError.invalidPublicKey
        }
        let outputs = taprootOutputsHex.compactMap { Data(hexString: $0) }
        return try SilentPaymentReceiver.scanWithTweak(
            keyPair: keyPair,
            tweak: tweakData,
            taprootOutputs: outputs,
            labels: Array(labels.keys)
        )
    }

    /// Full scan from raw transaction inputs (no notification available).
    ///
    /// - Parameters:
    ///   - inputs:            (outpoint hex, pubkey hex) pairs for all eligible inputs.
    ///   - taprootOutputsHex: All Taproot x-only output keys in the tx, as hex strings.
    public func scanWithInputs(
        inputs: [(outpoint: String, publicKey: String)],
        taprootOutputsHex: [String]
    ) throws -> [SilentPaymentOutput] {
        let parsedInputs = try inputs.map { input -> (outpoint: Data, publicKey: Data) in
            guard let op  = Data(hexString: input.outpoint),
                  let pub = Data(hexString: input.publicKey)
            else { throw SilentPaymentError.invalidOutpoint }
            return (op, pub)
        }
        let outputs = taprootOutputsHex.compactMap { Data(hexString: $0) }
        return try SilentPaymentReceiver.scanWithInputs(
            keyPair: keyPair,
            inputs: parsedInputs,
            taprootOutputs: outputs,
            labels: Array(labels.keys)
        )
    }

    // MARK: - Sending: derive output key for a recipient

    /// Derive the P2TR output public key(s) for a silent payment to `recipient`.
    ///
    /// - Parameters:
    ///   - recipient: The recipient's `sp1...` address string.
    ///   - inputs:    The inputs you will use in this transaction.
    ///   - count:     Number of outputs to create for this recipient (usually 1).
    /// - Returns: Compressed 33-byte public keys. Use x-only (drop first byte) for P2TR.
    public func deriveOutputKey(
        to recipient: String,
        inputs: [SilentPaymentInput],
        count: UInt32 = 1
    ) throws -> [Data] {
        let (scanPub, spendPub) = try Bech32m.decodeSilentPayment(recipient)
        let recipientAddress = SilentPaymentAddress(
            scanPublicKey: scanPub,
            spendPublicKey: spendPub,
            address: recipient
        )
        return try SilentPaymentSender.deriveOutputKeys(
            inputs: inputs,
            recipient: recipientAddress,
            count: count
        )
    }

    /// Compute the `tweak` field for a Nostr notification after building a tx.
    public func computeNotificationTweak(inputs: [SilentPaymentInput]) throws -> String {
        let tweak = try SilentPaymentSender.computeTweak(inputs: inputs)
        return tweak.hexString
    }

    // MARK: - Labels

    /// Issue a new labeled silent payment address (for tracking payment sources).
    /// - Parameter humanLabel: A human-readable tag (e.g. "donations", "exchange").
    /// - Returns: The labeled `sp1...` address.
    public func createLabel(_ humanLabel: String) throws -> SilentPaymentAddress {
        let m = nextLabelM
        nextLabelM += 1
        labels[m] = humanLabel

        // Labeled spend key: Bm = Bspend + hash(bscan || m)·G
        var preimage = keyPair.scanPrivateKey
        preimage.append(UInt8((m >> 24) & 0xFF))
        preimage.append(UInt8((m >> 16) & 0xFF))
        preimage.append(UInt8((m >>  8) & 0xFF))
        preimage.append(UInt8( m        & 0xFF))
        let labelScalar = TaggedHash.labelHash(preimage)
        let labeledSpendPub = try Secp256k1Helper.addTweakToPubKey(keyPair.spendPublicKey, tweak: labelScalar)

        let spStr = try Bech32m.encodeSilentPayment(
            scanPubKey: keyPair.scanPublicKey,
            spendPubKey: labeledSpendPub
        )
        return SilentPaymentAddress(
            scanPublicKey: keyPair.scanPublicKey,
            spendPublicKey: labeledSpendPub,
            address: spStr
        )
    }

    // MARK: - NSW: verify a recipient's address from their npub

    /// Anti-spoofing: given an npub, derive the expected SP address and compare.
    /// Returns `true` if the address you have matches what's derived from the identity.
    public static func verifyNSWAddress(_ spAddress: String, npub: String) throws -> Bool {
        let npubBytes = try NostrSilentWalletAdapter.decodeNpub(npub)
        let expected  = try NostrSilentWalletAdapter.deriveAddress(from: npubBytes)
        return expected.address == spAddress
    }

    // MARK: - BIP-321 URI

    /// Generate a shareable BIP-321 payment URI with optional npub and relay hints.
    /// `bitcoin:?sp1q...=&npub=npub1...&relays=wss://relay1.example.com`
    public func paymentURI(npub: String? = nil, relays: [String] = []) -> String {
        var parts = ["bitcoin:?\(address.address)="]
        if let n = npub { parts.append("npub=\(n)") }
        if !relays.isEmpty { parts.append("relays=\(relays.joined(separator: ","))") }
        return parts.joined(separator: "&")
    }
}
