// Tests/SilentPaymentsKitTests/SilentPaymentTests.swift
//
// Test vectors sourced from:
//   • BIP-352 test vectors: https://github.com/bitcoin/bips/blob/master/bip-0352/
//   • NSW derivation: trbouma's gist

import XCTest
@testable import SilentPaymentsKit

final class SilentPaymentTests: XCTestCase {

    // MARK: - Bech32m Address Codec

    func testBech32mRoundTrip() throws {
        // Generate two random 33-byte "keys" for testing codec symmetry
        let fakeScan  = Data(repeating: 0x02, count: 1) + Data(repeating: 0xAB, count: 32)
        let fakeSpend = Data(repeating: 0x03, count: 1) + Data(repeating: 0xCD, count: 32)

        let encoded = try Bech32m.encodeSilentPayment(scanPubKey: fakeScan, spendPubKey: fakeSpend)
        XCTAssertTrue(encoded.hasPrefix("sp1"), "Address must start with sp1")

        let (decodedScan, decodedSpend) = try Bech32m.decodeSilentPayment(encoded)
        XCTAssertEqual(decodedScan,  fakeScan,  "Scan key round-trip failed")
        XCTAssertEqual(decodedSpend, fakeSpend, "Spend key round-trip failed")
    }

    func testKnownAddressDecode() throws {
        // Real address from silentpayments.xyz docs
        let address = "sp1qqweplq6ylpfrzuq6hfznzmv28djsraupudz0s0dclyt8erh70pgwxqkz2ydatksrdzf770umsntsmcjp4kcz7jqu03jeszh0gdmpjzmrf5u4zh0c"
        let (scan, spend) = try Bech32m.decodeSilentPayment(address)
        XCTAssertEqual(scan.count,  33, "Scan key should be 33 bytes")
        XCTAssertEqual(spend.count, 33, "Spend key should be 33 bytes")
    }

    // MARK: - Nostr Silent Wallet Derivation

    func testNSWDerivationIsDeterministic() throws {
        // Any 32-byte value can be an nsec
        let nsec = Data(repeating: 0x42, count: 32)
        let kp1  = try NostrSilentWalletAdapter.deriveKeyPair(from: nsec)
        let kp2  = try NostrSilentWalletAdapter.deriveKeyPair(from: nsec)

        XCTAssertEqual(kp1.scanPrivateKey,  kp2.scanPrivateKey,  "Determinism: scan private key")
        XCTAssertEqual(kp1.spendPrivateKey, kp2.spendPrivateKey, "Determinism: spend private key")
        XCTAssertEqual(kp1.address.address, kp2.address.address, "Determinism: sp1 address")
    }

    func testNSWAddressDerivationFromNpub() throws {
        let nsec     = Data(repeating: 0x77, count: 32)
        let kpFull   = try NostrSilentWalletAdapter.deriveKeyPair(from: nsec)
        // Derive address from public key only (what a sender does)
        let npubBytes = try Secp256k1Helper.publicKey(from: nsec)
        let addrOnly  = try NostrSilentWalletAdapter.deriveAddress(from: npubBytes)

        XCTAssertEqual(
            kpFull.address.address,
            addrOnly.address,
            "Address derived from nsec must match address derived from npub"
        )
    }

    func testNSWScanAndSpendKeysAreDistinct() throws {
        let nsec = Data(repeating: 0x11, count: 32)
        let kp   = try NostrSilentWalletAdapter.deriveKeyPair(from: nsec)
        XCTAssertNotEqual(kp.scanPrivateKey, kp.spendPrivateKey)
        XCTAssertNotEqual(kp.scanPublicKey,  kp.spendPublicKey)
    }

    func testNSWAddressVerification() throws {
        let nsec = Data(repeating: 0x55, count: 32)
        let kp   = try NostrSilentWalletAdapter.deriveKeyPair(from: nsec)
        let npub = try Secp256k1Helper.publicKey(from: nsec)

        // Encode npub as bech32 for the verification call
        let npubFiveBit = try Bech32m.convertBits(Array(Secp256k1Helper.xOnlyKey(npub)), from: 8, to: 5, pad: true)
        let npubStr     = Bech32m.encode(hrp: "npub", data: npubFiveBit)

        let isValid = try SilentPaymentWallet.verifyNSWAddress(kp.address.address, npub: npubStr)
        XCTAssertTrue(isValid, "NSW address should verify against its npub")
    }

    // MARK: - Sender Output Derivation

    func testSenderDerivesUniqueOutputPerTransaction() throws {
        // Two different outpoints → two different outputs even for same address
        let recipientNsec = Data(repeating: 0x33, count: 32)
        let kp = try NostrSilentWalletAdapter.deriveKeyPair(from: recipientNsec)

        let senderPriv = Data(repeating: 0x66, count: 32)
        let outpoint1  = Data(repeating: 0xAA, count: 36)
        let outpoint2  = Data(repeating: 0xBB, count: 36)

        let input1 = SilentPaymentInput(outpoint: outpoint1, privateKey: senderPriv, inputType: .p2wpkh)
        let input2 = SilentPaymentInput(outpoint: outpoint2, privateKey: senderPriv, inputType: .p2wpkh)

        let out1 = try SilentPaymentSender.deriveOutputKeys(inputs: [input1], recipient: kp.address)
        let out2 = try SilentPaymentSender.deriveOutputKeys(inputs: [input2], recipient: kp.address)

        XCTAssertNotEqual(out1[0], out2[0], "Different outpoints must yield different output keys")
    }

    func testMultipleOutputsForSameRecipient() throws {
        let recipientNsec = Data(repeating: 0x22, count: 32)
        let kp = try NostrSilentWalletAdapter.deriveKeyPair(from: recipientNsec)

        let senderPriv = Data(repeating: 0x44, count: 32)
        let outpoint   = Data(repeating: 0xCC, count: 36)
        let input = SilentPaymentInput(outpoint: outpoint, privateKey: senderPriv, inputType: .p2wpkh)

        let outputs = try SilentPaymentSender.deriveOutputKeys(inputs: [input], recipient: kp.address, count: 3)
        XCTAssertEqual(outputs.count, 3)
        XCTAssertNotEqual(outputs[0], outputs[1])
        XCTAssertNotEqual(outputs[1], outputs[2])
    }

    // MARK: - Sender/Receiver Round-Trip

    func testScanWithTweakFindsOutput() throws {
        let recipientNsec = Data(repeating: 0x99, count: 32)
        let kp = try NostrSilentWalletAdapter.deriveKeyPair(from: recipientNsec)

        let senderPriv  = Data((0..<32).map { _ in UInt8.random(in: 1...254) })
        let outpointRaw = Data((0..<36).map { _ in UInt8.random(in: 0...255) })
        let input = SilentPaymentInput(outpoint: outpointRaw, privateKey: senderPriv, inputType: .p2wpkh)

        // Sender derives output key
        let outputKeys = try SilentPaymentSender.deriveOutputKeys(inputs: [input], recipient: kp.address)
        let xOnly      = Secp256k1Helper.xOnlyKey(outputKeys[0])

        // Sender computes tweak for notification
        let tweakData = try SilentPaymentSender.computeTweak(inputs: [input])

        // Receiver scans with tweak (fast path)
        let found = try SilentPaymentReceiver.scanWithTweak(
            keyPair: kp,
            tweak: tweakData,
            taprootOutputs: [xOnly]  // simulate a tx with this one output
        )

        XCTAssertEqual(found.count, 1, "Should find exactly one output")
        XCTAssertEqual(found[0].taprootXOnlyKey, xOnly, "Output key should match")
        XCTAssertNil(found[0].label, "Unlabeled output should have nil label")
    }

    func testScanIgnoresUnrelatedOutputs() throws {
        let recipientNsec = Data(repeating: 0x88, count: 32)
        let kp = try NostrSilentWalletAdapter.deriveKeyPair(from: recipientNsec)

        let senderPriv  = Data((0..<32).map { _ in UInt8.random(in: 1...254) })
        let outpointRaw = Data((0..<36).map { _ in UInt8.random(in: 0...255) })
        let input = SilentPaymentInput(outpoint: outpointRaw, privateKey: senderPriv, inputType: .p2wpkh)

        let tweakData = try SilentPaymentSender.computeTweak(inputs: [input])

        // Pass random outputs that don't belong to this wallet
        let randomOutput = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let found = try SilentPaymentReceiver.scanWithTweak(
            keyPair: kp,
            tweak: tweakData,
            taprootOutputs: [randomOutput]
        )

        XCTAssertEqual(found.count, 0, "Should find no outputs for unrelated keys")
    }

    // MARK: - Wallet Facade

    func testWalletPaymentURIFormat() throws {
        let nsec   = Data(repeating: 0x12, count: 32)
        let wallet = try SilentPaymentWallet(source: .nostr(nsec: nsec))
        let uri    = wallet.paymentURI(
            npub: "npub1test",
            relays: ["wss://relay.example.com"]
        )
        XCTAssertTrue(uri.hasPrefix("bitcoin:?sp1"), "URI should start with bitcoin:?sp1")
        XCTAssertTrue(uri.contains("npub=npub1test"))
        XCTAssertTrue(uri.contains("relays=wss://relay.example.com"))
    }

    func testWalletLabelCreatesDistinctAddress() throws {
        let nsec   = Data(repeating: 0x34, count: 32)
        let wallet = try SilentPaymentWallet(source: .nostr(nsec: nsec))

        let labeled = try wallet.createLabel("donations")
        XCTAssertNotEqual(labeled.address, wallet.address.address, "Labeled address must differ from base")
        XCTAssertEqual(labeled.scanPublicKey, wallet.address.scanPublicKey, "Scan key is shared across labels")
    }

    func testWalletRawKeyInit() throws {
        let scanPriv  = Data((0..<32).map { _ in UInt8.random(in: 1...254) })
        let spendPriv = Data((0..<32).map { _ in UInt8.random(in: 1...254) })
        let wallet = try SilentPaymentWallet(source: .rawKeys(scanPrivKey: scanPriv, spendPrivKey: spendPriv))
        XCTAssertTrue(wallet.address.address.hasPrefix("sp1"))
    }

    // MARK: - Notification Codec

    func testNotificationJSONRoundTrip() throws {
        let notification = SilentPaymentNotification(
            txid: "5a45ff552ec2193faa2a964f7bbf99574786045f38248ea4a5ca1ff1166a1736",
            tweak: "03464a0fdc066dc95f09ef85794ac86982de71875e513c758188b3f01c09e546fb",
            blockhash: "94e561958b0270a6a0496fa8313712787dcacf91b3d546493aea0e7efce0fc45"
        )
        let encoded = try JSONEncoder().encode(notification)
        let decoded = try JSONDecoder().decode(SilentPaymentNotification.self, from: encoded)
        XCTAssertEqual(decoded.txid,      notification.txid)
        XCTAssertEqual(decoded.tweak,     notification.tweak)
        XCTAssertEqual(decoded.blockhash, notification.blockhash)
    }

    func testNotificationWithoutBlockhash() throws {
        let notification = SilentPaymentNotification(txid: "abc123", tweak: "def456")
        let encoded = try JSONEncoder().encode(notification)
        let decoded = try JSONDecoder().decode(SilentPaymentNotification.self, from: encoded)
        XCTAssertNil(decoded.blockhash)
    }
}
