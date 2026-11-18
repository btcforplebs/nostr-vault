import XCTest
@testable import MediaLogic

/// Feeds on the one gate (Logen 2026-11-18). A spam reply from a stranger
/// reached the iPhone feed through the notes-tagging-you subscription, which
/// every non-Global feed pulls in, in modes with no author check.
final class FeedGateTests: XCTestCase {
    private let me = String(repeating: "0", count: 64)
    private let follow = String(repeating: "1", count: 64)
    private let webbie = String(repeating: "2", count: 64)
    private let hop = String(repeating: "3", count: 64)
    private let stranger = String(repeating: "4", count: 64)
    private let myPost = String(repeating: "5", count: 64)

    private func gate(blocked: Set<String> = [], mutes: MuteList = .empty) -> WebGate.Web {
        WebGate.Web(own: [me], web: [follow, webbie], hop3: [hop], blocked: blocked, mutes: mutes)
    }

    private func note(_ id: String, by author: String, content: String = "gm", replyTo parent: String? = nil,
                      tags extra: [[String]] = [], kind: Int = 1, repostedBy: String? = nil,
                      at offset: TimeInterval = 0) -> FeedNote {
        var tags = extra
        if let parent { tags.append(["e", parent, "", "reply"]) }
        return FeedNote(id: id, pubkey: author, content: content, createdAt: Date(timeIntervalSince1970: 1_800_000_000 + offset),
                        tags: tags, kind: kind, repostedBy: repostedBy)
    }

    /// The spam that reached Logen's feed: a stranger's reply to his post,
    /// tagging him, with a link and a picture.
    private var spam: FeedNote {
        note("spam", by: stranger, content: "sam.wav airdrop https://example.com/claim.jpg",
             replyTo: myPost, tags: [["p", me]])
    }

    private func run(_ notes: [FeedNote], _ mode: FeedMode, reach: WebGate.Reach = .web,
                     gate g: WebGate.Web? = nil, authorOf: @escaping (String) -> String? = { _ in nil },
                     popularFilter: PopularFilter = .all) -> [String] {
        FeedFilterEngine.filterFeedNotes(notes: notes, mode: mode, gate: g ?? gate(), reach: reach,
                                         showReposts: true, showReplies: true, followedPubkeys: [follow],
                                         ownPubkey: me, popularFilter: popularFilter, popularNoteScores: [:],
                                         authorOf: authorOf).map(\.id)
    }

    // MARK: - The holes

    func testStrangerMentionNeverReachesAnyFeedMode() {
        for mode in FeedMode.allCases where mode != .articles && mode != .polls {
            XCTAssertEqual(run([spam], mode), [], "\(mode) let a stranger's reply in")
            XCTAssertEqual(run([spam], mode, reach: .webAndHop3), [], "\(mode) with hop 3")
        }
    }

    func testMediaFollowingDropsTheStrangersPicture() {
        XCTAssertFalse(spam.mediaURLs.isEmpty, "positive control: the spam carries media")
        let pic = note("pic", by: follow, content: "https://example.com/a.jpg")
        let media = FeedFilterEngine.filterMediaNotes(notes: [spam, pic], gate: gate())
        XCTAssertEqual(media.map(\.id), ["pic"])
    }

    func testMediaGlobalEveryoneStillHidesTheBlocked() {
        let media = FeedFilterEngine.filterMediaNotes(notes: [spam], gate: gate(blocked: [stranger]), reach: .everyone)
        XCTAssertEqual(media, [])
        XCTAssertEqual(FeedFilterEngine.filterMediaNotes(notes: [spam], gate: gate(), reach: .everyone).map(\.id), ["spam"])
    }

    func testFallThroughModesKeepTheWeb() {
        let fromWeb = note("w", by: webbie)
        for mode in [FeedMode.reels, .music, .recipes, .live, .marketplace, .hashtags, .media] {
            XCTAssertEqual(run([fromWeb, spam], mode), ["w"], "\(mode)")
        }
    }

    func testPopularIsTheWebOnly() {
        XCTAssertEqual(run([note("w", by: webbie), note("s", by: stranger)], .popular), ["w"])
    }

    func testCatchUpWithNoFollowsShowsNobody() {
        let g = WebGate.Web(own: [me], web: [])
        let notes = [note("s", by: stranger)]
        XCTAssertEqual(FeedFilterEngine.filterFeedNotes(notes: notes, mode: .catchUp, gate: g, showReposts: true,
                                                        showReplies: true, followedPubkeys: [], ownPubkey: me,
                                                        popularFilter: .all, popularNoteScores: [:]), [])
        XCTAssertEqual(run([note("f", by: follow)], .catchUp), ["f"])
    }

    // MARK: - Reach

    func testUnderratedReachesOneHopOutRationed() {
        let hops = (0..<30).map { note("h\($0)", by: String(repeating: "\($0 % 10)", count: 63) + "a", at: Double($0)) }
        let hopGate = WebGate.Web(own: [me], web: [follow, webbie], hop3: Set(hops.map(\.pubkey)))
        let shown = run(hops + [note("w", by: webbie), note("x", by: stranger)], .underrated,
                        reach: .webAndHop3, gate: hopGate)
        XCTAssertTrue(shown.contains("w"))
        XCTAssertFalse(shown.contains("x"), "outside stays out at any reach")
        XCTAssertEqual(shown.filter { $0.hasPrefix("h") }.count, 10, "one per author, the floor of 10")
        XCTAssertEqual(run([note("h", by: hop)], .underrated), [], "Your web only: no hop 3")
    }

    func testGlobalEveryoneIsReachEveryone() {
        XCTAssertEqual(run([note("s", by: stranger)], .global), [])
        XCTAssertEqual(run([note("s", by: stranger)], .global, reach: .everyone), ["s"])
    }

    func testFeedReachDefaultsAndSetting() {
        XCTAssertEqual(FeedReach.reach(for: .underrated, settings: [:]), .webAndHop3)
        for mode in [FeedMode.discovery, .global, .popular, .media] {
            XCTAssertEqual(FeedReach.reach(for: mode, settings: [:]), .web)
        }
        XCTAssertEqual(FeedReach.reach(for: .following, settings: ["Following": "webAndHop3"]), .web,
                       "Following has no reach setting")
        XCTAssertEqual(FeedReach.reach(for: .global, settings: ["Global": "everyone"]), .web,
                       "Everyone is the shield, never a stored reach")
        let set = FeedReach.setting(.webAndHop3, for: .popular, in: [:])
        XCTAssertEqual(FeedReach.reach(for: .popular, settings: set), .webAndHop3)
        XCTAssertEqual(FeedReach.setting(.webAndHop3, for: .underrated, in: [:]), [:], "the default is stored as absent")
    }

    // MARK: - Blocks and mutes, through the gate

    func testRepostOfABlockedPersonIsHidden() {
        let embedded = note("r", by: stranger, content: "their words", kind: 6, repostedBy: follow)
        XCTAssertEqual(run([embedded], .following, gate: gate(blocked: [stranger])), [])
        let bare = note("b", by: follow, content: "", tags: [["e", "orig"], ["p", stranger]], kind: 6, repostedBy: follow)
        XCTAssertEqual(run([bare], .following, gate: gate(blocked: [stranger])), [])
        XCTAssertEqual(run([bare], .following), ["b"])
    }

    func testReplyUnderABlockedPersonIsHidden() {
        let reply = note("r", by: follow, replyTo: "theirs")
        XCTAssertEqual(run([reply], .following, gate: gate(blocked: [stranger]),
                           authorOf: { $0 == "theirs" ? self.stranger : nil }), [])
    }

    func testMutedWordAndRepostedThread() {
        let orig = String(repeating: "6", count: 64)
        let muted = MuteList(publicTags: [["word", "airdrop"], ["e", orig]])
        XCTAssertEqual(run([note("a", by: follow, content: "AIRDROP now")], .following, gate: gate(mutes: muted)), [])
        let repost = note("r", by: webbie, content: "", tags: [["e", orig]], kind: 6, repostedBy: follow)
        XCTAssertEqual(run([repost], .following), ["r"], "positive control: shown without the mute")
        XCTAssertEqual(run([repost], .following, gate: gate(mutes: muted)), [], "the post a repost shows")
    }
}
