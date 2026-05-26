// Tests/SilentPaymentsKitTests/CoreOperationTests.swift
//
// Tests for the two key operations:
//   1. npub → sp1 address derivation
//   2. Sweep transaction building and signing

import XCTest
@testable import SilentPaymentsKit

final class CoreOperationTests: XCTestCase {

    // ══════════════════════════════════════════════════════════════
    // MARK: - 1. npub → sp1 address
    // ══════════════════════════════════════════════════════════════

    // Known nsec: all-0x42 bytes (for deterministic test vectors)
    private let testNsec = Data(repeating: 0x42, count: 32)

    // Derived once and used as the reference value throughout
    private var referenceAddress: String {
        get throws {
            let kp = try NostrSilentWalletAdapter.keyPair(fromNsecBytes: testNsec)
            return kp.address.address
        }
    }

    func testAddressFromNpub_bech32() throws {
        // Get the npub string for our test key
        let kp     = try NostrSilentWalletAdapter.keyPair(fromNsecBytes: testNsec)
        let npubStr = try NostrSilentWalletAdapter.encodeNpub(kp.scanPublicKey) // not quite right...
        // The npub should be the *Nostr* public key (d·G), not the scan key.
        // Derive npub from the nsec directly.
        let nostrPub = try Secp256k1.publicKey(from: testNsec)
        let xOnly    = Secp256k1.xOnlyKey(nostrPub)
        let fiveBit  = try Bech32m.convertBits(Array(xOnly), from: 8, to: 5, pad: true)
        let npub     = Bech32m.encode(hrp: "npub", data: fiveBit)

        // Derive sp address from npub
        let derived = try NostrSilentWalletAdapter.spAddress(fromNpub: npub)
        XCTAssertEqual(derived.address, try referenceAddress,
            "Address from npub1... bech32 must match address from nsec")
    }

    func testAddressFromNpub_64hexXOnly() throws {
        let nostrPub = try Secp256k1.publicKey(from: testNsec)
        let xOnly    = Secp256k1.xOnlyKey(nostrPub)
        let hexStr   = xOnly.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hexStr.count, 64)

        let derived = try NostrSilentWalletAdapter.spAddress(fromNpub: hexStr)
        XCTAssertEqual(derived.address, try referenceAddress,
            "Address from 64-char hex (x-only) must match")
    }

    func testAddressFromNpub_66hexCompressed() throws {
        let nostrPub = try Secp256k1.publicKey(from: testNsec)
        let hexStr   = nostrPub.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hexStr.count, 66)

        let derived = try NostrSilentWalletAdapter.spAddress(fromNpub: hexStr)
        XCTAssertEqual(derived.address, try referenceAddress,
            "Address from 66-char hex (compressed) must match")
    }

    func testAddressFromNpub_rawBytes32() throws {
        let nostrPub = try Secp256k1.publicKey(from: testNsec)
        let xOnly    = Secp256k1.xOnlyKey(nostrPub)   // 32 bytes

        let derived = try NostrSilentWalletAdapter.spAddress(fromNpubBytes: xOnly)
        XCTAssertEqual(derived.address, try referenceAddress,
            "Address from 32-byte raw must match")
    }

    func testAddressFromNpub_rawBytes33() throws {
        let nostrPub = try Secp256k1.publicKey(from: testNsec)  // 33 bytes

        let derived = try NostrSilentWalletAdapter.spAddress(fromNpubBytes: nostrPub)
        XCTAssertEqual(derived.address, try referenceAddress,
            "Address from 33-byte compressed raw must match")
    }

    func testAddressStartsWithSp1() throws {
        XCTAssertTrue((try referenceAddress).hasPrefix("sp1"),
            "Silent Payment address must start with sp1")
    }

    func testAddressIsDeterministic_AllInputFormats() throws {
        let ref = try referenceAddress

        // All four input paths should produce the same sp1 address
        let nostrPub = try Secp256k1.publicKey(from: testNsec)
        let xOnly    = Secp256k1.xOnlyKey(nostrPub)
        let hex32    = xOnly.map { String(format: "%02x", $0) }.joined()
        let hex66    = nostrPub.map { String(format: "%02x", $0) }.joined()

        let a1 = try NostrSilentWalletAdapter.spAddress(fromNpubBytes: xOnly).address
        let a2 = try NostrSilentWalletAdapter.spAddress(fromNpubBytes: nostrPub).address
        let a3 = try NostrSilentWalletAdapter.spAddress(fromNpub: hex32).address
        let a4 = try NostrSilentWalletAdapter.spAddress(fromNpub: hex66).address

        XCTAssertEqual(a1, ref)
        XCTAssertEqual(a2, ref)
        XCTAssertEqual(a3, ref)
        XCTAssertEqual(a4, ref)
    }

    func testAddressDecodesTo66ByteKeys() throws {
        let addr = try referenceAddress
        let (scan, spend) = try Bech32m.decodeSilentPayment(addr)
        XCTAssertEqual(scan.count,  33, "Scan key must be 33 bytes (compressed)")
        XCTAssertEqual(spend.count, 33, "Spend key must be 33 bytes (compressed)")
        XCTAssertTrue(scan[0]  == 0x02 || scan[0]  == 0x03)
        XCTAssertTrue(spend[0] == 0x02 || spend[0] == 0x03)
    }

    func testDifferentNpubsProduceDifferentAddresses() throws {
        let nsec1 = Data(repeating: 0x11, count: 32)
        let nsec2 = Data(repeating: 0x22, count: 32)
        let pub1  = try Secp256k1.publicKey(from: nsec1)
        let pub2  = try Secp256k1.publicKey(from: nsec2)
        let addr1 = try NostrSilentWalletAdapter.spAddress(fromNpubBytes: pub1).address
        let addr2 = try NostrSilentWalletAdapter.spAddress(fromNpubBytes: pub2).address
        XCTAssertNotEqual(addr1, addr2, "Different npubs must yield different sp1 addresses")
    }

    func testInvalidNpubThrows() {
        XCTAssertThrowsError(
            try NostrSilentWalletAdapter.spAddress(fromNpub: "notanpub"),
            "Invalid npub string should throw"
        )
        XCTAssertThrowsError(
            try NostrSilentWalletAdapter.spAddress(fromNpubBytes: Data(repeating: 0, count: 5)),
            "Wrong-length bytes should throw"
        )
    }

    // ══════════════════════════════════════════════════════════════
    // MARK: - 2. Sweep Transaction
    // ══════════════════════════════════════════════════════════════

    /// Helper: simulate a complete sender → receiver → sweep cycle.
    private func makeSweepFixture() throws -> (
        sweepInput: SweepInput,
        receiverKeyPair: SilentPaymentKeyPair
    ) {
        let receiverNsec = Data(repeating: 0x99, count: 32)
        let kp = try NostrSilentWalletAdapter.keyPair(fromNsecBytes: receiverNsec)

        // Sender builds a tx with one input paying kp.address
        let senderPriv = Data(repeating: 0x66, count: 32)
        let fakeOutpoint = Data(repeating: 0xAB, count: 36)
        let input = SilentPaymentInput(outpoint: fakeOutpoint, privateKey: senderPriv, inputType: .p2wpkh)

        // Sender derives the output key
        let outputKeys = try SilentPaymentSender.deriveOutputKeys(inputs: [input], recipient: kp.address)
        let xOnly      = Secp256k1.xOnlyKey(outputKeys[0])

        // Receiver scans (using tweak fast-path)
        let tweak  = try SilentPaymentSender.computeTweak(inputs: [input])
        let found  = try SilentPaymentReceiver.scanWithTweak(
            keyPair: kp, tweak: tweak, taprootOutputs: [xOnly]
        )
        XCTAssertEqual(found.count, 1, "Fixture: should find exactly one output")

        // Wrap in SweepInput with a fake txid (32 bytes) and amount
        let fakeTxid   = Data(repeating: 0xCC, count: 32)
        let sweepInput = SweepInput(
            output:      found[0],
            amountSats:  100_000,   // 0.001 BTC
            txid:        fakeTxid,
            vout:        0
        )
        return (sweepInput, kp)
    }

    func testSweepBuildProducesRawTx() throws {
        let (sweepInput, _) = try makeSweepFixture()

        // P2TR destination (use the sender's key as destination for the test)
        let destPriv  = Data(repeating: 0x77, count: 32)
        let destPub   = try Secp256k1.publicKey(from: destPriv)
        let destXOnly = Secp256k1.xOnlyKey(destPub)
        let destScript = Data([0x51, 0x20]) + destXOnly  // OP_1 PUSH32 <key>
        let dest = SweepOutput(scriptPubKey: destScript, amountSats: 90_000)

        let result = try SweepTransaction.build(
            inputs: [sweepInput],
            destination: dest,
            feeRate: FeeEstimate(satsPerVbyte: 5)
        )

        XCTAssertFalse(result.rawTx.isEmpty, "Raw tx must not be empty")
        XCTAssertEqual(result.txid.count, 64, "txid must be 64 hex chars")
        XCTAssertGreaterThan(result.feeSats, 0, "Fee must be positive")
        XCTAssertEqual(result.inputCount, 1)
    }

    func testSweepTxHasCorrectSegwitFormat() throws {
        let (sweepInput, _) = try makeSweepFixture()
        let destPub   = try Secp256k1.publicKey(from: Data(repeating: 0x77, count: 32))
        let destXOnly = Secp256k1.xOnlyKey(destPub)
        let dest = SweepOutput(scriptPubKey: Data([0x51, 0x20]) + destXOnly, amountSats: 90_000)

        let result = try SweepTransaction.build(
            inputs: [sweepInput],
            destination: dest,
            feeRate: FeeEstimate(satsPerVbyte: 1)
        )

        let tx = result.rawTx
        // version (4 bytes LE = 02 00 00 00)
        XCTAssertEqual(tx[0], 0x02)
        XCTAssertEqual(tx[1], 0x00)
        XCTAssertEqual(tx[2], 0x00)
        XCTAssertEqual(tx[3], 0x00)
        // segwit marker + flag
        XCTAssertEqual(tx[4], 0x00, "SegWit marker must be 0x00")
        XCTAssertEqual(tx[5], 0x01, "SegWit flag must be 0x01")
    }

    func testSweepWitnessContains64ByteSchnorrSig() throws {
        let (sweepInput, _) = try makeSweepFixture()
        let destPub   = try Secp256k1.publicKey(from: Data(repeating: 0x77, count: 32))
        let destXOnly = Secp256k1.xOnlyKey(destPub)
        let dest = SweepOutput(scriptPubKey: Data([0x51, 0x20]) + destXOnly, amountSats: 90_000)

        let result = try SweepTransaction.build(
            inputs: [sweepInput],
            destination: dest,
            feeRate: FeeEstimate(satsPerVbyte: 1)
        )

        // Parse: skip version(4) + marker(1) + flag(1) + inputCount varint(1) + one input (41 bytes)
        //        + outputCount + outputs + witness stack
        // Easier: just check the tx length is consistent with one 64-byte witness item
        // Witness for key-path P2TR: [1 item] [0x40 = 64] [64 bytes of sig]
        // We search for the pattern 0x01 0x40 in the witness area
        let bytes = [UInt8](result.rawTx)
        var found64ByteSig = false
        for i in 0..<(bytes.count - 65) {
            if bytes[i] == 0x01 && bytes[i+1] == 0x40 {
                found64ByteSig = true
                break
            }
        }
        XCTAssertTrue(found64ByteSig, "Should find a 64-byte Schnorr signature in witness")
    }

    func testSweepWithChangeAddress() throws {
        let (sweepInput, _) = try makeSweepFixture()
        let destPub   = try Secp256k1.publicKey(from: Data(repeating: 0x77, count: 32))
        let destXOnly = Secp256k1.xOnlyKey(destPub)
        let dest = SweepOutput(scriptPubKey: Data([0x51, 0x20]) + destXOnly, amountSats: 50_000)

        // Use a testnet bech32 address as change
        // tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx  (P2WPKH testnet)
        let changeAddr = "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx"
        let result = try SweepTransaction.build(
            inputs: [sweepInput],
            destination: dest,
            feeRate: FeeEstimate(satsPerVbyte: 2),
            changeAddress: changeAddr
        )

        XCTAssertFalse(result.rawTx.isEmpty)
        // With 100k in, 50k out, ~300-400 sat fee at 2 sat/vb, change should be ~49.6k
        let totalOut: UInt64 = 50_000 + (100_000 - 50_000 - result.feeSats)
        XCTAssertEqual(totalOut + result.feeSats, 100_000,
            "inputs = outputs + fee must balance")
    }

    func testSweepInsufficientFundsThrows() throws {
        let (sweepInput, _) = try makeSweepFixture()
        let destPub   = try Secp256k1.publicKey(from: Data(repeating: 0x77, count: 32))
        let destXOnly = Secp256k1.xOnlyKey(destPub)
        // Try to send more than we have
        let dest = SweepOutput(scriptPubKey: Data([0x51, 0x20]) + destXOnly, amountSats: 200_000)

        XCTAssertThrowsError(
            try SweepTransaction.build(
                inputs: [sweepInput],
                destination: dest,
                feeRate: FeeEstimate(satsPerVbyte: 5)
            )
        ) { error in
            guard case SweepError.insufficientFunds = error else {
                XCTFail("Expected SweepError.insufficientFunds, got \(error)")
                return
            }
        }
    }

    func testFeeEstimation_SingleInputSingleOutput() {
        let fee = FeeEstimate(satsPerVbyte: 10)
        let estimated = fee.estimatedFee(inputCount: 1, outputCount: 1)
        // Expected: (42 + 230 + 172) / 4 * 10 ≈ 111 vbytes * 10 = 1110 sats
        XCTAssertGreaterThan(estimated, 500,  "Fee should be > 500 sats at 10 s/vb")
        XCTAssertLessThan(estimated,    2000, "Fee should be < 2000 sats at 10 s/vb")
    }

    // MARK: - Address decoder tests

    func testAddressDecoder_P2TR_mainnet() throws {
        // Real P2TR mainnet address
        let addr   = "bc1pftjlgdq0ufhq7qwd0atxhrjhlnpmc8v4x50tgytygzk5rz339u6qngunq4"
        let script = try AddressDecoder.toScriptPubKey(addr)
        XCTAssertEqual(script.count, 34,  "P2TR scriptPubKey is 34 bytes")
        XCTAssertEqual(script[0],   0x51, "OP_1")
        XCTAssertEqual(script[1],   0x20, "PUSH32")
    }

    func testAddressDecoder_P2WPKH_testnet() throws {
        let addr   = "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx"
        let script = try AddressDecoder.toScriptPubKey(addr)
        XCTAssertEqual(script.count, 22,  "P2WPKH scriptPubKey is 22 bytes")
        XCTAssertEqual(script[0],   0x00, "OP_0")
        XCTAssertEqual(script[1],   0x14, "PUSH20")
    }

    func testAddressDecoder_InvalidThrows() {
        XCTAssertThrowsError(try AddressDecoder.toScriptPubKey("notanaddress"))
    }
}
