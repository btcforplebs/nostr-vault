import XCTest
@testable import MediaLogic

/// A note pasted into the composer, bare or with `nostr:`, posts with the
/// same NIP-18 `q` + `p` the Quote button adds, so its author is told.
final class PastedQuoteTagTests: XCTestCase {
    private let id = String(repeating: "a", count: 64)
    private let otherId = String(repeating: "c", count: 64)
    private let author = String(repeating: "b", count: 64)

    private func hexData(_ hex: String) -> Data {
        Data(stride(from: 0, to: hex.count, by: 2).map {
            UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)...].prefix(2), radix: 16)!
        })
    }
    private func note(_ hex: String) -> String { Bech32.encode(hrp: "note", data: hexData(hex))! }
    private var nevent: String { Bech32.encodeNevent(idHex: id, pubkeyHex: author, kind: 1)! }

    func testBareNoteOnItsOwnLineIsQuoted() {
        // Logen's draft 11-01: text, then a bare note1 on its own line.
        let tags = QuoteReference.noteQuoteTags(in: "look at this\n\(note(id))", relayHint: "wss://r") { _ in self.author }
        XCTAssertEqual(tags, [["q", id, "wss://r", author], ["p", author]])
    }

    func testPrefixedNoteIsQuoted() {
        let tags = QuoteReference.noteQuoteTags(in: "nostr:\(note(id))") { _ in self.author }
        XCTAssertEqual(tags, [["q", id, "", author], ["p", author]])
    }

    func testNeventCarriesItsOwnAuthor() {
        let tags = QuoteReference.noteQuoteTags(in: "see \(nevent)") { _ in nil }
        XCTAssertEqual(tags, [["q", id, "", author], ["p", author]])
    }

    func testUnknownAuthorStillGetsQ() {
        XCTAssertEqual(QuoteReference.noteQuoteTags(in: note(id)), [["q", id, ""]])
    }

    func testRepeatsAndSharedAuthorAreTaggedOnce() {
        let text = "\(note(id)) nostr:\(nevent) \(note(otherId))"
        let tags = QuoteReference.noteQuoteTags(in: text) { _ in self.author }
        XCTAssertEqual(tags, [["q", id, "", author], ["q", otherId, "", author], ["p", author]])
    }

    func testProfilesLinksAndBadChecksumsAreNotQuotes() {
        var broken = note(id)
        broken.removeLast()
        broken += broken.hasSuffix("q") ? "p" : "q"
        let npub = Bech32.encode(hrp: "npub", data: hexData(author))!
        let text = "\(npub) https://njump.me/\(note(id)) \(broken) note1st"
        XCTAssertEqual(QuoteReference.noteQuoteTags(in: text) { _ in self.author }, [])
    }
}
