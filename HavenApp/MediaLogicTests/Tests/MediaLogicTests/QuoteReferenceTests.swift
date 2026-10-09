import XCTest
@testable import MediaLogic

final class QuoteReferenceTests: XCTestCase {

    // MARK: - Finding references in content

    func testFindsEachKindOfReference() {
        let content = """
        look at nostr:note1abc123 and nostr:nevent1def456 \
        and the article nostr:naddr1ghi789
        """
        XCTAssertEqual(
            QuoteReference.identifiers(in: content),
            ["note1abc123", "nevent1def456", "naddr1ghi789"]
        )
    }

    func testIgnoresProfileReferencesAndBareText() {
        let content = "hey nostr:npub1abc and nostr:nprofile1def, note1notprefixed"
        XCTAssertEqual(QuoteReference.identifiers(in: content), [])
    }

    /// The identifiers address rows in a list, so the same reference twice must
    /// not become two cards with the same SwiftUI id.
    func testRepeatedReferenceIsListedOnce() {
        let content = "nostr:note1abc … and again nostr:note1abc"
        XCTAssertEqual(QuoteReference.identifiers(in: content), ["note1abc"])
    }

    func testOrderIsPreserved() {
        let content = "nostr:nevent1zzz first, nostr:note1aaa second"
        XCTAssertEqual(QuoteReference.identifiers(in: content), ["nevent1zzz", "note1aaa"])
    }

    // MARK: - nevent TLV

    func testEventIDFromNeventPayload() {
        let id = Data((0..<32).map { UInt8($0) })
        var payload = Data([1, 4]) + Data([1, 2, 3, 4])   // type 1 (relay), skipped
        payload += Data([0, 32]) + id                      // type 0 (event id)
        XCTAssertEqual(
            QuoteReference.eventID(fromNeventTLV: payload),
            id.map { String(format: "%02x", $0) }.joined()
        )
    }

    func testEventIDRejectsWrongLengthAndTruncatedPayloads() {
        // Type 0 but only 16 bytes — not an event id.
        XCTAssertNil(QuoteReference.eventID(fromNeventTLV: Data([0, 16]) + Data(repeating: 7, count: 16)))
        // Claims 32 bytes, carries 4.
        XCTAssertNil(QuoteReference.eventID(fromNeventTLV: Data([0, 32]) + Data([1, 2, 3, 4])))
        XCTAssertNil(QuoteReference.eventID(fromNeventTLV: Data()))
    }

    // MARK: - naddr TLV

    func testCoordinateFromNaddrPayload() {
        let pubkey = Data(repeating: 0xab, count: 32)
        var payload = Data([0, 5]) + Data("intro".utf8)                 // d-tag
        payload += Data([2, 32]) + pubkey                                // pubkey
        payload += Data([3, 4]) + Data([0x00, 0x00, 0x75, 0x53])         // kind 30035
        XCTAssertEqual(
            QuoteReference.coordinate(fromNaddrTLV: payload),
            "naddr:30035:\(String(repeating: "ab", count: 32)):intro"
        )
    }

    /// Kind is four big-endian bytes. Reading them the other way round turns
    /// 30023 into 2489745408 and the fetch filter then matches nothing.
    func testKindIsReadBigEndian() {
        let pubkey = Data(repeating: 0x11, count: 32)
        var payload = Data([2, 32]) + pubkey
        payload += Data([3, 4]) + Data([0x00, 0x00, 0x75, 0x47])         // 30023
        let coordinate = QuoteReference.coordinate(fromNaddrTLV: payload)
        XCTAssertEqual(QuoteReference.parseCoordinate(coordinate ?? "")?.kind, 30023)
    }

    func testCoordinateNeedsKindAndPubkey() {
        // d-tag only — names no event.
        XCTAssertNil(QuoteReference.coordinate(fromNaddrTLV: Data([0, 5]) + Data("intro".utf8)))
        // kind but no pubkey.
        XCTAssertNil(QuoteReference.coordinate(fromNaddrTLV: Data([3, 4]) + Data([0, 0, 0x75, 0x47])))
    }

    func testEmptyDTagIsAllowed() {
        var payload = Data([2, 32]) + Data(repeating: 0x22, count: 32)
        payload += Data([3, 4]) + Data([0, 0, 0x75, 0x47])
        let coordinate = QuoteReference.coordinate(fromNaddrTLV: payload)
        XCTAssertEqual(QuoteReference.parseCoordinate(coordinate ?? "")?.dTag, "")
    }

    /// A type-0 entry that is present but carries no bytes is a real empty `d`
    /// tag, not a missing one, so it must still resolve. The distinction matters
    /// because the bad-UTF-8 case below is rejected, and Foundation decodes empty
    /// data to "" rather than nil — the two must not be conflated.
    func testZeroLengthDTagEntryStillResolves() {
        var payload = Data([0, 0])                                       // d-tag, no bytes
        payload += Data([2, 32]) + Data(repeating: 0x22, count: 32)
        payload += Data([3, 4]) + Data([0, 0, 0x75, 0x47])
        let parts = QuoteReference.naddrParts(fromTLV: payload)
        XCTAssertEqual(parts?.dTag, "")
        XCTAssertEqual(parts?.kind, 30023)
    }

    /// The whole reference fails on a `d` tag that is not valid UTF-8.
    ///
    /// Decoding it to nil and falling back to "" named a different, legal
    /// coordinate: the same author's empty-`d` event of the same kind. A `nostr:`
    /// link or a quoted naddr comes from outside the app, so whoever wrote it
    /// chose those bytes — this is how one event got opened under another's name.
    func testBadUTF8DTagIsRejected() {
        var payload = Data([0, 2]) + Data([0xff, 0xfe])                  // d-tag, invalid UTF-8
        payload += Data([2, 32]) + Data(repeating: 0x22, count: 32)
        payload += Data([3, 4]) + Data([0, 0, 0x75, 0x47])
        XCTAssertNil(QuoteReference.naddrParts(fromTLV: payload))
        XCTAssertNil(QuoteReference.coordinate(fromNaddrTLV: payload))
    }

    /// The regression stated as the attack: the crafted payload must not come out
    /// as the coordinate it was being mistaken for.
    func testBadUTF8DTagDoesNotBecomeTheEmptyDTagCoordinate() {
        let pubkey = Data(repeating: 0x22, count: 32)
        let kind = Data([3, 4]) + Data([0, 0, 0x75, 0x47])
        let crafted = Data([0, 2]) + Data([0xff, 0xfe]) + Data([2, 32]) + pubkey + kind
        let emptyDTag = Data([0, 0]) + Data([2, 32]) + pubkey + kind
        XCTAssertNotNil(QuoteReference.coordinate(fromNaddrTLV: emptyDTag))
        XCTAssertNotEqual(
            QuoteReference.coordinate(fromNaddrTLV: crafted),
            QuoteReference.coordinate(fromNaddrTLV: emptyDTag)
        )
    }

    /// Lone continuation bytes, a truncated sequence and an overlong encoding are
    /// all rejected. Swift's UTF-8 decoding is strict about each of them; the test
    /// pins that, because a lossy decode would turn them into U+FFFD and quietly
    /// name an event nobody wrote.
    func testEachKindOfInvalidUTF8IsRejected() {
        let tail = Data([2, 32]) + Data(repeating: 0x33, count: 32)
            + Data([3, 4]) + Data([0, 0, 0x75, 0x47])
        for bytes in [Data([0x80]), Data([0xC3]), Data([0xC0, 0x80]), Data([0xED, 0xA0, 0x80])] {
            let payload = Data([0, UInt8(bytes.count)]) + bytes + tail
            XCTAssertNil(
                QuoteReference.naddrParts(fromTLV: payload),
                "expected \(bytes.map { String(format: "%02x", $0) }.joined()) to be refused"
            )
        }
    }

    /// A `d` tag that begins with a byte-order mark keeps it.
    ///
    /// This is the bad-UTF-8 bug in valid-UTF-8 clothing, and it is why the check
    /// is a byte round trip rather than a decode: `String(data:encoding: .utf8)`
    /// silently drops a leading U+FEFF, so `EF BB BF 78` arrived as `"x"` and a
    /// crafted naddr named the author's real `d = "x"` event. Found by Tim
    /// reviewing #479.
    func testLeadingByteOrderMarkIsKeptInTheDTag() {
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("x".utf8)
        var payload = Data([0, UInt8(bytes.count)]) + bytes
        payload += Data([2, 32]) + Data(repeating: 0x66, count: 32)
        payload += Data([3, 4]) + Data([0, 0, 0x75, 0x47])
        XCTAssertEqual(QuoteReference.naddrParts(fromTLV: payload)?.dTag, "\u{FEFF}x")
    }

    /// Stated as the attack: the BOM payload must not come out as the coordinate
    /// of the plain `d = "x"` event it was being mistaken for.
    func testBOMDTagDoesNotBecomeThePlainDTagCoordinate() {
        let pubkey = Data(repeating: 0x66, count: 32)
        let kind = Data([3, 4]) + Data([0, 0, 0x75, 0x47])
        func payload(_ dTag: Data) -> Data {
            Data([0, UInt8(dTag.count)]) + dTag + Data([2, 32]) + pubkey + kind
        }
        let crafted = payload(Data([0xEF, 0xBB, 0xBF]) + Data("x".utf8))
        let plain = payload(Data("x".utf8))
        XCTAssertNotNil(QuoteReference.coordinate(fromNaddrTLV: plain))
        XCTAssertNotEqual(
            QuoteReference.coordinate(fromNaddrTLV: crafted),
            QuoteReference.coordinate(fromNaddrTLV: plain)
        )
    }

    /// A BOM on its own is a one-scalar `d` tag, not the empty one. Both of the
    /// ways a `d` tag can collapse to "" are covered, so neither can come back.
    func testBOMOnlyDTagIsNotTheEmptyDTag() {
        let pubkey = Data(repeating: 0x66, count: 32)
        let kind = Data([3, 4]) + Data([0, 0, 0x75, 0x47])
        let bom = Data([0, 3]) + Data([0xEF, 0xBB, 0xBF]) + Data([2, 32]) + pubkey + kind
        let empty = Data([0, 0]) + Data([2, 32]) + pubkey + kind
        XCTAssertEqual(QuoteReference.naddrParts(fromTLV: bom)?.dTag, "\u{FEFF}")
        XCTAssertEqual(QuoteReference.naddrParts(fromTLV: empty)?.dTag, "")
        XCTAssertNotEqual(
            QuoteReference.coordinate(fromNaddrTLV: bom),
            QuoteReference.coordinate(fromNaddrTLV: empty)
        )
    }

    /// Valid multi-byte UTF-8 is not collateral damage of the check above.
    func testMultiByteDTagSurvives() {
        let dTag = "träume-🐝"
        let bytes = Data(dTag.utf8)
        var payload = Data([0, UInt8(bytes.count)]) + bytes
        payload += Data([2, 32]) + Data(repeating: 0x44, count: 32)
        payload += Data([3, 4]) + Data([0, 0, 0x75, 0x47])
        XCTAssertEqual(QuoteReference.naddrParts(fromTLV: payload)?.dTag, dTag)
    }

    /// The relay hint is read by nobody on purpose: honouring it would let the
    /// author of a link choose a host for the app to connect to. A payload that
    /// carries one still parses, and the hint never becomes the `d` tag.
    func testRelayHintIsIgnored() {
        let hint = Data("wss://evil.example/x".utf8)
        var payload = Data([1, UInt8(hint.count)]) + hint                // relay hint
        payload += Data([0, 5]) + Data("intro".utf8)
        payload += Data([2, 32]) + Data(repeating: 0x55, count: 32)
        payload += Data([3, 4]) + Data([0, 0, 0x75, 0x47])
        let parts = QuoteReference.naddrParts(fromTLV: payload)
        XCTAssertEqual(parts?.dTag, "intro")
        XCTAssertEqual(parts?.kind, 30023)
    }

    // MARK: - Coordinate round trip

    func testCoordinateRoundTrip() {
        let built = QuoteReference.coordinate(kind: 30023, pubkey: "deadbeef", dTag: "my-post")
        let parsed = QuoteReference.parseCoordinate(built)
        XCTAssertEqual(parsed?.kind, 30023)
        XCTAssertEqual(parsed?.pubkey, "deadbeef")
        XCTAssertEqual(parsed?.dTag, "my-post")
    }

    /// A d-tag may contain colons; splitting on all of them loses the tail.
    func testDTagKeepsItsColons() {
        let built = QuoteReference.coordinate(kind: 30023, pubkey: "deadbeef", dTag: "2026:09:08-notes")
        XCTAssertEqual(QuoteReference.parseCoordinate(built)?.dTag, "2026:09:08-notes")
    }

    func testPlainEventIDIsNotACoordinate() {
        XCTAssertNil(QuoteReference.parseCoordinate(String(repeating: "a", count: 64)))
        XCTAssertNil(QuoteReference.parseCoordinate("naddr:notanumber:pk:d"))
        XCTAssertNil(QuoteReference.parseCoordinate("naddr:30023::d"))
    }
}

// MARK: - Matching an event to a reference

extension QuoteReferenceTests {
    private static let articleTags = [["d", "my-post"], ["title", "My Post"]]

    func testPlainIdMatchesById() {
        XCTAssertTrue(QuoteReference.event(id: "abc", kind: 1, pubkey: "pk", tags: [], matches: "abc"))
        XCTAssertFalse(QuoteReference.event(id: "abc", kind: 1, pubkey: "pk", tags: [], matches: "def"))
    }

    func testCoordinateMatchesKindAuthorAndDTag() {
        let coordinate = QuoteReference.coordinate(kind: 30023, pubkey: "pk", dTag: "my-post")
        XCTAssertTrue(QuoteReference.event(id: "evt", kind: 30023, pubkey: "pk", tags: Self.articleTags, matches: coordinate))
        // Right d-tag, wrong author.
        XCTAssertFalse(QuoteReference.event(id: "evt", kind: 30023, pubkey: "other", tags: Self.articleTags, matches: coordinate))
        // Right author, wrong kind.
        XCTAssertFalse(QuoteReference.event(id: "evt", kind: 30024, pubkey: "pk", tags: Self.articleTags, matches: coordinate))
        // Right author and kind, different article.
        XCTAssertFalse(QuoteReference.event(id: "evt", kind: 30023, pubkey: "pk", tags: [["d", "other-post"]], matches: coordinate))
    }

    /// `d` tags match byte for byte, not by Unicode equivalence.
    ///
    /// Swift's `==` on String is canonical equivalence, so a reference naming
    /// the NFD form used to match an event whose `d` tag is the NFC form. They
    /// are different events: a relay filters tags on exact bytes and would
    /// never have answered the NFD reference with the NFC event. This only
    /// showed up on the local match against events already loaded.
    func testDTagMatchesOnBytesNotUnicodeEquivalence() {
        let nfc = "\u{00E9}sa"        // precomposed é
        let nfd = "e\u{0301}sa"       // e + combining acute
        XCTAssertEqual(nfc, nfd, "precondition: Swift == treats these as equal")
        XCTAssertFalse(Array(nfc.utf8) == Array(nfd.utf8), "precondition: their bytes differ")

        let reference = QuoteReference.coordinate(kind: 30023, pubkey: "pk", dTag: nfd)
        XCTAssertFalse(
            QuoteReference.event(id: "evt", kind: 30023, pubkey: "pk", tags: [["d", nfc]], matches: reference),
            "an NFD reference must not match the NFC event"
        )
        // The same form still matches.
        XCTAssertTrue(
            QuoteReference.event(id: "evt", kind: 30023, pubkey: "pk", tags: [["d", nfd]], matches: reference)
        )
    }

    /// An event id is never matched by a coordinate and vice versa — the id
    /// field of an addressable event is not what a coordinate names.
    func testCoordinateDoesNotMatchOnIdAlone() {
        let coordinate = QuoteReference.coordinate(kind: 30023, pubkey: "pk", dTag: "my-post")
        XCTAssertFalse(QuoteReference.event(id: coordinate, kind: 30023, pubkey: "pk", tags: [], matches: coordinate))
    }

    func testEmptyDTagMatchesAnArticleWithNoDTagValue() {
        let coordinate = QuoteReference.coordinate(kind: 30023, pubkey: "pk", dTag: "")
        XCTAssertTrue(QuoteReference.event(id: "evt", kind: 30023, pubkey: "pk", tags: [["d", ""]], matches: coordinate))
        XCTAssertFalse(QuoteReference.event(id: "evt", kind: 30023, pubkey: "pk", tags: [], matches: coordinate))
    }
}
