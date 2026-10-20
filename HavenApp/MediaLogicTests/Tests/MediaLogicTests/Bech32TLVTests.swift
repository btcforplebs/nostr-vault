import XCTest
@testable import MediaLogic

/// NIP-19 TLV lengths are one byte. A relay controls the bytes that go into
/// them (an addressable event's d tag, an event's kind), so oversized input
/// must fail softly rather than trap the app while building a share link.
final class Bech32TLVTests: XCTestCase {

    func testEncodesAnEntryUpTo255Bytes() {
        let entry = Bech32.encodeTLV(type: 0, data: Data(repeating: 0xab, count: 255))
        XCTAssertEqual(entry.count, 257)
        XCTAssertEqual(entry.prefix(2), Data([0, 255]))
    }

    /// A hostile relay's 300-byte d tag used to trap in UInt8(data.count).
    func testSkipsAnEntryOver255BytesInsteadOfTrapping() {
        XCTAssertEqual(Bech32.encodeTLV(type: 0, data: Data(repeating: 0x61, count: 300)), Data())
    }
}

final class Bech32NeventTests: XCTestCase {

    private let id = String(repeating: "a", count: 64)
    private let pubkey = String(repeating: "b", count: 64)

    /// Decoded TLV payload of an nevent, as (type, length) pairs.
    private func entries(_ nevent: String) -> [(UInt8, Int)] {
        guard let decoded = Bech32.decode(nevent), decoded.hrp == "nevent" else { return [] }
        var bytes = [UInt8](decoded.data)[...]
        var out = [(UInt8, Int)]()
        while bytes.count >= 2 {
            let type = bytes.removeFirst(), length = Int(bytes.removeFirst())
            out.append((type, length))
            bytes = bytes.dropFirst(length)
        }
        return out
    }

    func testIncludesTheKindWhenItFits() {
        let nevent = Bech32.encodeNevent(idHex: id, pubkeyHex: pubkey, kind: 30023)
        XCTAssertEqual(entries(nevent ?? "").map { $0.0 }, [0, 2, 3])
    }

    /// A relay can send any integer as kind; UInt32(kind) used to trap.
    func testLeavesOutAKindThatDoesNotFitInsteadOfTrapping() {
        for kind in [-1, 5_000_000_000, Int.max, Int.min] {
            let nevent = Bech32.encodeNevent(idHex: id, pubkeyHex: pubkey, kind: kind)
            XCTAssertEqual(entries(nevent ?? "").map { $0.0 }, [0, 2], "kind \(kind)")
        }
    }

    func testNilForIdsThatAreNotHex() {
        XCTAssertNil(Bech32.encodeNevent(idHex: "zz", pubkeyHex: pubkey, kind: 1))
    }
}
