import XCTest
@testable import MediaLogic

/// The kind 10000 mute list beyond its public `p` tags: private people, and
/// muted words, hashtags and threads, public or in the encrypted part.
final class MuteListTests: XCTestCase {
    private let a = String(repeating: "a", count: 64)
    private let b = String(repeating: "b", count: 64)
    private let thread = String(repeating: "1", count: 64)
    private let other = String(repeating: "2", count: 64)

    func testEntriesAreReadLowercasedAndOnce() {
        let list = MuteList(publicTags: [["word", "Crypto Scam"], ["word", "crypto scam"], ["t", "#NSFW"],
                                         ["e", thread], ["e", "nope"], ["word", " "], ["p", a]])
        XCTAssertEqual(list.words, ["crypto scam"])
        XCTAssertEqual(list.hashtags, ["nsfw"])
        XCTAssertEqual(list.threads, [thread])
        XCTAssertEqual(list.privatePubkeys, [], "public p tags are the published blocks, not this list's")
    }

    func testMutedWordHidesNoteCaseInsensitive() {
        let list = MuteList(publicTags: [["word", "airdrop"]])
        XCTAssertTrue(list.hides(id: "x", content: "Free AIRDROP now", tags: []))
        XCTAssertFalse(list.hides(id: "y", content: "a drop of rain", tags: []), "positive control")
    }

    func testMutedHashtagHidesNote() {
        let list = MuteList(publicTags: [["t", "nsfw"]])
        XCTAssertTrue(list.hides(id: "x", content: "", tags: [["t", "NSFW"]]))
        XCTAssertFalse(list.hides(id: "y", content: "nsfw in text only", tags: [["t", "art"]]))
    }

    func testMutedThreadHidesRootRepliesAndReactions() {
        let list = MuteList(publicTags: [["e", thread]])
        XCTAssertTrue(list.hides(id: thread, content: "", tags: []), "the root itself")
        XCTAssertTrue(list.hides(id: "r", content: "", tags: [["e", thread, "", "root"], ["e", other, "", "reply"]]))
        XCTAssertTrue(list.hides(id: "r2", content: "", tags: [], parentId: thread))
        XCTAssertTrue(list.hides(id: "like", content: "+", tags: [["e", thread], ["p", a]]), "a like on it")
        XCTAssertFalse(list.hides(id: "q", content: "", tags: [["e", thread, "", "mention"]]), "a quote is not the thread")
        XCTAssertFalse(list.hides(id: "z", content: "", tags: [["e", other, "", "root"]]))
    }

    func testEmptyListHidesNothing() {
        XCTAssertFalse(MuteList.empty.hides(id: thread, content: "anything", tags: [["t", "nsfw"]]))
    }

    // MARK: - Private part

    private func json(_ tags: [[String]]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: tags), encoding: .utf8)!
    }

    func testNip44PrivatePartAddsPeopleWordsHashtagsThreads() async {
        var used: [String] = []
        let list = await MuteList.read(
            tags: [["p", a], ["word", "loud"]], content: "AgSealedNip44Payload==",
            decrypt44: { ct in used.append("44:\(ct)"); return self.json([["p", self.b.uppercased()], ["word", "Secret"], ["t", "spoilers"], ["e", self.other]]) },
            decrypt04: { _ in used.append("04"); return "[]" })
        XCTAssertEqual(used, ["44:AgSealedNip44Payload=="])
        XCTAssertEqual(list.privatePubkeys, [b])
        XCTAssertEqual(Set(list.words), ["loud", "secret"])
        XCTAssertEqual(list.hashtags, ["spoilers"])
        XCTAssertEqual(list.threads, [other])
        XCTAssertEqual(list.privateNote, "")
    }

    func testNip04PrivatePartIsOpenedWithNip04() async {
        var used: [String] = []
        let list = await MuteList.read(
            tags: [], content: "c2VjcmV0?iv=aXY=",
            decrypt44: { _ in used.append("44"); throw MuteList.PrivateError.notAList },
            decrypt04: { _ in used.append("04"); return self.json([["p", self.a], ["word", "old"]]) })
        XCTAssertEqual(used, ["04"])
        XCTAssertEqual(list.privatePubkeys, [a])
        XCTAssertEqual(list.words, ["old"])
    }

    func testUnreadablePrivatePartKeepsPublicAndSaysWhy() async {
        struct Refused: LocalizedError { var errorDescription: String? { "signer said no" } }
        let list = await MuteList.read(tags: [["word", "loud"]], content: "AgAA",
                                       decrypt44: { _ in throw Refused() }, decrypt04: { _ in "" })
        XCTAssertEqual(list.words, ["loud"])
        XCTAssertEqual(list.privatePubkeys, [])
        XCTAssertEqual(list.privateNote, "signer said no")
        let notList = await MuteList.read(tags: [], content: "AgAA", decrypt44: { _ in "{\"p\":1}" }, decrypt04: { _ in "" })
        XCTAssertFalse(notList.privateNote.isEmpty)
    }

    func testNoContentNeedsNoSigner() async {
        let list = await MuteList.read(tags: [["t", "x"]], content: "  ",
                                       decrypt44: { _ in XCTFail("no decrypt"); return "" },
                                       decrypt04: { _ in XCTFail("no decrypt"); return "" })
        XCTAssertEqual(list.hashtags, ["x"])
        XCTAssertEqual(list.privateNote, "")
    }
}
