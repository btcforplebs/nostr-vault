import XCTest
@testable import MediaLogic

/// The Vault tab's "Vault" list: what others did that reached you.
final class VaultActivityTests: XCTestCase {
    private let me = String(repeating: "a", count: 64)
    private let ann = String(repeating: "b", count: 64)
    private let bob = String(repeating: "c", count: 64)
    private let cat = String(repeating: "d", count: 64)
    private let noteKinds: Set<Int> = [1, 6, 30023, 1111, 9802, 1068]

    private func event(_ id: String, _ pubkey: String, kind: Int = 1, at: Int64,
                       content: String = "", tags: [[String]] = [], images: [URL] = []) -> VaultActivity.Event {
        VaultActivity.Event(id: id, pubkey: pubkey, kind: kind, createdAt: at, content: content, tags: tags, images: images)
    }

    func testPicturesLeaveThePreviewAndRideAlongAsThumbnails() {
        let pic = URL(string: "https://img.example/a.jpg")!
        let pic2 = URL(string: "https://img.example/b.png")!
        let lines = build([
            event("post", me, at: 100, content: "mine \(pic2.absoluteString)", images: [pic2]),
            event("r1", ann, kind: 7, at: 110, content: "+", tags: [["e", "post"], ["p", me]]),
            event("reply", bob, at: 120, content: "look \(pic.absoluteString) https://example.com/page wow",
                  tags: [["e", "post"], ["p", me]], images: [pic]),
        ])
        XCTAssertEqual(lines.count, 2)
        // Their reply: the picture link is gone from the words, the page link stays.
        XCTAssertEqual(lines[0].kind, .reply)
        XCTAssertEqual(lines[0].preview, "look https://example.com/page wow")
        XCTAssertEqual(lines[0].images, [pic])
        // A like of your post carries your post's pictures.
        XCTAssertEqual(lines[1].kind, .reaction)
        XCTAssertEqual(lines[1].preview, "mine")
        XCTAssertEqual(lines[1].images, [pic2])
    }

    private func zapReceipt(_ id: String, from sender: String, on note: String?, sats: Int, at: Int64,
                            comment: String = "") -> VaultActivity.Event {
        var requestTags: [[String]] = [["p", me], ["amount", "\(sats * 1000)"]]
        if let note { requestTags.append(["e", note]) }
        let request: [String: Any] = ["pubkey": sender, "content": comment, "tags": requestTags, "kind": 9734]
        let json = String(data: try! JSONSerialization.data(withJSONObject: request), encoding: .utf8)!
        var tags: [[String]] = [["p", me], ["description", json]]
        if let note { tags.append(["e", note]) }
        return event(id, "lnurlprovider", kind: 9735, at: at, tags: tags)
    }

    private func build(_ events: [VaultActivity.Event],
                       follows: [(pubkey: String, at: Int64)] = [],
                       isBlocked: @escaping (String) -> Bool = { _ in false },
                       isOutside: @escaping (String) -> Bool = { _ in false }) -> [VaultActivity] {
        VaultActivity.build(events: events, owner: me, noteKinds: noteKinds, follows: follows,
                            isBlocked: isBlocked, isOutside: isOutside)
    }

    func testLikesOnOnePostFoldIntoOneLineNewestActorFirst() {
        let lines = build([
            event("post", me, at: 100, content: "my   post\ntext"),
            event("r1", ann, kind: 7, at: 110, content: "+", tags: [["e", "post"], ["p", me]]),
            event("r2", bob, kind: 7, at: 130, content: "🔥", tags: [["e", "post"], ["p", me]]),
            event("r3", ann, kind: 7, at: 120, content: "+", tags: [["e", "post"], ["p", me]]),
        ])
        XCTAssertEqual(lines.count, 1)
        let line = lines[0]
        XCTAssertEqual(line.kind, .reaction)
        XCTAssertEqual(line.actors, [bob, ann])
        XCTAssertEqual(line.createdAt, 130)
        XCTAssertEqual(line.openId, "post")
        XCTAssertEqual(line.preview, "my post text")
        XCTAssertEqual(line.emojis, ["🔥", "+"])
    }

    func testACustomEmojiReactionKeepsItsImageForTheRow() {
        let url = "https://x.example/pepe.png"
        let lines = build([
            event("post", me, at: 100, content: "hi"),
            event("r1", ann, kind: 7, at: 110, content: ":pepe:", tags: [["e", "post"], ["p", me], ["emoji", "pepe", url]]),
            event("r2", bob, kind: 7, at: 120, content: ":untagged:", tags: [["e", "post"]]),
        ])
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].emojis, [":untagged:", ":pepe:"])
        XCTAssertEqual(lines[0].customEmojis, ["pepe": CustomEmoji(shortcode: "pepe", url: url)])
        // The row keeps the shortcode it can draw; text with no image is not kept.
        XCTAssertEqual(CustomEmoji.shownShortcode(":pepe:", known: ["pepe"]), ":pepe:")
        XCTAssertNil(CustomEmoji.shownShortcode(":untagged:", known: ["pepe"]))
        XCTAssertNil(CustomEmoji.shownShortcode("🔥", known: ["pepe"]))
    }

    func testReactionsToSomeoneElsesPostAreNotYours() {
        let lines = build([
            event("theirs", ann, at: 100),
            event("r1", bob, kind: 7, at: 110, tags: [["e", "theirs"], ["p", ann]]),
        ])
        XCTAssertTrue(lines.isEmpty)
    }

    func testRepliesMentionsAndQuotesEachGetALineNewestFirst() {
        let lines = build([
            event("post", me, at: 100, content: "hello"),
            event("reply", ann, at: 110, content: "hi back", tags: [["e", "post"], ["p", me]]),
            event("mention", bob, at: 120, content: "cc nostr:npub", tags: [["p", me]]),
            event("quote", cat, at: 130, content: "look", tags: [["q", "post"], ["p", me]]),
        ])
        XCTAssertEqual(lines.map(\.kind), [.quote, .mention, .reply])
        XCTAssertEqual(lines.map(\.openId), ["quote", "mention", "reply"])
        XCTAssertEqual(lines.last?.preview, "hi back")
    }

    func testOwnEventsBlockedAndOutsideAuthorsAreLeftOut() {
        let lines = build([
            event("post", me, at: 100),
            event("self", me, at: 105, tags: [["p", me]]),
            event("blocked", bob, at: 110, tags: [["p", me]]),
            event("blockedLike", bob, kind: 7, at: 111, tags: [["e", "post"]]),
            event("spam", cat, at: 120, tags: [["p", me]]),
            // Outside your network only hides posts that tag you, as in Notes.
            event("like", cat, kind: 7, at: 130, tags: [["e", "post"]]),
        ], isBlocked: { $0 == self.bob }, isOutside: { $0 == self.cat })
        XCTAssertEqual(lines.map(\.id), ["reaction-post"])
    }

    func testZapsFoldPerPostAndSumWhileCommentsAndProfileZapsStandAlone() {
        let lines = build([
            event("post", me, at: 100, content: "zap me"),
            zapReceipt("z1", from: ann, on: "post", sats: 21, at: 110),
            zapReceipt("z2", from: bob, on: "post", sats: 1000, at: 120),
            zapReceipt("z3", from: cat, on: "post", sats: 5, at: 130, comment: "great post"),
            zapReceipt("z4", from: ann, on: nil, sats: 100, at: 140),
            zapReceipt("mine", from: me, on: "post", sats: 9, at: 150),
        ])
        XCTAssertEqual(lines.map(\.id), ["z4", "z3", "zap-post"])
        XCTAssertNil(lines[0].openId)
        XCTAssertEqual(lines[0].sats, 100)
        XCTAssertEqual(lines[1].preview, "great post")
        XCTAssertEqual(lines[1].openId, "post")
        XCTAssertEqual(lines[2].actors, [bob, ann])
        XCTAssertEqual(lines[2].sats, 1021)
        XCTAssertEqual(lines[2].preview, "zap me")
    }

    func testZapsOnMyPostsLeaveOutBlockedSendersAndKeepTheRest() {
        let zaps = [
            VaultActivity.Zap(sender: ann, target: "p1", sats: 21, at: 110),
            VaultActivity.Zap(sender: bob, target: "p1", sats: 500, at: 130),
            VaultActivity.Zap(sender: bob, target: "p2", sats: 1000, at: 140),
            VaultActivity.Zap(sender: me, target: "p1", sats: 9, at: 150),
            VaultActivity.Zap(sender: cat, target: "elsewhere", sats: 5, at: 160),
        ]
        let shown = VaultActivity.zapsOnPosts(zaps, targets: ["p1", "p2"], owner: me, excludeOwner: true,
                                              isBlocked: { $0 == self.bob })
        // Bob is blocked: his zaps are gone, and p2, which only he zapped, drops off.
        XCTAssertEqual(shown.zappers["p1"]?.map(\.pubkey), [ann])
        XCTAssertNil(shown.zappers["p2"])
        // The newest zap time comes from what is shown, not from Bob's later zap.
        XCTAssertEqual(shown.lastZapAt["p1"], 110)
        XCTAssertNil(shown.lastZapAt["p2"])

        // Unblocked, the same receipts all come back.
        let all = VaultActivity.zapsOnPosts(zaps, targets: ["p1", "p2"], owner: me, excludeOwner: true,
                                            isBlocked: { _ in false })
        XCTAssertEqual(all.zappers["p1"]?.map(\.pubkey), [ann, bob])
        XCTAssertEqual(all.zappers["p2"]?.map(\.amount), [1000])
        XCTAssertEqual(all.lastZapAt["p1"], 130)
    }

    func testAPostsZapRowKeepsYourOwnZapButHidesABlockedZapper() {
        let zaps = [
            VaultActivity.Zap(sender: me, target: "p1", sats: 9, at: 100),
            VaultActivity.Zap(sender: ann, target: "p1", sats: 21, at: 110),
            VaultActivity.Zap(sender: bob, target: "p1", sats: 500, at: 120),
        ]
        let row = VaultActivity.zapsOnPosts(zaps, targets: ["p1"], owner: me, excludeOwner: false,
                                            isBlocked: { $0 == self.bob }).zappers["p1"]
        XCTAssertEqual(row?.map(\.pubkey), [me, ann])
    }

    func testABlockedZapperIsLeftOutOfTheActivityList() {
        let lines = build([
            event("post", me, at: 100, content: "zap me"),
            zapReceipt("z1", from: ann, on: "post", sats: 21, at: 110),
            zapReceipt("z2", from: bob, on: "post", sats: 1000, at: 120),
            zapReceipt("z3", from: bob, on: nil, sats: 50, at: 130, comment: "let me in"),
        ], isBlocked: { $0 == self.bob })
        XCTAssertEqual(lines.map(\.id), ["zap-post"])
        XCTAssertEqual(lines[0].actors, [ann])
        XCTAssertEqual(lines[0].sats, 21)
    }

    func testRepostsOfYourPostFold() {
        let lines = build([
            event("post", me, at: 100, content: "share this"),
            event("rp1", ann, kind: 6, at: 110, tags: [["e", "post"], ["p", me]]),
            event("rp2", bob, kind: 6, at: 120, tags: [["e", "post"], ["p", me]]),
        ])
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].kind, .repost)
        XCTAssertEqual(lines[0].actors, [bob, ann])
    }

    func testArticlesAndHighlightsThatTagYou() {
        let lines = build([
            event("art", ann, kind: 30023, at: 110, content: "long body", tags: [["title", "My Essay"], ["p", me]]),
            event("hl", bob, kind: 9802, at: 120, content: "a quoted line", tags: [["p", me]]),
        ])
        XCTAssertEqual(lines.map(\.kind), [.highlight, .article])
        XCTAssertEqual(lines[1].preview, "My Essay")
    }

    func testFollowsOnOneDayFoldAndInterleaveByTime() {
        let day1 = Int64(1_790_000_000)
        let lines = build([
            event("mention", cat, at: day1 + 50, tags: [["p", me]]),
        ], follows: [(ann, day1), (bob, day1 + 100), (cat, day1 + 3 * 86_400)])
        XCTAssertEqual(lines.map(\.kind), [.follow, .follow, .mention])
        XCTAssertEqual(lines[0].actors, [cat])
        XCTAssertEqual(lines[1].actors, [bob, ann])
        XCTAssertEqual(lines[1].createdAt, day1 + 100)
        XCTAssertNil(lines[1].openId)
    }

    func testNoOwnerNoLines() {
        XCTAssertTrue(VaultActivity.build(events: [event("x", ann, at: 1, tags: [["p", ""]])],
                                          owner: "", noteKinds: noteKinds).isEmpty)
    }
}
