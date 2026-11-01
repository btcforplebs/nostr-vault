import XCTest
@testable import MediaLogic

/// A photo's link goes in where it was picked and stays there while the
/// author keeps writing; anything not placed goes at the end on Post.
final class ComposerPlacementTests: XCTestCase {
    private let link = "https://blossom.example/abc.jpg"

    // MARK: - Edits

    func testEditFindsOneTypedCharacter() {
        let e = ComposerPlacement.edit(from: "helo", to: "hello")
        XCTAssertEqual(e.start, 3)
        XCTAssertEqual(e.oldEnd, 3)
        XCTAssertEqual(e.newEnd, 4)
    }

    func testEditCountsUTF16LikeTheTextViews() {
        // An emoji is two UTF-16 units; the offsets must match UITextView's.
        let e = ComposerPlacement.edit(from: "a🙂b", to: "a🙂Xb")
        XCTAssertEqual(e.start, 3)
        XCTAssertEqual(e.newEnd, 4)
    }

    // MARK: - Anchors

    func testTextTypedBeforeTheAnchorPushesItAlong() {
        XCTAssertEqual(ComposerPlacement.shiftAnchor(5, old: "hello world", new: "oh hello world"), 8)
    }

    func testTextTypedAtTheAnchorGoesAfterThePhoto() {
        // Picked at the end, then kept writing: the photo stays where it was picked.
        XCTAssertEqual(ComposerPlacement.shiftAnchor(5, old: "hello", new: "hello there"), 5)
    }

    func testTextTypedAfterTheAnchorLeavesIt() {
        XCTAssertEqual(ComposerPlacement.shiftAnchor(2, old: "hello", new: "hello #nostr"), 2)
    }

    func testAnchorInsideDeletedTextFallsToTheDeletionStart() {
        XCTAssertEqual(ComposerPlacement.shiftAnchor(6, old: "one XYZ three", new: "one three"), 4)
    }

    // MARK: - Caret

    func testCaretFollowsAFilledInMention() {
        // "@al" at the caret becomes "@Alice ": the caret lands after it.
        let old = "hi @al", new = "hi @Alice "
        XCTAssertEqual(ComposerPlacement.followCaret(6, old: old, new: new), new.utf16.count)
    }

    func testCaretBeforeAWrittenInLinkStaysPut() {
        let old = "first\nsecond"
        let new = ComposerPlacement.insert(link, at: old.utf16.count, in: old).text
        XCTAssertEqual(ComposerPlacement.followCaret(2, old: old, new: new), 2)
    }

    func testCaretAtTheAnchorMovesPastTheLink() {
        let old = "caption"
        let out = ComposerPlacement.insert(link, at: 7, in: old)
        XCTAssertEqual(ComposerPlacement.followCaret(7, old: old, new: out.text), out.text.utf16.count)
    }

    // MARK: - Insert and remove

    func testInsertPutsTheLinkOnItsOwnLine() {
        let out = ComposerPlacement.insert(link, at: 5, in: "Look at this #sunset")
        XCTAssertEqual(out.text, "Look\n\(link)\nat this #sunset")
        XCTAssertEqual(out.end, ("Look\n" + link).utf16.count)
    }

    func testInsertAtTheStartOrEndAddsNoBlankLine() {
        XCTAssertEqual(ComposerPlacement.insert(link, at: 0, in: "").text, link)
        XCTAssertEqual(ComposerPlacement.insert(link, at: 0, in: "caption").text, "\(link)\ncaption")
        XCTAssertEqual(ComposerPlacement.insert(link, at: 7, in: "caption").text, "caption\n\(link)")
        XCTAssertEqual(ComposerPlacement.insert(link, at: 8, in: "caption\n").text, "caption\n\(link)")
    }

    func testInsertClampsAnOutOfRangeOffset() {
        XCTAssertEqual(ComposerPlacement.insert(link, at: 99, in: "hi").text, "hi\n\(link)")
    }

    func testRemoveTakesTheLinkAndItsLineBreak() {
        let text = "Look\n\(link)\n#sunset"
        XCTAssertEqual(ComposerPlacement.remove(link, from: text), "Look\n#sunset")
        XCTAssertEqual(ComposerPlacement.remove(link, from: "Look\n\(link)"), "Look")
        XCTAssertEqual(ComposerPlacement.remove(link, from: "no link here"), "no link here")
    }

    // MARK: - Post

    func testPlacedLinksStayAndUnplacedOnesGoAtTheEnd() {
        let other = "https://blossom.example/def.jpg"
        let text = "\(link)\nsunset #nostr"
        XCTAssertEqual(ComposerPlacement.withUnplacedLinks(text, links: [link, other]),
                       "\(link)\nsunset #nostr\n\(other)")
    }

    func testContentOrderFollowsTheText() {
        let a = "https://x/a.jpg", b = "https://x/b.jpg", c = "https://x/c.jpg"
        let content = "\(b)\nhello\n\(a)"
        XCTAssertEqual(ComposerPlacement.contentOrder([a, b, c], link: { $0 }, in: content), [b, a, c])
    }

    /// The whole flow with an anchor: pick at the caret, keep typing before
    /// and after it, then the upload lands at the right spot.
    func testPickTypeThenLandPutsThePhotoWherePicked() {
        var text = "Morning walk"
        var anchor = text.utf16.count                       // picked at the end
        let typed = text + " #sunrise"                       // kept typing after it
        anchor = ComposerPlacement.shiftAnchor(anchor, old: text, new: typed)
        text = typed
        let prefixed = "Lovely. " + text                     // then added a word in front
        anchor = ComposerPlacement.shiftAnchor(anchor, old: text, new: prefixed)
        text = prefixed
        let landed = ComposerPlacement.insert(link, at: anchor, in: text).text
        XCTAssertEqual(landed, "Lovely. Morning walk\n\(link)\n#sunrise")
        XCTAssertFalse(landed.hasSuffix(link), "the link must not drift to the end, after the hashtags")
    }
}
