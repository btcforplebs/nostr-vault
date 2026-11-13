import XCTest
@testable import MediaLogic

/// Stricter web of trust (Logen 2026-11-13 "go all"): A) the Vault list folds
/// likes and reposts from outside your web into one line, B) Search folds
/// strangers, C) the Everyone banner.
final class WotStricterTests: XCTestCase {
    private let me = String(repeating: "a", count: 64)
    private let friend = String(repeating: "b", count: 64)
    private let s1 = String(repeating: "c", count: 64)
    private let s2 = String(repeating: "d", count: 64)
    private let noteKinds: Set<Int> = [1, 6, 30023, 1111, 9802, 1068]

    private func event(_ id: String, _ pubkey: String, kind: Int = 1, at: Int64,
                       content: String = "", tags: [[String]] = []) -> VaultActivity.Event {
        VaultActivity.Event(id: id, pubkey: pubkey, kind: kind, createdAt: at, content: content, tags: tags)
    }

    private func zap(_ id: String, from sender: String, on note: String, at: Int64) -> VaultActivity.Event {
        let request: [String: Any] = ["pubkey": sender, "content": "", "kind": 9734,
                                      "tags": [["p", me], ["e", note], ["amount", "21000"]]]
        let json = String(data: try! JSONSerialization.data(withJSONObject: request), encoding: .utf8)!
        return event(id, "lnurlprovider", kind: 9735, at: at, tags: [["p", me], ["e", note], ["description", json]])
    }

    private var events: [VaultActivity.Event] {
        [
            event("post", me, at: 100, content: "mine"),
            event("l1", friend, kind: 7, at: 110, content: "+", tags: [["e", "post"], ["p", me]]),
            event("l2", s1, kind: 7, at: 111, content: "+", tags: [["e", "post"], ["p", me]]),
            event("l3", s1, kind: 7, at: 112, content: "🔥", tags: [["e", "post"], ["p", me]]),
            event("r1", s2, kind: 6, at: 113, tags: [["e", "post"], ["p", me]]),
            zap("z1", from: s1, on: "post", at: 114),
            event("reply", s2, at: 115, content: "hi", tags: [["e", "post"], ["p", me]]),
        ]
    }

    private func build(outsideOnly: Bool = false, folds: Bool = true) -> [VaultActivity] {
        VaultActivity.build(events: events, owner: me, noteKinds: noteKinds,
                            follows: [(pubkey: s2, at: 116)],
                            isOutside: { [friend] in $0 != friend },
                            outsideOnly: outsideOnly, foldsOutsideLikes: folds)
    }

    // MARK: A

    func testAllKeepsInsideLikesZapsAndFollowsButFoldsStrangersLikesAndReposts() {
        let all = build()
        let reaction = all.first { $0.kind == .reaction }
        XCTAssertEqual(reaction?.actors, [friend])
        XCTAssertNil(all.first { $0.kind == .repost })
        XCTAssertEqual(all.first { $0.kind == .zap }?.actors, [s1], "a stranger's zap keeps its line")
        XCTAssertEqual(all.first { $0.kind == .follow }?.actors, [s2], "a stranger's follow keeps its line")
        XCTAssertNil(all.first { $0.kind == .reply }, "an outside reply is left out, as before")
    }

    func testOutsideListsStrangersLikesAndRepostsWithTheirPosts() {
        let outside = build(outsideOnly: true)
        XCTAssertEqual(Set(outside.map(\.kind)), [.reaction, .repost, .reply])
        XCTAssertEqual(outside.first { $0.kind == .reaction }?.actors, [s1])
        XCTAssertEqual(outside.first { $0.kind == .reaction }?.emojis, ["🔥", "+"])
        XCTAssertTrue(outside.allSatisfy { ActivityFilter.outside.includes($0.kind) })
    }

    func testTheFoldLineCountsEachPersonOncePerLine() {
        let outside = build(outsideOnly: true)
        XCTAssertEqual(VaultActivity.outsideLikeCount(outside), 2, "s1 liked twice (one person), s2 reposted")
        XCTAssertEqual(VaultActivity.outsideLikeCount(outside, zapsOnly: true), 1, "Zaps Only hides likes")
        XCTAssertEqual(VaultActivity.outsideLabel(2), "2 from outside your web")
    }

    func testWithoutTheFoldNothingChanges() {
        let all = build(folds: false)
        XCTAssertEqual(Set(all.first { $0.kind == .reaction }?.actors ?? []), [friend, s1])
        XCTAssertEqual(all.first { $0.kind == .repost }?.actors, [s2])
        XCTAssertFalse(build(outsideOnly: true, folds: false).contains { $0.kind == .reaction || $0.kind == .repost })
    }

    // MARK: B

    func testSearchKeepsYouFollowsAndWebAndFoldsTheRestInOrder() {
        let web = String(repeating: "e", count: 64)
        let order = [s1, friend, web, me, s2]
        let split = GlobalSearchRanking.splitOutside(order, own: [me], follows: [friend], wot: [web], pubkey: { $0 })
        XCTAssertEqual(split.inside, [friend, web, me])
        XCTAssertEqual(split.outside, [s1, s2])
    }

    func testSearchWithNoWebYetFailsClosedToYouAndYourFollows() {
        let web = String(repeating: "e", count: 64)
        let split = GlobalSearchRanking.splitOutside([web, friend], own: [me], follows: [friend], wot: [], pubkey: { $0 })
        XCTAssertEqual(split.inside, [friend])
        XCTAssertEqual(split.outside, [web])
    }

    // MARK: C

    func testTheEveryoneBannerShowsOnlyOnAGlobalViewWithTheShieldOn() {
        XCTAssertTrue(EveryoneBanner.shows(everyone: true, globalLike: true))
        XCTAssertFalse(EveryoneBanner.shows(everyone: false, globalLike: true))
        XCTAssertFalse(EveryoneBanner.shows(everyone: true, globalLike: false))
        XCTAssertTrue(EveryoneBanner.text.hasPrefix("Everyone is on"))
        XCTAssertEqual(EveryoneBanner.back, "Back to your web")
    }
}
