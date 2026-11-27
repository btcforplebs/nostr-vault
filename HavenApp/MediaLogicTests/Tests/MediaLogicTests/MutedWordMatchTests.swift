import XCTest
@testable import MediaLogic

/// Muted words match whole words only (Logen 2026-11-27). Android:
/// MutedWordMatchTest; web: muted-words.test.mjs.
final class MutedWordMatchTests: XCTestCase {
    func testWholeWordInAnyCaseWithPunctuation() {
        XCTAssertTrue(MutedWordMatch.contains("What an ASS!", word: "ass"))
        XCTAssertTrue(MutedWordMatch.contains("ass", word: "ass"))
        XCTAssertTrue(MutedWordMatch.contains("(ass)", word: "ass"))
    }

    func testPartOfALongerWordDoesNotMatch() {
        XCTAssertFalse(MutedWordMatch.contains("first class", word: "ass"))
        XCTAssertFalse(MutedWordMatch.contains("assets", word: "ass"))
        XCTAssertFalse(MutedWordMatch.contains("Scunthorpe", word: "cunt"))
        XCTAssertFalse(MutedWordMatch.contains("ass2", word: "ass"), "a digit is part of the word")
    }

    func testALaterWholeMatchIsFoundAfterAPartialOne() {
        XCTAssertTrue(MutedWordMatch.contains("class ass", word: "ass"))
    }

    func testUnicodeLettersAreWordCharacters() {
        XCTAssertFalse(MutedWordMatch.contains("éass", word: "ass"))
        XCTAssertTrue(MutedWordMatch.contains("Привет мир", word: "мир"))
        XCTAssertFalse(MutedWordMatch.contains("мирный", word: "мир"))
    }

    func testPhraseMatchesAcrossLineBreaksAndSpaces() {
        XCTAssertTrue(MutedWordMatch.contains("a Big\n  Spoiler here", word: "big spoiler"))
        XCTAssertFalse(MutedWordMatch.contains("big spoilers", word: "big spoiler"))
    }

    func testEdgesThatAreNotLettersNeedNoBoundary() {
        XCTAssertTrue(MutedWordMatch.contains("I love c++code", word: "c++"))
        XCTAssertFalse(MutedWordMatch.contains("abc++", word: "c++"))
    }

    func testMuteListHidesByWholeWordOnly() {
        let list = MuteList(publicTags: [["word", "ass"]])
        XCTAssertTrue(list.hides(id: "x", content: "you ass", tags: []))
        XCTAssertFalse(list.hides(id: "y", content: "first class", tags: []), "the old substring rule hid this")
    }

    private func message(_ text: String, mine: Bool) -> DMMessage {
        DMMessage(id: UUID().uuidString, senderPubkey: mine ? "me" : "them", content: text,
                  timestamp: Date(), isFromMe: mine)
    }

    func testAMutedWordFromTheOtherPersonHidesTheConversation() {
        let list = MuteList(privateTags: [["word", "spoiler"]])
        XCTAssertTrue(list.hidesConversation([message("hi", mine: false), message("Spoiler: he dies", mine: false)]))
        XCTAssertFalse(list.hidesConversation([message("hi", mine: false), message("no spoilers", mine: false)]))
    }

    func testWhatYouSentNeverHidesTheConversation() {
        let list = MuteList(publicTags: [["word", "spoiler"]])
        XCTAssertFalse(list.hidesConversation([message("spoiler alert", mine: true), message("ok", mine: false)]))
        XCTAssertFalse(MuteList.empty.hidesConversation([message("spoiler", mine: false)]))
    }
}
