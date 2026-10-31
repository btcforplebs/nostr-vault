import XCTest
@testable import MediaLogic

final class EmojiCatalogTests: XCTestCase {
    /// The real bundled file, so the shipped data is what is tested.
    private static let bundled: EmojiCatalog = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("HavenApp/Resources/emoji.tsv")
        return EmojiCatalog(tsv: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }()

    func testTheBundledFileHasEveryGroupAndAllTheEmoji() {
        let catalog = Self.bundled
        XCTAssertEqual(catalog.groups.map(\.name),
                       ["Smileys", "People", "Nature", "Food", "Travel", "Activities", "Objects", "Symbols", "Flags"])
        let all = catalog.groups.flatMap(\.entries)
        XCTAssertGreaterThan(all.count, 1800)
        XCTAssertEqual(Set(all.map(\.emoji)).count, all.count, "each emoji once")
        XCTAssertFalse(all.contains { $0.emoji.unicodeScalars.contains { (0x1F3FB...0x1F3FF).contains($0.value) } },
                       "no skin-tone variants")
        XCTAssertEqual(catalog.names["🤔"], "thinking face")
        XCTAssertTrue(catalog.groups.last!.entries.contains { $0.emoji == "🇺🇸" })
    }

    func testSearchFindsCommonWordsBestFirst() {
        let catalog = Self.bundled
        XCTAssertEqual(catalog.search("thinking").first, "🤔")
        XCTAssertEqual(catalog.search("clap").first, "👏")
        XCTAssertEqual(catalog.search("Thumbs Up").first, "👍")
        XCTAssertTrue(catalog.search("laugh").contains("😂"), "CLDR keyword")
        XCTAssertTrue(catalog.search("rocket").contains("🚀"))
        XCTAssertTrue(catalog.search("   ").isEmpty)
        XCTAssertTrue(catalog.search("zzqqx").isEmpty)
    }

    func testRankingWholeNameThenPrefixThenWordThenKeywordThenContains() {
        let tsv = """
        # comment
        @Smileys & Emotion
        A\tcatapult\t
        B\tblack cat\t
        C\tcat\t
        D\tdog\tcat lover
        E\tbobcatish\t
        """
        let catalog = EmojiCatalog(tsv: tsv)
        XCTAssertEqual(catalog.groups.map(\.name), ["Smileys"])
        XCTAssertEqual(catalog.search("cat"), ["C", "A", "B", "D", "E"])
    }

    func testTypedEmojiIsOfferedButWordsAndDigitsAreNot() {
        XCTAssertEqual(EmojiCatalog.typedEmoji(" 🫡 "), "🫡")
        XCTAssertEqual(EmojiCatalog.typedEmoji("❤️"), "❤️")
        XCTAssertEqual(EmojiCatalog.typedEmoji("👍🏽"), "👍🏽")
        XCTAssertNil(EmojiCatalog.typedEmoji("dog"))
        XCTAssertNil(EmojiCatalog.typedEmoji("1"))
        XCTAssertNil(EmojiCatalog.typedEmoji("🐶 dog"))
    }

    func testResultsPutTypedThenCustomThenUnicodeOnceEach() {
        let catalog = EmojiCatalog(tsv: "@Animals & Nature\n🐸\tfrog\t\n")
        let frog = CustomEmoji(shortcode: "frog_dance", url: "https://x.example/f.png", setAddress: nil)
        let tabs = [EmojiPickerTabs.Tab(name: "Your emoji", symbol: nil, icon: nil, picks: [ReactionPick(frog)])]
        XCTAssertEqual(catalog.results("frog", tabs: tabs, custom: true).map(\.content), [":frog_dance:", "🐸"])
        XCTAssertEqual(catalog.results("frog", tabs: tabs, custom: false).map(\.content), ["🐸"])
        XCTAssertEqual(catalog.results("🐸", tabs: tabs, custom: true).map(\.content), ["🐸"])
        XCTAssertEqual(catalog.tabs.first?.symbol, "leaf")
    }
}
