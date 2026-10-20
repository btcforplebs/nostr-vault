import XCTest
@testable import MediaLogic

/// The sweep sends the whole balance and cannot be undone, so the address
/// check is the only thing between a bad paste and lost funds. Vectors are
/// from BIP173, BIP350 and BIP86, cross-checked against an independent
/// implementation.
final class BitcoinAddressTests: XCTestCase {

    func testAcceptsEveryMainnetTypeTheSweepCanPay() {
        XCTAssertEqual(BitcoinAddress.mainnetKind("1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"), .p2pkh)
        XCTAssertEqual(BitcoinAddress.mainnetKind("3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy"), .p2sh)
        XCTAssertEqual(BitcoinAddress.mainnetKind("BC1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KV8F3T4"), .p2wpkh)
        XCTAssertEqual(BitcoinAddress.mainnetKind("bc1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3qccfmv3"), .p2wsh)
        XCTAssertEqual(BitcoinAddress.mainnetKind("bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr"), .p2tr)
    }

    func testNormalizedTrimsAPastedNewline() {
        let address = "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr"
        XCTAssertEqual(BitcoinAddress.normalizedMainnet("  \(address)\n"), address)
    }

    /// One wrong character: the old gate (non-empty text) let each through.
    func testRejectsAOneCharacterTypo() {
        XCTAssertNil(BitcoinAddress.mainnetKind("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t5"))
        XCTAssertNil(BitcoinAddress.mainnetKind("1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN3"))
        XCTAssertNil(BitcoinAddress.mainnetKind("bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcs"))
    }

    func testRejectsATruncatedPaste() {
        XCTAssertNil(BitcoinAddress.mainnetKind("bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxq"))
        XCTAssertNil(BitcoinAddress.mainnetKind("1BvBMSEYstWetqTFn5Au4m4GFg7x"))
        XCTAssertNil(BitcoinAddress.normalizedMainnet(""))
        XCTAssertNil(BitcoinAddress.normalizedMainnet("   "))
    }

    func testRejectsOtherNetworks() {
        XCTAssertNil(BitcoinAddress.mainnetKind("tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx"))
        XCTAssertNil(BitcoinAddress.mainnetKind("mipcBbFg9gMiCh81Kj8tqqdgoZub1ZJRfn"))
    }

    func testRejectsMixedCase() {
        XCTAssertNil(BitcoinAddress.mainnetKind("bc1qW508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"))
    }

    /// Taproot under the old bech32 checksum is the BIP350 trap; v2+ is not
    /// something the sweep can pay.
    func testRejectsWrongChecksumVariantAndUnknownVersions() {
        XCTAssertEqual(BitcoinAddress.mainnetKind("bc1pqqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0sg5tmnz"), .p2tr)
        XCTAssertNil(BitcoinAddress.mainnetKind("bc1pqqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0sagmhkq"))
        XCTAssertNil(BitcoinAddress.mainnetKind("bc1zqqqqqqqqqqqqqqqqqqqqqqqqqqr3t3q4"))
    }

    func testRejectsNonAddressText() {
        XCTAssertNil(BitcoinAddress.mainnetKind("npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m"))
        XCTAssertNil(BitcoinAddress.mainnetKind("bitcoin:bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr"))
        XCTAssertNil(BitcoinAddress.mainnetKind("0OIl000000000000000000000000"))
    }
}
