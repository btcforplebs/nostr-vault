import XCTest
@testable import MediaLogic

/// `nevent1…`, `nprofile1…` and `naddr1…` written without `nostr:` draw the
/// same quote card or mention as the prefixed form, and pasting any of them
/// into search opens what they name.
final class BareReferenceTests: XCTestCase {
    private let id = String(repeating: "a", count: 64)
    private let pubkey = String(repeating: "b", count: 64)

    private func hexData(_ hex: String) -> Data {
        Data(stride(from: 0, to: hex.count, by: 2).map {
            UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)...].prefix(2), radix: 16)!
        })
    }
    private var note: String { Bech32.encode(hrp: "note", data: hexData(id))! }
    private var nevent: String { Bech32.encodeNevent(idHex: id, pubkeyHex: pubkey, kind: 1)! }
    private var npub: String { Bech32.encode(hrp: "npub", data: hexData(pubkey))! }
    private var nprofile: String {
        // pubkey, then a relay hint the app must not need.
        let tlv = Bech32.encodeTLV(type: 0, data: hexData(pubkey)) + Bech32.encodeTLV(type: 1, data: Data("wss://r.example".utf8))
        return Bech32.encode(hrp: "nprofile", data: tlv)!
    }
    private var naddr: String {
        var kind = UInt32(30023).bigEndian
        let tlv = Bech32.encodeTLV(type: 0, data: Data("my-article".utf8))
            + Bech32.encodeTLV(type: 2, data: hexData(pubkey))
            + Bech32.encodeTLV(type: 3, data: Data(bytes: &kind, count: 4))
        return Bech32.encode(hrp: "naddr", data: tlv)!
    }

    // MARK: Content split

    func testBareReferencesGetThePrefix() {
        XCTAssertEqual(QuoteReference.prefixBare("look \(nevent) here"), "look nostr:\(nevent) here")
        XCTAssertEqual(QuoteReference.prefixBare("by \(nprofile)."), "by nostr:\(nprofile).")
        XCTAssertEqual(QuoteReference.prefixBare("\(naddr)"), "nostr:\(naddr)")
        XCTAssertEqual(QuoteReference.prefixBare("\(note)\n"), "nostr:\(note)\n")
    }

    func testAtBeforeABareProfileIsDropped() {
        XCTAssertEqual(QuoteReference.prefixBare("hi @\(npub)!"), "hi nostr:\(npub)!")
    }

    func testPrefixedReferencesAreLeftAlone() {
        let text = "nostr:\(nevent) and nostr:\(nprofile)"
        XCTAssertEqual(QuoteReference.prefixBare(text), text)
    }

    func testReferenceInsideAURLStaysInTheURL() {
        let text = "https://njump.me/\(nevent) and https://x.com/?p=\(npub)"
        XCTAssertEqual(QuoteReference.prefixBare(text), text)
    }

    func testWordsThatOnlyLookLikeReferencesStayText() {
        XCTAssertEqual(QuoteReference.prefixBare("note1st thing, npub1abc"), "note1st thing, npub1abc")
        // A real-looking one with a broken checksum.
        let broken = String(nevent.dropLast()) + (nevent.last == "q" ? "p" : "q")
        XCTAssertEqual(QuoteReference.prefixBare(broken), broken)
    }

    func testNsecIsNeverTouched() {
        let nsec = Bech32.encode(hrp: "nsec", data: hexData(id))!
        XCTAssertEqual(QuoteReference.prefixBare("oops \(nsec)"), "oops \(nsec)")
        XCTAssertNil(QuoteReference.target(ofBech32: nsec))
    }

    func testBareQuotesAreFoundAlongsidePrefixedOnes() {
        let ids = QuoteReference.identifiers(in: "a \(nevent) b nostr:\(note) c \(naddr)")
        XCTAssertEqual(ids, [nevent, note, naddr])
    }

    // MARK: Search parse

    func testPastedReferencesOpenWhatTheyName() {
        let coordinate = QuoteReference.coordinate(kind: 30023, pubkey: pubkey, dTag: "my-article")
        let cases: [(String, QuoteReference.Target)] = [
            (note, .note(id)),
            (nevent, .note(id)),
            ("nostr:\(nevent)", .note(id)),
            ("  \(nevent)\n", .note(id)),
            (naddr, .address(coordinate)),
            ("nostr:\(naddr)", .address(coordinate)),
            (npub, .profile(pubkey)),
            ("@\(npub)", .profile(pubkey)),
            (nprofile, .profile(pubkey)),
            ("nostr:\(nprofile)", .profile(pubkey)),
            (nprofile.uppercased(), .profile(pubkey)),
        ]
        for (pasted, expected) in cases {
            let target = NostrURI(pasted: pasted).flatMap { QuoteReference.target(of: $0) }
            XCTAssertEqual(target, expected, pasted)
        }
    }

    func testOrdinarySearchesAreNotReferences() {
        for query in ["jack", "notebook", "note1st", "#bitcoin", "https://example.com", "nevent1zzzz", ""] {
            let target = NostrURI(pasted: query).flatMap { QuoteReference.target(of: $0) }
            XCTAssertNil(target, query)
        }
    }
}
