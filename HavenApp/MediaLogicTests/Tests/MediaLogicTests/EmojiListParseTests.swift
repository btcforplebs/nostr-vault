import XCTest
@testable import MediaLogic

final class EmojiListParseTests: XCTestCase {
    private let artist = String(repeating: "c", count: 64)

    func testA10030GivesItsOwnEmojiAndTheSetsItAdds() {
        let parsed = EmojiListParse.list([
            ["emoji", "pepe", "https://x.example/p.png"],
            ["emoji", "bad shortcode", "https://x.example/b.png"],
            ["a", "30030:\(artist):frogs"],
            ["a", "30030:\(artist):frogs"],
            ["a", "30023:\(artist):an-article"],
            ["a", "30030:not-hex:x"],
            ["p", artist],
        ])
        XCTAssertEqual(parsed.single.map(\.shortcode), ["pepe"])
        XCTAssertEqual(parsed.setAddresses, ["30030:\(artist):frogs"])
    }

    func testASetAddressKeepsADWithColons() {
        XCTAssertEqual(EmojiListParse.setRef("30030:\(artist):a:b"), EmojiListParse.SetRef(pubkey: artist, d: "a:b"))
        XCTAssertNil(EmojiListParse.setRef("30030:\(artist)"))
        XCTAssertNil(EmojiListParse.setRef("10030:\(artist):x"))
        XCTAssertNil(EmojiListParse.setRef("30030:\(artist.uppercased()):x"))
    }

    func testASetsEmojiKnowWhichSetTheyCameFrom() {
        let address = "30030:\(artist):frogs"
        let set = EmojiListParse.set(address: address, tags: [["d", "frogs"], ["title", "Frog pack"], ["emoji", "pepe", "https://x.example/p.png"]])
        XCTAssertEqual(set.title, "Frog pack")
        XCTAssertEqual(set.emojis, [CustomEmoji(shortcode: "pepe", url: "https://x.example/p.png", setAddress: address)])
        XCTAssertEqual(EmojiListParse.set(address: address, tags: [["d", "frogs"]]).title, "frogs")
    }

    func testReactingPutsRecentsYourEmojiAndEachSetBeforeTheCategories() {
        let pepe = CustomEmoji(shortcode: "pepe", url: "https://x.example/p.png")
        let frog = CustomEmoji(shortcode: "frog_dance", url: "https://x.example/f.gif", setAddress: "30030:\(artist):frogs")
        let library = EmojiLibrary(owner: "me", single: [pepe],
                                   sets: [EmojiLibrary.EmojiSet(address: frog.setAddress!, title: "Frogs", emojis: [frog])])
        let palette = EmojiPalette.recordUse(EmojiPalette.State(), ReactionPick("😂"))
        let smileys = EmojiPickerTabs.Tab(name: "Smileys", symbol: "face.smiling.fill", icon: nil, picks: [ReactionPick("😀")])
        let tabs = EmojiPickerTabs.build(categories: [smileys], palette: palette, library: library, reacting: true)
        XCTAssertEqual(tabs.map(\.name), ["Recents", "Your emoji", "Frogs", "Smileys"])
        XCTAssertEqual(tabs[2].picks.first?.custom, frog)
        XCTAssertEqual(EmojiPickerTabs.build(categories: [smileys], palette: palette, library: library, reacting: false).map(\.name), ["Smileys"])
        XCTAssertEqual(EmojiPickerTabs.build(categories: [smileys], palette: EmojiPalette.State(), library: EmojiLibrary(), reacting: true).map(\.name), ["Smileys"])
        XCTAssertEqual(EmojiPickerTabs.searchCustom(tabs, query: "FROG").map(\.content), [":frog_dance:"])
        XCTAssertEqual(EmojiPickerTabs.searchCustom(tabs, query: ":pepe:").map(\.content), [":pepe:"])
    }
}
