import XCTest
@testable import MediaLogic

final class TopicFeedFilterTests: XCTestCase {
    private func post(_ id: String, _ pubkey: String, _ content: String, hashtags: Int = 1) -> TopicFeedFilter.Post {
        TopicFeedFilter.Post(id: id, pubkey: pubkey, content: content,
                             tags: (0..<hashtags).map { ["t", "tag\($0)"] })
    }

    /// People follow people; bots and farms don't. Unknown waits.
    func testAuthorsMustFollowTwenty() {
        let posts = [post("a", "person", "street photo"), post("b", "bot", "price tick"), post("c", "unknown", "hi there")]
        XCTAssertEqual(TopicFeedFilter.shown(posts, followCounts: ["person": 120, "bot": 0]), ["a"])
        XCTAssertEqual(TopicFeedFilter.shown(posts, followCounts: ["person": 20, "bot": 19]), ["a"])
        // Content bots follow exactly 10 to look like people.
        XCTAssertEqual(TopicFeedFilter.shown(posts, followCounts: ["person": 10, "bot": 10]), [])
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

    func testAdultPostsAreHidden() {
        let posts = [
            TopicFeedFilter.Post(id: "a", pubkey: "p", content: "say hi", tags: [["t", "NSFW"]]),
            TopicFeedFilter.Post(id: "b", pubkey: "q", content: "beach", tags: [["content-warning", ""]]),
            TopicFeedFilter.Post(id: "c", pubkey: "r", content: "sunset", tags: [["t", "photography"]]),
        ]
        XCTAssertEqual(TopicFeedFilter.shown(posts, followCounts: ["p": 50, "q": 50, "r": 50]), ["c"])
    }

    /// A game posting its player's score is the app talking, not the person.
    func testAppMadePostsAreHidden() {
        let game = TopicFeedFilter.Post(id: "g", pubkey: "p", content: "I just obliterated 197 zombies https://plebsvszombies.cc/x",
                                        tags: [["client", "Plebs vs. Zombies"]])
        let person = TopicFeedFilter.Post(id: "h", pubkey: "q", content: "my essay https://trbouma.substack.com/p/x",
                                          tags: [["client", "Amethyst"]])
        let photo = TopicFeedFilter.Post(id: "i", pubkey: "r", content: "walk https://i.nostr.build/a.jpg",
                                         tags: [["client", "nostr.build"]])
        XCTAssertTrue(TopicFeedFilter.isAppMade(game))
        XCTAssertFalse(TopicFeedFilter.isAppMade(person))
        XCTAssertFalse(TopicFeedFilter.isAppMade(photo), "image links are not sites")
        let damus = TopicFeedFilter.Post(id: "d", pubkey: "s", content: "look https://damus.io/note1abc",
                                         tags: [["client", "Damus"]])
        XCTAssertFalse(TopicFeedFilter.isAppMade(damus), "a person sharing a link from their own app")
        XCTAssertEqual(TopicFeedFilter.shown([game, person, photo], followCounts: ["p": 50, "q": 50, "r": 50]), ["h", "i"])
    }

    /// Posts two or more people responded to lead; the rest follow, in order.
    func testRespondedToGoFirst() {
        let ids = ["new", "liked", "one", "older", "loved"]
        XCTAssertEqual(TopicFeedFilter.ordered(ids, responders: ["liked": 2, "one": 1, "loved": 9]),
                       ["liked", "loved", "new", "one", "older"])
        XCTAssertEqual(TopicFeedFilter.ordered(ids, responders: [:]), ids)
    }

    /// A zap counts as the signer of the zap request inside the receipt,
    /// never an unsigned name the wallet wrote.
    func testZapResponderIsTheSignedSender() {
        let signed = #"{"kind":9734,"pubkey":"bob","tags":[],"sig":"ok"}"#
        let forged = #"{"kind":9734,"pubkey":"mallory","tags":[],"sig":"bad"}"#
        let valid: ([String: Any]) -> Bool = { ($0["sig"] as? String) == "ok" }
        func receipt(_ description: String?, p: String? = nil) -> [String: Any] {
            var tags: [[String]] = [["e", "x"]]
            if let description { tags.append(["description", description]) }
            if let p { tags.append(["P", p]) }
            return ["kind": 9735, "pubkey": "wallet", "tags": tags]
        }
        XCTAssertEqual(TopicFeedFilter.responder(receipt(signed), isValid: valid), "bob")
        XCTAssertEqual(TopicFeedFilter.responder(receipt(signed, p: "bob"), isValid: valid), "bob")
        XCTAssertNil(TopicFeedFilter.responder(receipt(signed, p: "alice"), isValid: valid), "P disagrees")
        XCTAssertNil(TopicFeedFilter.responder(receipt(forged), isValid: valid), "unsigned request")
        XCTAssertNil(TopicFeedFilter.responder(receipt(nil, p: "alice"), isValid: valid), "P alone is unsigned")
        let like: [String: Any] = ["kind": 7, "pubkey": "carol", "tags": [["e", "x"]]]
        XCTAssertEqual(TopicFeedFilter.responder(like, isValid: valid), "carol")
    }

    func testLinkDomains() {
        XCTAssertEqual(TopicFeedFilter.linkDomains("see https://Example.com/a and https://i.nostr.build/x.PNG"), ["example.com"])
    }
}
