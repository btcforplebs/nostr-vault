import XCTest
@testable import MediaLogic

final class TopicFeedFilterTests: XCTestCase {
    private func post(_ id: String, _ pubkey: String, _ content: String, hashtags: Int = 1) -> TopicFeedFilter.Post {
        TopicFeedFilter.Post(id: id, pubkey: pubkey, content: content,
                             tags: (0..<hashtags).map { ["t", "tag\($0)"] })
    }

    /// People follow people; bots and farms don't. Unknown waits.
    func testAuthorsMustFollowTen() {
        let posts = [post("a", "person", "street photo"), post("b", "bot", "price tick"), post("c", "unknown", "hi there")]
        XCTAssertEqual(TopicFeedFilter.shown(posts, followCounts: ["person": 120, "bot": 0]), ["a"])
        XCTAssertEqual(TopicFeedFilter.shown(posts, followCounts: ["person": 9, "bot": 0]), [])
    }

    func testHashtagStuffing() {
        let posts = [post("a", "p", "five tags", hashtags: 5), post("b", "q", "six tags", hashtags: 6)]
        XCTAssertEqual(TopicFeedFilter.shown(posts, followCounts: ["p": 50, "q": 50]), ["a"])
    }

    /// A non-media site linked by 4+ accounts is a farm; images aren't.
    func testLinkFarms() {
        var posts = (0..<4).map { post("f\($0)", "farm\($0)", "thank you donors https://api.gifts.example/m/\($0)") }
        posts += (0..<4).map { post("i\($0)", "cam\($0)", "sunset number \($0) https://blossom.example/\($0).jpg") }
        let counts = Dictionary(uniqueKeysWithValues: (posts.map(\.pubkey)).map { ($0, 50) })
        XCTAssertEqual(TopicFeedFilter.shown(posts, followCounts: counts), ["i0", "i1", "i2", "i3"])
    }

    /// The same text once, even when the link in it changes.
    func testCopiesShowOnce() {
        let posts = [post("a", "p", "GM nostr https://x.example/1"), post("b", "q", "gm   NOSTR https://x.example/2")]
        XCTAssertEqual(TopicFeedFilter.shown(posts, followCounts: ["p": 50, "q": 50]), ["a"])
    }

    func testTwoPerPerson() {
        let posts = (0..<5).map { post("\($0)", "busy", "post number \($0)") }
        XCTAssertEqual(TopicFeedFilter.shown(posts, followCounts: ["busy": 300]), ["0", "1"])
    }

    func testLinkDomains() {
        XCTAssertEqual(TopicFeedFilter.linkDomains("see https://Example.com/a and https://i.nostr.build/x.PNG"), ["example.com"])
    }
}
