import XCTest
@testable import MediaLogic

/// NIP-51 lists are replaceable: publishing only this device's entries used to
/// delete what other clients had set (Android twin: `ListMergeTest.kt`).
final class ListMergeTests: XCTestCase {
    func testMuteListKeepsWordHashtagAndThreadMutesAndReplacesPTags() {
        let published = [["p", "aaa"], ["p", "gone"], ["word", "spoiler"], ["t", "nsfw"], ["e", "thread1"]]
        let tags = ListMerge.tags(name: "p", local: ["aaa", "bbb"], published: published) { _ in false }
        XCTAssertEqual(tags, [["p", "aaa"], ["p", "bbb"], ["word", "spoiler"], ["t", "nsfw"], ["e", "thread1"]])
    }

    func testEntryAnotherClientAddedStaysOneRemovedHereGoes() {
        let base: Set<String> = ["wss://removed.example", "wss://kept.example"]
        let published = [["relay", "wss://kept.example"], ["relay", "wss://removed.example"], ["relay", "wss://other-client.example"]]
        let tags = ListMerge.tags(name: "relay", local: ["wss://kept.example"], published: published) { !base.contains(ListMerge.key($0)) }
        XCTAssertEqual(tags, [["relay", "wss://kept.example"], ["relay", "wss://other-client.example"]])
    }

    func testNoBaseKeepsEveryPublishedEntryOnceAfterLocalOnesInOrder() {
        let published = [["server", "https://b.example/"], ["server", "https://c.example"]]
        let tags = ListMerge.tags(name: "server", local: ["https://a.example", "https://B.example"], published: published) { _ in true }
        XCTAssertEqual(tags, [["server", "https://a.example"], ["server", "https://B.example"], ["server", "https://c.example"]])
    }

    func testNothingPublishedPublishesTheLocalList() {
        XCTAssertEqual(ListMerge.tags(name: "p", local: ["x", "X", " "], published: []) { _ in true }, [["p", "x"]])
    }

    func testBasesAreSavedPerListAndSurviveANewInstance() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(ListMerge.basesFileName)
        XCTAssertNil(ListMerge.Bases(file: file).get("10006:abc"))
        ListMerge.Bases(file: file).put("10006:abc", ["wss://a"])
        ListMerge.Bases(file: file).put("10063:abc", ["https://m"])
        XCTAssertEqual(ListMerge.Bases(file: file).get("10006:abc"), ["wss://a"])
        XCTAssertEqual(ListMerge.Bases(file: file).get("10063:abc"), ["https://m"])
    }
}
