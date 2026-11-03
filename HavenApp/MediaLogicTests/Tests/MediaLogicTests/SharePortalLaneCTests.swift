import XCTest
@testable import MediaLogic

/// Share portal lane C: who a profile share names, and how Save for later
/// edits the bookmark list. The fixtures are read by Android's shareportal
/// tests too (ProfileShareTargetTest.kt, BookmarkShareTagsTest.kt).
final class SharePortalLaneCTests: XCTestCase {

    private func fixture(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/SharePortal"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func tags(_ any: Any?) -> [[String]]? { any as? [[String]] }

    func testProfileTargetFixtures() throws {
        let cases = try XCTUnwrap(fixture("profile-cases")["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let s = c["source"] as? [String: String] ?? [:]
            XCTAssertEqual(ProfileShareTarget.identifiers(url: s["url"], text: s["text"], selection: s["selection"]),
                           c["identifiers"] as? [String], name)
            XCTAssertEqual(ProfileShareTarget.pubkeys(url: s["url"], text: s["text"], selection: s["selection"]),
                           c["pubkeys"] as? [String], name)
        }
    }

    func testProfileTargetStopsAtTheCap() {
        let one = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
        let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
        let many = (0..<30).map { i in String(one.dropLast(1)) + String(alphabet[i]) }
        XCTAssertEqual(Set(many).count, 30)
        let text = many.joined(separator: " ")
        XCTAssertEqual(ProfileShareTarget.identifiers(url: nil, text: text, selection: nil),
                       Array(many.prefix(ProfileShareTarget.maxIdentifiers)))
    }

    func testShortNpubShowsBothEnds() {
        let npub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
        XCTAssertEqual(ProfileShareTarget.shortNpub(npub), "npub10elfcs4…zvjptg")
        XCTAssertEqual(ProfileShareTarget.shortNpub("npub1short"), "npub1short")
    }

    func testPrivatePartKeepsItsScheme() {
        XCTAssertTrue(BookmarkShareTags.sealsAsNip04(existingContent: "c2VjcmV0?iv=aXY="), "a NIP-04 part stays NIP-04, as the mute path")
        XCTAssertFalse(BookmarkShareTags.sealsAsNip04(existingContent: "AqH2…nip44"), "NIP-44 stays NIP-44")
        XCTAssertFalse(BookmarkShareTags.sealsAsNip04(existingContent: ""), "a new private part is NIP-44")
    }

    func testBookmarkURLFixtures() throws {
        let urls = try XCTUnwrap(fixture("bookmark-cases")["urls"] as? [[String: Any]])
        for u in urls {
            let raw = u["raw"] as? String
            XCTAssertEqual(BookmarkShareTags.url(raw), u["url"] as? String, raw ?? "nil")
        }
    }

    func testBookmarkAddFixtures() throws {
        let cases = try XCTUnwrap(fixture("bookmark-cases")["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 7)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let got = BookmarkShareTags.adding(try XCTUnwrap(c["url"] as? String, name),
                                               publicTags: tags(c["public"]) ?? [], privateTags: tags(c["private"]) ?? [],
                                               privately: c["privately"] as? Bool ?? false)
            let expect = try XCTUnwrap(c["expect"] as? [String: Any], name)
            switch expect["already"] as? String {
            case "public": XCTAssertEqual(got, .alreadyPublic, name)
            case "private": XCTAssertEqual(got, .alreadyPrivate, name)
            default:
                if let pub = tags(expect["public"]) { XCTAssertEqual(got, .publicTags(pub), name) }
                else { XCTAssertEqual(got, .privateTags(try XCTUnwrap(tags(expect["private"]), name)), name) }
            }
        }
    }

    func testBookmarkPrivatePartFixtures() throws {
        let parts = try XCTUnwrap(fixture("bookmark-cases")["private_parts"] as? [[String: Any]])
        for p in parts {
            let name = p["name"] as? String ?? "?"
            XCTAssertEqual(BookmarkShareTags.privateTags(plaintext: try XCTUnwrap(p["plaintext"] as? String)),
                           tags(p["tags"]), name)
        }
        // What it writes, it reads back the same.
        let written: [[String]] = [["r", "https://x.example/a?b=c&d=é"], ["e", "aa"]]
        XCTAssertEqual(BookmarkShareTags.privateTags(plaintext: BookmarkShareTags.json(written)), written)
        XCTAssertFalse(BookmarkShareTags.json(written).contains("\\/"), "slashes as they are, like other apps write them")
    }
}
