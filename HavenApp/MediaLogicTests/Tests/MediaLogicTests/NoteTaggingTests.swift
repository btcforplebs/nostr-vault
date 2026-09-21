import XCTest
@testable import MediaLogic

final class NoteTaggingTests: XCTestCase {

    // MARK: - Hashtags

    func testExtractsHashtagsInOrderWithoutTheHash() {
        XCTAssertEqual(
            NoteTagging.hashtags(in: "gm #nostr and #bitcoin"),
            ["nostr", "bitcoin"]
        )
    }

    func testLowercasesAndDeduplicatesCaseInsensitively() {
        XCTAssertEqual(
            NoteTagging.hashtags(in: "#Bitcoin #bitcoin #BITCOIN"),
            ["bitcoin"]
        )
    }

    func testIgnoresFragmentsInsideURLs() {
        XCTAssertEqual(
            NoteTagging.hashtags(in: "see https://example.com/docs#installation for #help"),
            ["help"]
        )
    }

    func testIgnoresNostrAndRelayReferences() {
        let text = "wss://relay.example/#room nostr:npub1abc#x plain #tag"
        XCTAssertEqual(NoteTagging.hashtags(in: text), ["tag"])
    }

    func testIgnoresAHashThatFollowsAWordCharacter() {
        XCTAssertEqual(NoteTagging.hashtags(in: "I write C# daily"), [])
        XCTAssertEqual(NoteTagging.hashtags(in: "a#b"), [])
    }

    func testRequiresALetterSoDigitOnlyRunsAreNotTags() {
        XCTAssertEqual(NoteTagging.hashtags(in: "we are #1 today"), [])
        XCTAssertEqual(NoteTagging.hashtags(in: "#nostr2"), ["nostr2"])
    }

    func testStripsSurroundingPunctuation() {
        XCTAssertEqual(
            NoteTagging.hashtags(in: "(#nostr), #bitcoin. #freedom!"),
            ["nostr", "bitcoin", "freedom"]
        )
    }

    func testMatchesNonLatinHashtags() {
        XCTAssertEqual(NoteTagging.hashtags(in: "おはよう #日本"), ["日本"])
    }

    func testSkipsRunsLongerThanTheLengthGuard() {
        let long = String(repeating: "a", count: 65)
        XCTAssertEqual(NoteTagging.hashtags(in: "#\(long) #ok"), ["ok"])
    }

    func testBuildsTTags() {
        XCTAssertEqual(
            NoteTagging.hashtagTags(in: "#nostr #bitcoin"),
            [["t", "nostr"], ["t", "bitcoin"]]
        )
    }

    // MARK: - imeta

    func testImetaCarriesEveryKnownFieldInNIP92Order() {
        let media = NoteTagging.MediaDescriptor(
            url: "https://blossom.example/abc.jpg",
            mimeType: "image/jpeg",
            sha256: "deadbeef",
            pixelWidth: 3024,
            pixelHeight: 4032,
            alt: "A cat asleep on a keyboard",
            byteCount: 120_000
        )
        XCTAssertEqual(
            NoteTagging.imetaTag(for: media),
            [
                "imeta",
                "url https://blossom.example/abc.jpg",
                "m image/jpeg",
                "x deadbeef",
                "dim 3024x4032",
                "size 120000",
                "alt A cat asleep on a keyboard",
            ]
        )
    }

    func testImetaOmitsUnknownFieldsRatherThanEmittingThemEmpty() {
        let media = NoteTagging.MediaDescriptor(url: "https://blossom.example/abc.jpg")
        XCTAssertEqual(
            NoteTagging.imetaTag(for: media),
            ["imeta", "url https://blossom.example/abc.jpg"]
        )
    }

    func testImetaOmitsDimWhenOnlyOneAxisIsKnown() {
        var media = NoteTagging.MediaDescriptor(url: "https://blossom.example/abc.jpg")
        media.pixelWidth = 100
        XCTAssertFalse(NoteTagging.imetaTag(for: media)!.contains { $0.hasPrefix("dim ") })
    }

    func testImetaFlattensNewlinesInAlt() {
        var media = NoteTagging.MediaDescriptor(url: "https://blossom.example/abc.jpg")
        media.alt = "line one\nline two"
        XCTAssertEqual(
            NoteTagging.imetaTag(for: media)?.last,
            "alt line one line two"
        )
    }

    func testDescriptorWithoutAURLProducesNoTag() {
        XCTAssertNil(NoteTagging.imetaTag(for: NoteTagging.MediaDescriptor(url: "   ")))
    }
}
