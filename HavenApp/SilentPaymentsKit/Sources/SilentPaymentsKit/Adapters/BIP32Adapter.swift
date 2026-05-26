// Sources/SilentPaymentsKit/Adapters/BIP32Adapter.swift
//
// BIP-352 §Key Derivation — derives Silent Payment keys from a BIP-32 / BIP-84/86 wallet.
//
// BIP-352 specifies:
//   m/352'/coin_type'/account'/0'/0   → scan key
//   m/352'/coin_type'/account'/1'/0   → spend key
//
// coin_type: 0 = mainnet, 1 = testnet

import Foundation
import CryptoKit

public struct BIP32Adapter {

    // BIP-352 derivation paths
    public enum Network: UInt32 {
        case mainnet = 0
        case testnet = 1
    }

    /// Derive a Silent Payment key pair from a BIP-32 master private key (64 bytes: key || chain).
    /// Pass the raw 64 bytes of the HMAC-SHA512 output (BIP-32 master key derivation).
    ///
    /// In practice you'll call this after deriving the master key from a mnemonic
    /// using a library such as swift-bitcoin or your existing wallet seed handling code.
    public static func deriveKeyPair(
        masterKey: Data,        // 32-byte privkey
        masterChainCode: Data,  // 32-byte chain code
        network: Network = .mainnet,
        account: UInt32 = 0
    ) throws -> SilentPaymentKeyPair {

        // m/352'/coin'/account'/0'/0  → scan
        // m/352'/coin'/account'/1'/0  → spend
        let purpose: UInt32  = 0x80000160  // 352' (hardened)
        let coin: UInt32     = network.rawValue | 0x80000000  // hardened
        let acct: UInt32     = account | 0x80000000           // hardened
        let scanPath: [UInt32]  = [purpose, coin, acct, 0x80000000, 0]  // .../0'/0
        let spendPath: [UInt32] = [purpose, coin, acct, 0x80000001, 0]  // .../1'/0

        let scanKey  = try derivePrivateKey(key: masterKey, chainCode: masterChainCode, path: scanPath)
        let spendKey = try derivePrivateKey(key: masterKey, chainCode: masterChainCode, path: spendPath)

        let scanPub  = try Secp256k1Helper.publicKey(from: scanKey)
        let spendPub = try Secp256k1Helper.publicKey(from: spendKey)
        let spAddress = try Bech32m.encodeSilentPayment(scanPubKey: scanPub, spendPubKey: spendPub)
        let address   = SilentPaymentAddress(
            scanPublicKey:  scanPub,
            spendPublicKey: spendPub,
            address: spAddress
        )

        return SilentPaymentKeyPair(
            scanPrivateKey:  scanKey,
            scanPublicKey:   scanPub,
            spendPrivateKey: spendKey,
            spendPublicKey:  spendPub,
            address: address
        )
    }

    // MARK: - BIP-32 private child key derivation

    private static func derivePrivateKey(key: Data, chainCode: Data, path: [UInt32]) throws -> Data {
        var currentKey       = key
        var currentChainCode = chainCode

        for index in path {
            let (childKey, childChain) = try bip32ChildKey(
                parentKey: currentKey,
                parentChainCode: currentChainCode,
                index: index
            )
            currentKey       = childKey
            currentChainCode = childChain
        }
        return currentKey
    }

    /// BIP-32 CKD_priv
    private static func bip32ChildKey(
        parentKey: Data,
        parentChainCode: Data,
        index: UInt32
    ) throws -> (key: Data, chainCode: Data) {

        var data = Data()
        let isHardened = (index & 0x80000000) != 0

        if isHardened {
            // Hardened: 0x00 || parent_key || ser32(index)
            data.append(0x00)
            data.append(contentsOf: parentKey)
        } else {
            // Normal: compressed parent public key || ser32(index)
            let parentPub = try Secp256k1Helper.publicKey(from: parentKey)
            data.append(contentsOf: parentPub)
        }
        // ser32(index)
        data.append(UInt8((index >> 24) & 0xFF))
        data.append(UInt8((index >> 16) & 0xFF))
        data.append(UInt8((index >>  8) & 0xFF))
        data.append(UInt8( index        & 0xFF))

        // HMAC-SHA512(key: chainCode, data: data)
        let hmacKey = SymmetricKey(data: parentChainCode)
        let mac = HMAC<SHA512>.authenticationCode(for: data, using: hmacKey)
        let macBytes = Data(mac)

        let IL = macBytes.prefix(32)   // child key tweak
        let IR = macBytes.suffix(32)   // child chain code

        // child_key = (IL + parent_key) mod n
        let childKey = try Secp256k1Helper.addTweakToPrivKey(parentKey, tweak: Data(IL))
        return (childKey, Data(IR))
    }
}
