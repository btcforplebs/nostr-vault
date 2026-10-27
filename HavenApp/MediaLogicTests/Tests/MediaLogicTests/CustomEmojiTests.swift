import XCTest
@testable import MediaLogic

final class CustomEmojiTests: XCTestCase {
    private let set = "30030:\(String(repeating: "b", count: 64)):frogs"

    func testAnEmojiTagGivesShortcodeImageAndSet() {
        XCTAssertEqual(CustomEmoji.from(tag: ["emoji", "pepe", "https://x.example/p.png", set]),
                       CustomEmoji(shortcode: "pepe", url: "https://x.example/p.png", setAddress: set))
        XCTAssertEqual(CustomEmoji.from(tag: ["emoji", "soap_box-2", "http://x.example/s.gif"]),
                       CustomEmoji(shortcode: "soap_box-2", url: "http://x.example/s.gif"))
    }

    func testBadShortcodesAndAddressesAreRefused() {
        XCTAssertNil(CustomEmoji.from(tag: ["emoji", "pe pe", "https://x.example/p.png"]))
        XCTAssertNil(CustomEmoji.from(tag: ["emoji", "pepe:", "https://x.example/p.png"]))
        XCTAssertNil(CustomEmoji.from(tag: ["emoji", "", "https://x.example/p.png"]))
        XCTAssertNil(CustomEmoji.from(tag: ["emoji", "pépé", "https://x.example/p.png"]))
        XCTAssertNil(CustomEmoji.from(tag: ["emoji", "pepe", "javascript:alert(1)"]))
        XCTAssertNil(CustomEmoji.from(tag: ["emoji", "pepe", "data:image/png;base64,AAAA"]))
        XCTAssertNil(CustomEmoji.from(tag: ["emoji", "pepe", "file:///p.png"]))
        XCTAssertNil(CustomEmoji.from(tag: ["emoji", "pepe", "https://"]))
        XCTAssertNil(CustomEmoji.from(tag: ["emoji", "pepe"]))
        XCTAssertNil(CustomEmoji.from(tag: ["t", "pepe", "https://x.example/p.png"]))
        XCTAssertNil(CustomEmoji.from(tag: ["emoji", "pepe", "https://x.example/p.png", "junk"])?.setAddress)
    }

    func testAShortcodeTaggedTwiceKeepsTheFirstImage() {
        let emojis = CustomEmoji.list(from: [
            ["emoji", "pepe", "https://first.example/p.png"],
            ["emoji", "pepe", "https://second.example/p.png"],
            ["emoji", "cat", "https://x.example/c.png"],
        ])
        XCTAssertEqual(emojis.map(\.shortcode), ["pepe", "cat"])
        XCTAssertEqual(emojis.first?.url, "https://first.example/p.png")
    }

    func testAReactionIsCustomOnlyAsALoneTaggedShortcode() {
        let tags = [["e", "abc"], ["emoji", "pepe", "https://x.example/p.png"]]
        XCTAssertEqual(CustomEmoji.forReaction(content: ":pepe:", tags: tags)?.shortcode, "pepe")
        XCTAssertEqual(CustomEmoji.forReaction(content: " :pepe: ", tags: tags)?.shortcode, "pepe")
        XCTAssertNil(CustomEmoji.forReaction(content: ":cat:", tags: tags))
        XCTAssertNil(CustomEmoji.forReaction(content: "+", tags: tags))
        XCTAssertNil(CustomEmoji.forReaction(content: "🔥", tags: tags))
        XCTAssertNil(CustomEmoji.forReaction(content: "I :pepe:", tags: tags))
    }

    func testTextSplitsAroundShortcodesThatHaveImages() {
        let pepe = CustomEmoji(shortcode: "pepe", url: "https://x.example/p.png")
        let emojis = ["pepe": pepe]
        XCTAssertEqual(CustomEmoji.segments("gm :pepe: and :cat: 12:30", emojis: emojis),
                       [.text("gm "), .emoji(pepe), .text(" and :cat: 12:30")])
        XCTAssertEqual(CustomEmoji.segments(":pepe::pepe:", emojis: emojis), [.emoji(pepe), .emoji(pepe)])
        XCTAssertEqual(CustomEmoji.segments("time 12::pepe: ok", emojis: emojis), [.text("time 12:"), .emoji(pepe), .text(" ok")])
        XCTAssertEqual(CustomEmoji.segments("no tags :pepe:", emojis: [:]), [.text("no tags :pepe:")])
    }

    func testItsTagRoundTrips() {
        let emoji = CustomEmoji(shortcode: "pepe", url: "https://x.example/p.png", setAddress: set)
        XCTAssertEqual(CustomEmoji.from(tag: emoji.tag), emoji)
        XCTAssertEqual(CustomEmoji(shortcode: "pepe", url: "https://x.example/p.png").tag, ["emoji", "pepe", "https://x.example/p.png"])
        XCTAssertEqual(emoji.content, ":pepe:")
    }

    func testACustomReactionCarriesExactlyItsEmojiTag() {
        let tag = ["emoji", "pepe", "https://x.example/p.png", set]
        XCTAssertEqual(CustomEmoji.reactionTags(content: ":pepe:", emojiTag: tag), [tag])
        XCTAssertEqual(CustomEmoji.reactionTags(content: "🔥", emojiTag: tag), [])
        XCTAssertEqual(CustomEmoji.reactionTags(content: ":other:", emojiTag: tag), [])
        XCTAssertEqual(CustomEmoji.reactionTags(content: ":pepe:", emojiTag: nil), [])
        XCTAssertEqual(CustomEmoji.reactionTags(content: ":pepe:", emojiTag: ["emoji", "pepe", "javascript:alert(1)"]), [])
    }

    func testCustomReactionsGroupPerShortcodeAndImage() {
        let a = [["emoji", "pepe", "https://a.example/p.png"]]
        let b = [["emoji", "pepe", "https://b.example/p.png"]]
        let groups = ReactionGrouping.groups(tagged: [
            (content: ":pepe:", pubkey: "1", createdAt: 1, tags: a),
            (content: ":pepe:", pubkey: "2", createdAt: 2, tags: a),
            (content: ":pepe:", pubkey: "3", createdAt: 3, tags: b),
            (content: ":untagged:", pubkey: "4", createdAt: 4, tags: []),
            (content: "❤️", pubkey: "5", createdAt: 5, tags: []),
        ])
        XCTAssertEqual(groups.map(\.emoji), [":pepe:", ":pepe:", "❤️"])
        XCTAssertEqual(groups.map(\.count), [2, 1, 1])
        XCTAssertEqual(groups[0].custom?.url, "https://a.example/p.png")
        XCTAssertEqual(groups[1].custom?.url, "https://b.example/p.png")
        XCTAssertNil(groups[2].custom)
    }
}
