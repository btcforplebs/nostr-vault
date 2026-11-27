import XCTest
@testable import MediaLogic

/// The second round of a quote lookup (2026-11-27): the quote's only hint,
/// nostr.mom, was down, and the note sat only on nostr-02.yakihonne.com, 7th
/// of 9 in its author's kind 10002. The app asked neither.
final class QuoteFetchRelaysTests: XCTestCase {
    private let id = "ea788c3024ec939c190704befe94272d326daffb555b306d226ef849ecfe2f26"
    private let author = "3252715543f6e43be086465129b030d47d76cf8cead4798e48864563c3375083"

    private func nevent(relays: [String]) -> String {
        var tlv = Bech32.encodeTLV(type: 0, data: Data(hex: id))
        for r in relays { tlv += Bech32.encodeTLV(type: 1, data: Data(r.utf8)) }
        tlv += Bech32.encodeTLV(type: 2, data: Data(hex: author))
        return Bech32.encode(hrp: "nevent", data: tlv)!
    }

    private let authorList = [
        "wss://relay.damus.io", "wss://nos.lol", "wss://relay.primal.net", "wss://nostr.wine",
        "wss://relay.snort.social", "wss://nostr.land", "wss://nostr-02.yakihonne.com",
        "wss://relay.nostr.band", "wss://purplepag.es",
    ]

    func testReadsTheNeventHintAndAuthor() {
        let content = "look nostr:\(nevent(relays: ["wss://nostr.mom"]))"
        XCTAssertEqual(QuoteFetchRelays.hints(for: id, in: content), ["wss://nostr.mom"])
        XCTAssertEqual(QuoteFetchRelays.author(for: id, in: content), author)
    }

    func testHintOfAnotherNoteIsNotUsed() {
        let content = "nostr:\(nevent(relays: ["wss://nostr.mom"]))"
        XCTAssertEqual(QuoteFetchRelays.hints(for: String(repeating: "ab", count: 32), in: content), [])
    }

    func testReachesTheSeventhOfNineWriteRelays() {
        let out = QuoteFetchRelays.relays(hints: ["wss://nostr.mom"], authorWrite: authorList,
                                          asked: ["wss://relay.damus.io/", "WSS://nos.lol"])
        XCTAssertEqual(out.first, "wss://nostr.mom")
        XCTAssertTrue(out.contains("wss://nostr-02.yakihonne.com"))
        XCTAssertFalse(out.contains("wss://relay.damus.io"), "already asked")
        XCTAssertFalse(out.contains("wss://nos.lol"), "already asked, other case")
    }

    func testCapsTheAuthorRelaysAtEight() {
        let many = (1...12).map { "wss://r\($0).example.com" }
        let out = QuoteFetchRelays.relays(hints: [], authorWrite: many, asked: [])
        XCTAssertEqual(out, Array(many.prefix(8)))
    }

    func testSkipsLoopbackAndLanHints() {
        let out = QuoteFetchRelays.relays(hints: ["ws://127.0.0.1:3355", "ws://localhost:4869", "ws://192.168.1.5:7777"],
                                          authorWrite: nil, asked: [])
        XCTAssertEqual(out, [])
    }
}

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            bytes.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        self = Data(bytes)
    }
}
