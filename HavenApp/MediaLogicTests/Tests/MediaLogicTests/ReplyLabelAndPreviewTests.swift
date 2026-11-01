import XCTest
@testable import MediaLogic

/// The "reply to X" line names the parent's author, and condensed previews
/// don't spend their line limit on blank lines.
final class ReplyLabelAndPreviewTests: XCTestCase {
    private let starter = String(repeating: "a", count: 64)
    private let parentAuthor = String(repeating: "b", count: 64)
    private let other = String(repeating: "c", count: 64)

    private func author(_ tags: [[String]], kind: Int = 1) -> String? {
        NIP10Thread.parentAuthor(kind: kind, tags: tags)
    }

    func testDeepReplyReadsThePubkeyOnTheReplyTag() {
        // Our composers: parent author first, then the parent's p tags.
        XCTAssertEqual(author([
            ["e", "root", "", "root", starter], ["e", "parent", "", "reply", parentAuthor],
            ["p", starter], ["p", parentAuthor],
        ]), parentAuthor)
    }

    func testDeepReplyWithoutPubkeysTakesTheLastP() {
        // The parent's p tags (the starter) then the parent's author appended.
        XCTAssertEqual(author([
            ["e", "root", "", "root"], ["e", "parent", "", "reply"], ["p", starter], ["p", parentAuthor],
        ]), parentAuthor)
        // Old positional form.
        XCTAssertEqual(author([["e", "root"], ["e", "parent"], ["p", starter], ["p", parentAuthor]]), parentAuthor)
    }

    func testDirectReplyKeepsTheFirstP() {
        XCTAssertEqual(author([["e", "root", "", "root"], ["p", starter], ["p", other]]), starter)
        XCTAssertEqual(author([["e", "root"], ["p", starter]]), starter)
        XCTAssertEqual(author([["e", "root", "", "root", starter], ["p", other]]), starter)
    }

    func testMentionIsNotTheParent() {
        XCTAssertEqual(author([
            ["e", "root", "", "root"], ["e", "parent", "", "reply", parentAuthor],
            ["e", "quoted", "", "mention", other], ["p", other],
        ]), parentAuthor)
        XCTAssertNil(author([["e", "quoted", "", "mention", other], ["p", other]]))
    }

    func testMalformedPubkeySlotFallsBackToPTags() {
        XCTAssertEqual(author([
            ["e", "root", "", "root"], ["e", "parent", "", "reply", "npub1xyz"], ["p", starter], ["p", parentAuthor],
        ]), parentAuthor)
    }

    func testNotAReplyOrNobodyNamed() {
        XCTAssertNil(author([["p", starter]]))
        XCTAssertNil(author([["e", "root", "", "root"], ["e", "parent", "", "reply"]]))
    }

    func testCommentNamesTheParentComment() {
        XCTAssertEqual(author([
            ["E", "root", "", starter], ["K", "1"], ["P", starter],
            ["e", "c1", "", parentAuthor], ["k", "1111"], ["p", parentAuthor],
        ], kind: 1111), parentAuthor)
    }

    func testSqueezeBlankLines() {
        XCTAssertEqual(CondensedText.squeezeBlankLines("\n\n  \nHello\n\n\n \t\nWorld\r\n\r\nend\n\n"), "Hello\nWorld\nend")
        XCTAssertEqual(CondensedText.squeezeBlankLines("one line"), "one line")
        XCTAssertEqual(CondensedText.squeezeBlankLines("\n \n"), "")
    }

    /// The parent quote over a reply is one line: breaks and runs of spaces
    /// become single spaces, so it never stops at the first line break.
    func testOneLine() {
        XCTAssertEqual(CondensedText.oneLine("First line\n\nsecond  line\r\n\tthird "), "First line second line third")
        XCTAssertEqual(CondensedText.oneLine("  \n "), "")
        XCTAssertEqual(CondensedText.oneLine("gm"), "gm")
    }
}
