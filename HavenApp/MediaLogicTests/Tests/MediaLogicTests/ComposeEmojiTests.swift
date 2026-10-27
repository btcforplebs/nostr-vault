import XCTest
@testable import MediaLogic

final class ComposeEmojiTests: XCTestCase {
    private let pepe = CustomEmoji(shortcode: "pepe", url: "https://x.example/pepe.png")
    private let pepeSleep = CustomEmoji(shortcode: "pepesleep", url: "https://x.example/sleep.gif")
    private let sleepy = CustomEmoji(shortcode: "sleepy_pepe", url: "https://x.example/sleepy.png")

    func testAColonStartingAWordWithTwoLettersIsAQuery() {
        XCTAssertEqual(ComposeEmoji.query(in: "gm :pep", caret: 7), .init(start: 3, end: 7, text: "pep"))
        XCTAssertEqual(ComposeEmoji.query(in: ":pe", caret: 3), .init(start: 0, end: 3, text: "pe"))
        XCTAssertEqual(ComposeEmoji.query(in: ":pep and more", caret: 4), .init(start: 0, end: 4, text: "pep"))
        // Character offsets: an emoji before it counts once.
        XCTAssertEqual(ComposeEmoji.query(in: "🔥 :pe", caret: 5), .init(start: 2, end: 5, text: "pe"))
    }

    func testTimesLinksShortNamesAndFinishedShortcodesAreNotQueries() {
        XCTAssertNil(ComposeEmoji.query(in: "at 12:30", caret: 8))
        XCTAssertNil(ComposeEmoji.query(in: "https://x", caret: 9))
        XCTAssertNil(ComposeEmoji.query(in: "hi :p", caret: 5))
        XCTAssertNil(ComposeEmoji.query(in: "hi :", caret: 4))
        XCTAssertNil(ComposeEmoji.query(in: "hi :pepe: ", caret: 10))
        XCTAssertNil(ComposeEmoji.query(in: "hi :pe pe", caret: 9))
    }

    func testSuggestionsPutPrefixMatchesFirstOnceEachCapped() {
        let known = [sleepy, pepe, pepeSleep, pepe]
        XCTAssertEqual(ComposeEmoji.suggestions("PEP", known: known), [pepe, pepeSleep, sleepy])
        XCTAssertEqual(ComposeEmoji.suggestions("sle", known: known), [sleepy, pepeSleep])
        let many = (1...20).map { CustomEmoji(shortcode: "e1x\($0)", url: "https://x.example/\($0).png") }
        XCTAssertEqual(ComposeEmoji.suggestions("e1", known: many).count, ComposeEmoji.maxSuggestions)
    }

    func testPickingASuggestionReplacesTheQuery() {
        let q = ComposeEmoji.query(in: "gm :pep friends", caret: 7)!
        let out = ComposeEmoji.insert(pepe, replacing: q, in: "gm :pep friends")
        XCTAssertEqual(out.text, "gm :pepe:  friends")
        XCTAssertEqual(out.caret, 10)
    }

    func testTheEmojiButtonInsertsAtTheCaret() {
        XCTAssertEqual(ComposeEmoji.insert(":pepe:", at: 2, in: "gm").text, "gm :pepe: ")
        XCTAssertEqual(ComposeEmoji.insert("🔥", at: 3, in: "gm x").text, "gm 🔥x")
        XCTAssertEqual(ComposeEmoji.insert(":pepe:", at: 0, in: "hi").text, ":pepe: hi")
        XCTAssertEqual(ComposeEmoji.insert(":pepe:", at: 0, in: "hi").caret, 7)
    }

    func testAPostTagsEachCustomEmojiItUsesOnceAndNothingElse() {
        let known = ["pepe": pepe, "pepesleep": pepeSleep]
        XCTAssertEqual(ComposeEmoji.tags(for: "gm :pepe: :pepesleep: :pepe: at 12:30 :unknown:", known: known),
                       [pepe.tag, pepeSleep.tag])
        XCTAssertEqual(ComposeEmoji.tags(for: "no emoji here", known: known), [])
    }
}
