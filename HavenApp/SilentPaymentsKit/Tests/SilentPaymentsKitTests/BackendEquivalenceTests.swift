// Tests/SilentPaymentsKitTests/BackendEquivalenceTests.swift
//
// Runs the same secp256k1 operations against all available backends
// and asserts they produce identical results.
// If GigaBitcoin changes its API, the GigaBitcoinBackend tests will fail
// while LibsecrBackend and AppleCryptoBackend continue passing — giving
// you a clear diff to fix the wrapper.

import XCTest
@testable import SilentPaymentsKit

final class BackendEquivalenceTests: XCTestCase {

    // Well-known secp256k1 test vectors (scalar, expected pubkey)
    // Private key = 1 → G (the generator point)
    private let privKey1 = Data([
        0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
        0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,1
    ])
    // Expected compressed public key for privKey=1 (the generator point G)
    private let expectedG = Data(hexString:
        "0279BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798")!

    private let privKey2 = Data([
        0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
        0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,2
    ])
    private let tweak32 = Data([
        0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
        0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,3
    ])

    // All backends to test
    private var backends: [(name: String, backend: any Secp256k1Backend)] {
        var list: [(String, any Secp256k1Backend)] = [
            ("GigaBitcoin", GigaBitcoinBackend()),
            ("AppleCrypto", AppleCryptoBackend()),
        ]
        #if canImport(LibSecp256k1)
        list.append(("LibSecp256k1 C", LibsecrBackend()))
        #endif
        return list
    }

    // MARK: - privateKeyToPublicKey

    func testPublicKeyDerivation_KnownVector() throws {
        for (name, backend) in backends {
            let pubKey = try backend.privateKeyToPublicKey(privKey1)
            XCTAssertEqual(pubKey, expectedG,
                "[\(name)] privKey=1 should yield generator point G")
        }
    }

    func testPublicKeyDerivation_AllBackendsAgree() throws {
        let results = try backends.map { (name, backend) in
            (name, try backend.privateKeyToPublicKey(privKey2))
        }
        let first = results[0].1
        for (name, result) in results.dropFirst() {
            XCTAssertEqual(result, first, "[\(name)] pubkey disagrees with \(results[0].0)")
        }
    }

    // MARK: - addTweakToPrivateKey

    func testPrivKeyTweak_AllBackendsAgree() throws {
        let results = try backends.map { (name, backend) in
            (name, try backend.addTweakToPrivateKey(privKey1, tweak: tweak32))
        }
        assertAllEqual(results, label: "addTweakToPrivateKey")
    }

    // MARK: - multiplyPrivateKey

    func testPrivKeyMultiply_AllBackendsAgree() throws {
        let results = try backends.map { (name, backend) in
            (name, try backend.multiplyPrivateKey(privKey2, scalar: tweak32))
        }
        assertAllEqual(results, label: "multiplyPrivateKey")
    }

    // MARK: - sumPrivateKeys

    func testSumPrivateKeys_AllBackendsAgree() throws {
        let results = try backends.map { (name, backend) in
            (name, try backend.sumPrivateKeys([privKey1, privKey2]))
        }
        assertAllEqual(results, label: "sumPrivateKeys")
    }

    // MARK: - addTweakToPublicKey

    func testPubKeyTweak_AllBackendsAgree() throws {
        let results = try backends.map { (name, backend) in
            let pub = try backend.privateKeyToPublicKey(privKey1)
            return (name, try backend.addTweakToPublicKey(pub, tweak: tweak32))
        }
        assertAllEqual(results, label: "addTweakToPublicKey")
    }

    // MARK: - multiplyPublicKey

    func testPubKeyMultiply_AllBackendsAgree() throws {
        let results = try backends.map { (name, backend) in
            let pub = try backend.privateKeyToPublicKey(privKey1)
            return (name, try backend.multiplyPublicKey(pub, scalar: tweak32))
        }
        assertAllEqual(results, label: "multiplyPublicKey")
    }

    // MARK: - combinePublicKeys (P1 + P2 = P3)

    func testCombinePublicKeys_AllBackendsAgree() throws {
        let results = try backends.map { (name, backend) -> (String, Data) in
            let p1 = try backend.privateKeyToPublicKey(privKey1)
            let p2 = try backend.privateKeyToPublicKey(privKey2)
            return (name, try backend.combinePublicKeys([p1, p2]))
        }
        assertAllEqual(results, label: "combinePublicKeys")
    }

    // MARK: - subtractPublicKeys

    func testSubtractPublicKeys_AllBackendsAgree() throws {
        let results = try backends.map { (name, backend) -> (String, Data) in
            let p1 = try backend.privateKeyToPublicKey(privKey1)
            let p2 = try backend.privateKeyToPublicKey(privKey2)
            return (name, try backend.subtractPublicKeys(p2, p1))  // 2G - 1G = 1G
        }
        assertAllEqual(results, label: "subtractPublicKeys")
        // 2G - G = G
        let gExpected = expectedG
        for (name, result) in results {
            XCTAssertEqual(result, gExpected, "[\(name)] 2G - G should equal G")
        }
    }

    // MARK: - negatePrivateKey

    func testNegatePrivateKey_SumIsZero() throws {
        for (name, backend) in backends {
            let k    = privKey2
            let negK = try backend.negatePrivateKey(k)
            // k + (-k) mod n should equal 0, but secp256k1 libs reject 0 as invalid.
            // Instead verify: pubKey(k) + pubKey(-k) = point at infinity (combine fails)
            let pk   = try backend.privateKeyToPublicKey(k)
            let pNk  = try backend.privateKeyToPublicKey(negK)
            XCTAssertThrowsError(
                try backend.combinePublicKeys([pk, pNk]),
                "[\(name)] k + (-k) should yield point at infinity (error)"
            )
        }
    }

    // MARK: - hasOddY

    func testHasOddY_ConsistentWithPubKey() throws {
        // Verify that hasOddY matches the actual prefix byte
        for (name, backend) in backends {
            let pub = try backend.privateKeyToPublicKey(privKey1)
            let isOdd = backend.hasOddY(pub)
            let prefixOdd = pub[0] == 0x03
            XCTAssertEqual(isOdd, prefixOdd, "[\(name)] hasOddY inconsistent with prefix byte")
        }
    }

    // MARK: - Cross-backend ECDH equivalence (core BIP-352 operation)

    func testECDH_CrossBackend() throws {
        // ECDH: privKey1 * pubKey(privKey2) should equal privKey2 * pubKey(privKey1)
        for (name, backend) in backends {
            let pub1 = try backend.privateKeyToPublicKey(privKey1)
            let pub2 = try backend.privateKeyToPublicKey(privKey2)

            let shared1 = try backend.multiplyPublicKey(pub2, scalar: privKey1)
            let shared2 = try backend.multiplyPublicKey(pub1, scalar: privKey2)

            XCTAssertEqual(shared1, shared2,
                "[\(name)] ECDH commutativity: a*B should equal b*A")
        }
    }

    // MARK: - NSW derivation produces same address across all backends

    func testNSWDerivation_AllBackendsProduceSameAddress() throws {
        let nsec = Data(repeating: 0x42, count: 32)
        var addresses = [(String, String)]()

        for (name, backend) in backends {
            // Temporarily swap the global backend
            let saved = Secp256k1.backend
            Secp256k1.backend = backend
            defer { Secp256k1.backend = saved }

            let kp = try NostrSilentWalletAdapter.deriveKeyPair(from: nsec)
            addresses.append((name, kp.address.address))
        }

        let firstAddress = addresses[0].1
        for (name, address) in addresses.dropFirst() {
            XCTAssertEqual(address, firstAddress,
                "[\(name)] NSW address disagrees with \(addresses[0].0)")
        }
    }

    // MARK: - Sender/receiver round-trip on all backends

    func testSenderReceiverRoundTrip_AllBackends() throws {
        let nsec = Data(repeating: 0x77, count: 32)
        let senderPriv = privKey2
        let outpoint   = Data(repeating: 0xAB, count: 36)

        for (name, backend) in backends {
            let saved = Secp256k1.backend
            Secp256k1.backend = backend
            defer { Secp256k1.backend = saved }

            let kp    = try NostrSilentWalletAdapter.deriveKeyPair(from: nsec)
            let input = SilentPaymentInput(outpoint: outpoint, privateKey: senderPriv, inputType: .p2wpkh)

            let outputKeys = try SilentPaymentSender.deriveOutputKeys(inputs: [input], recipient: kp.address)
            let xOnly      = Secp256k1.xOnlyKey(outputKeys[0])
            let tweak      = try SilentPaymentSender.computeTweak(inputs: [input])

            let found = try SilentPaymentReceiver.scanWithTweak(
                keyPair: kp,
                tweak: tweak,
                taprootOutputs: [xOnly]
            )

            XCTAssertEqual(found.count, 1, "[\(name)] Should find exactly one output")
        }
    }

    // MARK: - Helper

    private func assertAllEqual(_ results: [(String, Data)], label: String) {
        guard let first = results.first else { return }
        for (name, result) in results.dropFirst() {
            XCTAssertEqual(result, first.1,
                "[\(label)] [\(name)] disagrees with [\(first.0)]")
        }
    }
}

// MARK: - Data hex helper (test target)
private extension Data {
    init?(hexString: String) {
        let h = hexString.uppercased()
        var data = Data()
        var i = h.startIndex
        while i < h.endIndex {
            let j = h.index(i, offsetBy: 2)
            guard let byte = UInt8(h[i..<j], radix: 16) else { return nil }
            data.append(byte)
            i = j
        }
        self = data
    }
}
