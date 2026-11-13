import XCTest
@testable import MediaLogic

/// Custom emoji v1 (RESEARCH/NV_CUSTOM_EMOJI_PLAN.md §4): the shared emoji
/// note fixture every platform reads the same way, the Media hide rule, and
/// the Emoji page's save/dead/zip/10030 rules.
final class EmojiVaultTests: XCTestCase {
    private let cats = "30030:" + String(repeating: "b", count: 64) + ":cats"
    private let birds = "30030:" + String(repeating: "b", count: 64) + ":birds"
    private let owner = String(repeating: "a", count: 64)
    private let h1 = String(repeating: "1", count: 64)

    // MARK: Shared fixture (docs/fixtures/emoji-notes, same on Android + web)

    private var fixtureDir: URL {
        // Tests/MediaLogicTests/<this file> -> repo root
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/fixtures/emoji-notes")
    }

    private func events(_ name: String) throws -> [[String: Any]] {
        let data = try Data(contentsOf: fixtureDir.appendingPathComponent(name))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    func testEverySharedFixtureReadsAsExpected() throws {
        let data = try Data(contentsOf: fixtureDir.appendingPathComponent("expected.json"))
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        XCTAssertEqual(expected.count, 4)
        for (file, want) in expected {
            var state = FileNotesState(owner: owner)
            for event in try events(file) { _ = state.apply(event) }
            let copies = state.emojiCopies
            XCTAssertEqual(state.notes.values.filter { $0.emoji != nil }.count, want["emojiNotes"] as? Int, file)
            XCTAssertEqual(state.emojiOnlyHashes, Set(want["hiddenFromMedia"] as? [String] ?? []), file)
            for (sha, codes) in want["codes"] as? [String: [[String]]] ?? [:] {
                XCTAssertEqual(copies[sha]?.note.emoji.map { [$0.shortcode, $0.url] }, codes, "\(file) codes")
            }
            for (sha, sets) in want["sets"] as? [String: [String]] ?? [:] {
                XCTAssertEqual(copies[sha]?.note.sets, sets, "\(file) sets")
            }
            // The Media grid follows the same rule.
            let hidden = Set(want["hiddenFromMedia"] as? [String] ?? [])
            XCTAssertTrue(state.tiles.allSatisfy { !hidden.contains($0.sha256) }, file)
        }
    }

    func testPhotoAndEmojiSameHashStaysInMedia() throws {
        var state = FileNotesState(owner: owner)
        for event in try events("photo-and-emoji.json") { _ = state.apply(event) }
        XCTAssertTrue(state.tiles.contains { $0.sha256 == h1 })
        XCTAssertNotNil(state.emojiCopies[h1])
    }

    // MARK: Writing a note

    func testNoteTagsRoundTripThroughTheReader() throws {
        let emoji = [CustomEmoji(shortcode: "party", url: "https://a.example.com/party.gif", setAddress: cats),
                     CustomEmoji(shortcode: "party_parrot", url: "https://b.example.com/p.gif", setAddress: birds),
                     CustomEmoji(shortcode: "bad code", url: "https://a.example.com/x.gif", setAddress: cats)]
        let extra = EmojiNote.tags(for: emoji)
        let tags = try XCTUnwrap(FileNote.tags(sha256: h1, mime: "image/gif", size: 10, owner: owner, servers: [], extra: extra))
        XCTAssertEqual(tags.filter { $0.first == "t" }, [["t", "nv-emoji"]])
        let event: [String: Any] = ["id": "e9", "pubkey": owner, "created_at": 1, "kind": 1063, "tags": tags, "content": ""]
        let read = try XCTUnwrap(FileNote.parse(event)?.emoji)
        XCTAssertEqual(read.emoji.map(\.shortcode), ["party", "party_parrot"])
        XCTAssertEqual(read.sets, [cats, birds])
    }

    func testExtraTagsCannotOverrideTheRequiredOnes() throws {
        let tags = try XCTUnwrap(FileNote.tags(sha256: h1, mime: "image/png", size: 10, owner: owner, servers: [],
                                               extra: [["x", String(repeating: "f", count: 64)], ["p", owner], ["t", "nv-emoji"]]))
        XCTAssertEqual(tags.filter { $0.first == "x" }, [["x", h1]])
        XCTAssertEqual(tags.filter { $0.first == "p" }.count, 1)
    }

    // MARK: Page

    private func set(_ address: String, _ emoji: [(String, String)]) -> EmojiLibrary.EmojiSet {
        EmojiLibrary.EmojiSet(address: address, title: "t",
                              emojis: emoji.map { CustomEmoji(shortcode: $0.0, url: $0.1, setAddress: address) })
    }

    private func copy(_ sha: String, _ emoji: [(String, String)]) -> EmojiCopy {
        EmojiCopy(sha256: sha, mime: "image/png", size: 1,
                  note: EmojiNote(emoji: emoji.map { CustomEmoji(shortcode: $0.0, url: $0.1) }, sets: [cats]))
    }

    func testPageStatusSavedDeadAndNotSaved() {
        let sets = [set(cats, [("a", "https://x.com/a.png"), ("b", "https://x.com/b.png"),
                               ("c", "https://x.com/\(h1).png"), ("d", "https://x.com/d.png")])]
        let copies = [h1: copy(h1, [("a", "https://x.com/a.png")])]
        let pages = EmojiVaultLogic.pages(sets: sets, copies: copies, dead: ["https://x.com/b.png"])
        XCTAssertEqual(pages[0].rows.map(\.status), [.saved(sha256: h1), .dead, .saved(sha256: h1), .notSaved])
        XCTAssertEqual(pages[0].saved, 2)
        XCTAssertEqual(EmojiVaultLogic.deadLinks(pages).map(\.emoji.shortcode), ["b"])
    }

    func testJobsOncePerLinkSkippingSavedAndNamingEverySetUser() {
        let shared = "https://x.com/shared.png"
        let sets = [set(cats, [("a", shared), ("b", "https://x.com/b.png")]),
                    set(birds, [("a2", shared), ("c", "https://x.com/\(h1).png")])]
        let jobs = EmojiVaultLogic.jobs(sets: sets, copies: [h1: copy(h1, [])])
        XCTAssertEqual(jobs.map(\.url), [shared, "https://x.com/b.png"])
        XCTAssertEqual(jobs[0].emoji.map(\.shortcode), ["a", "a2"])
        XCTAssertEqual(jobs[0].emoji.map(\.setAddress), [cats, birds])
    }

    func testCapsAndTypes() {
        XCTAssertTrue(EmojiVaultLogic.isAllowedImage(mime: "image/PNG"))
        XCTAssertTrue(EmojiVaultLogic.isAllowedImage(mime: "image/webp; charset=binary"))
        XCTAssertFalse(EmojiVaultLogic.isAllowedImage(mime: "image/svg+xml"))
        XCTAssertFalse(EmojiVaultLogic.isAllowedImage(mime: "video/mp4"))
        XCTAssertEqual(EmojiVaultLogic.maxImageBytes, 2 * 1024 * 1024)
        XCTAssertEqual(EmojiVaultLogic.Tally(saved: 203, dead: 9, tooBig: 4).summary, "Saved 203 · 9 dead · 4 too big")
    }

    // MARK: Dead links

    func testHashInURL() {
        XCTAssertEqual(EmojiVaultLogic.hashInURL("https://x.com/\(h1).png"), h1)
        XCTAssertEqual(EmojiVaultLogic.hashInURL("https://x.com/\(h1.uppercased())"), h1)
        XCTAssertNil(EmojiVaultLogic.hashInURL("https://x.com/cat.png"))
        XCTAssertNil(EmojiVaultLogic.hashInURL("https://x.com/\(h1)00.png"))
    }

    func testOtherServersSkipTheDeadHostFipsAndPlainHTTP() {
        let urls = EmojiVaultLogic.otherServerURLs(for: "https://blossom.primal.net/\(h1).png",
                                                   own: ["https://mine.example/", "http://insecure.example", "https://vault.fips", "https://MINE.example"])
        XCTAssertEqual(urls.first?.absoluteString, "https://mine.example/\(h1)")
        XCTAssertFalse(urls.contains { $0.host == "blossom.primal.net" })
        XCTAssertFalse(urls.contains { $0.host == "insecure.example" || $0.host == "vault.fips" })
        XCTAssertEqual(urls.filter { $0.host == "mine.example" }.count, 1)
        XCTAssertEqual(EmojiVaultLogic.otherServerURLs(for: "https://x.com/cat.png", own: ["https://mine.example"]), [])
    }

    // MARK: Zip import

    func testZipMatchesByShortcodeOrHashAndListsTheRest() {
        let sets = [set(cats, [("blobcat", "https://x.com/a.png"), ("hashed", "https://x.com/\(h1).png")])]
        let other = String(repeating: "2", count: 64)
        let files = [EmojiVaultLogic.ZipFile(name: "blobcat.png", sha256: other),
                     EmojiVaultLogic.ZipFile(name: "whatever.gif", sha256: h1),
                     EmojiVaultLogic.ZipFile(name: "loose.png", sha256: String(repeating: "3", count: 64)),
                     EmojiVaultLogic.ZipFile(name: "BLOBCAT.png", sha256: other)]
        let result = EmojiVaultLogic.matchZip(files, sets: sets, copies: [:])
        XCTAssertEqual(result.matched.map(\.file.name), ["blobcat.png", "whatever.gif"])
        XCTAssertEqual(result.matched[0].emoji.map(\.setAddress), [cats])
        XCTAssertEqual(result.matched[1].emoji.map(\.shortcode), ["hashed"])
        XCTAssertEqual(result.unmatched, ["loose.png", "BLOBCAT.png"])
    }

    // MARK: 10030

    func testListEditKeepsEveryOtherTagAndIsExact() {
        let base = [["emoji", "loose", "https://x.com/l.png"], ["a", cats], ["client", "x"]]
        let added = EmojiVaultLogic.listTags(base: base, add: birds)
        XCTAssertEqual(added, base + [["a", birds]])
        XCTAssertEqual(EmojiVaultLogic.listTags(base: added, add: birds), added)
        let removed = EmojiVaultLogic.listTags(base: added, remove: cats)
        XCTAssertEqual(removed, [["emoji", "loose", "https://x.com/l.png"], ["client", "x"], ["a", birds]])
        let catsUpper = "30030:" + String(repeating: "b", count: 64) + ":Cats"
        XCTAssertEqual(EmojiVaultLogic.listTags(base: base, remove: catsUpper), base)
    }

    func testPastedSetAddress() throws {
        XCTAssertEqual(EmojiVaultLogic.setAddress(fromPaste: "  \(cats)\n"), cats)
        XCTAssertNil(EmojiVaultLogic.setAddress(fromPaste: "30023:" + String(repeating: "b", count: 64) + ":x"))
        XCTAssertNil(EmojiVaultLogic.setAddress(fromPaste: "hello"))
        // naddr for kind 30030, pubkey bb…, d "cats"
        var tlv = Data([0, 4]) + Data("cats".utf8)
        tlv += Data([2, 32]) + Data(repeating: 0xbb, count: 32)
        tlv += Data([3, 4, 0, 0, 0x75, 0x4e])
        let naddr = try XCTUnwrap(Bech32.encode(hrp: "naddr", data: tlv))
        XCTAssertEqual(EmojiVaultLogic.setAddress(fromPaste: "nostr:" + naddr), cats)
    }
}
