import XCTest
@testable import MediaLogic

/// The one gate (Logen 2026-11-18): web, hop 3, blocks and mutes decided in
/// one place, failing closed.
final class WebGateTests: XCTestCase {
    private let me = String(repeating: "a", count: 64)
    private let alt = String(repeating: "b", count: 64)
    private let friend = String(repeating: "c", count: 64)
    private let fof = String(repeating: "d", count: 64)
    private let fringe = String(repeating: "e", count: 64)
    private let stranger = String(repeating: "f", count: 64)

    private func web(blocked: Set<String> = [], mutes: MuteList = .empty) -> WebGate.Web {
        WebGate.Web(own: [me, alt], whitelist: [], web: [friend, fof], hop3: [fringe],
                    blocked: blocked, mutes: mutes)
    }

    private func judge(_ signer: String, related: [String] = [], content: String = "",
                       reach: WebGate.Reach = .web, always: Set<String> = [],
                       in w: WebGate.Web? = nil) -> WebGate.Verdict {
        WebGate.judge(.init(signer: signer, related: related, content: content), in: w ?? web(),
                      reach: reach, always: always)
    }

    // MARK: - The rule

    func testInsideIsOwnWhitelistAlwaysAndWeb() {
        XCTAssertEqual(judge(me), .inside)
        XCTAssertEqual(judge(alt), .inside, "every account on the device")
        XCTAssertEqual(judge(friend), .inside)
        XCTAssertEqual(judge(stranger, always: [stranger]), .inside, "the note's author on its own thread")
        let listed = WebGate.Web(own: [me], whitelist: [stranger], web: [])
        XCTAssertEqual(judge(stranger, in: listed), .inside)
    }

    func testOutsideByDefault() {
        XCTAssertEqual(judge(stranger), .outside)
        XCTAssertEqual(judge(fringe), .outside, "hop 3 only where the surface reaches it")
    }

    func testHop3OnlyWithThatReach() {
        XCTAssertEqual(judge(fringe, reach: .webAndHop3), .hop3)
        XCTAssertEqual(judge(stranger, reach: .webAndHop3), .outside)
        XCTAssertEqual(judge(friend, reach: .webAndHop3), .inside)
    }

    func testEveryoneLetsStrangersInButNotTheBlocked() {
        XCTAssertEqual(judge(stranger, reach: .everyone), .inside)
        XCTAssertEqual(judge(stranger, reach: .everyone, in: web(blocked: [stranger])), .blocked)
    }

    func testKeysAreCaseInsensitive() {
        XCTAssertEqual(judge(friend.uppercased()), .inside)
        let upper = WebGate.Web(own: [me.uppercased()], web: [friend.uppercased()], blocked: [stranger.uppercased()])
        XCTAssertEqual(judge(friend, in: upper), .inside)
        XCTAssertEqual(judge(me, in: upper), .inside)
        XCTAssertEqual(judge(stranger, in: upper), .blocked)
    }

    // MARK: - Blocks and mutes in the same gate

    func testBlockedBeatsEverything() {
        let w = web(blocked: [friend])
        XCTAssertEqual(judge(friend, in: w), .blocked, "a blocked follow is hidden, not inside")
        XCTAssertEqual(judge(friend, always: [friend], in: w), .blocked)
    }

    func testRelatedPeopleOnlyCountForBlocks() {
        // A friend reposting a blocked person, or replying under them.
        XCTAssertEqual(judge(friend, related: [stranger], in: web(blocked: [stranger])), .blocked)
        // A friend reposting a stranger is the friend's row: inside.
        XCTAssertEqual(judge(friend, related: [stranger]), .inside)
        // A stranger reposting a friend stays outside.
        XCTAssertEqual(judge(stranger, related: [friend]), .outside)
    }

    func testOwnAccountsAreNeverBlockedAsPeople() {
        XCTAssertEqual(judge(me, in: web(blocked: [me])), .inside)
        XCTAssertEqual(judge(friend, related: [me], in: web(blocked: [me])), .inside)
    }

    func testMuteListPeopleAreBlocked() {
        let mutes = MuteList(privateTags: [["p", stranger]])
        let w = web(mutes: mutes)
        XCTAssertEqual(judge(stranger, in: w), .blocked, "private mute-list people count as blocked")
    }

    func testMutedWordsHashtagsAndThreads() {
        let mutes = MuteList(publicTags: [["word", "airdrop"], ["t", "spam"], ["e", String(repeating: "9", count: 64)]])
        let w = web(mutes: mutes)
        XCTAssertEqual(judge(friend, content: "free AIRDROP here", in: w), .blocked)
        XCTAssertEqual(judge(me, content: "airdrop", in: w), .blocked, "word mutes apply to your own notes too")
        let tagged = WebGate.Subject(signer: friend, tags: [["t", "Spam"]])
        XCTAssertEqual(WebGate.judge(tagged, in: w), .blocked)
        let inThread = WebGate.Subject(signer: friend, parentId: String(repeating: "9", count: 64))
        XCTAssertEqual(WebGate.judge(inThread, in: w), .blocked)
        XCTAssertEqual(judge(friend, content: "hello", in: w), .inside)
    }

    func testIsBlockedAlone() {
        XCTAssertTrue(WebGate.isBlocked(.init(signer: stranger), in: web(blocked: [stranger])))
        XCTAssertFalse(WebGate.isBlocked(.init(signer: stranger), in: web()))
    }

    // MARK: - Zaps

    func testZapJudgedOnTheVerifiedRequestSigner() {
        let verified = WebGate.Subject.zap(requestSigner: friend, verified: true, comment: "gm")
        XCTAssertEqual(WebGate.judge(verified, in: web()), .inside)
        let forged = WebGate.Subject.zap(requestSigner: friend, verified: false, comment: "gm")
        XCTAssertEqual(WebGate.judge(forged, in: web()), .outside, "an unverified request names nobody")
        let blocked = WebGate.Subject.zap(requestSigner: stranger, verified: true)
        XCTAssertEqual(WebGate.judge(blocked, in: web(blocked: [stranger])), .blocked)
        XCTAssertEqual(WebGate.judge(.zap(requestSigner: nil, verified: true), in: web()), .outside)
    }

    // MARK: - Layers: fail closed, never pooled

    private func scope(_ known: Bool = true, bar: Int = 2) -> AccountWebScope {
        AccountWebScope(owners: [me], minFollowers: bar, followsKnown: known)
    }

    func testNoGraphIsJustTheFollows() {
        let l = WebGate.layers(saved: [], follows: [friend], links: nil, depth: 3, scope: scope())
        XCTAssertEqual(l.web, [friend, me])
        XCTAssertEqual(l.hop3, [])
    }

    func testUnconfirmedFollowsNeverFallBackToThePool() {
        let pooled: Set<String> = [friend, stranger, fof]
        let l = WebGate.layers(saved: pooled, follows: [friend], links: nil, depth: 3, scope: scope(false))
        XCTAssertEqual(l.web, [friend, me], "AccountWeb.web returns the pooled web here; the gate does not")
        XCTAssertEqual(l.hop3, [])
    }

    func testDepthTwoSavedWebIsHop3() {
        let saved: Set<String> = [me, friend, stranger]
        let l = WebGate.layers(saved: saved, follows: [friend], links: nil, depth: 2, scope: scope())
        XCTAssertEqual(l.web, [friend, me])
        XCTAssertEqual(l.hop3, [stranger], "another account's follow is one hop out, not inside")
    }

    func testDepthThreeWithoutLinksIsTheFollows() {
        let l = WebGate.layers(saved: [friend, stranger], follows: [friend], links: nil, depth: 3, scope: scope())
        XCTAssertEqual(l.web, [friend, me])
        XCTAssertEqual(l.hop3, [stranger])
    }

    func testDepthThreeSplitsByMinFollowers() {
        let f2 = String(repeating: "1", count: 64)
        let links = TrustLinksIndex(follows: [friend, f2].sorted(), links: [
            fof: [0, 1],        // both follows follow them: in the web (bar 2)
            fringe: [0],        // one follow: hop 3
            stranger: [],       // in the file, no follow of mine: neither
        ])
        let l = WebGate.layers(saved: [friend, f2, fof, fringe, stranger], follows: [friend, f2], links: links,
                               depth: 3, scope: scope(bar: 2))
        XCTAssertEqual(l.web, [me, friend, f2, fof])
        XCTAssertEqual(l.hop3, [fringe])
        // Same web as AccountWeb.web where both are defined.
        let scopeKnown = scope(bar: 2)
        XCTAssertEqual(AccountWeb.web(saved: [friend, f2, fof, fringe, stranger], follows: [friend, f2],
                                      links: links, depth: 3, scope: scopeKnown), l.web)
    }

    func testNewAccountWidensLikeTheRelay() {
        // One follow, bar 3: the follow's follows join the web, as AccountWeb does.
        let links = TrustLinksIndex(follows: [friend], links: [fof: [0], fringe: [0]])
        let l = WebGate.layers(saved: [friend, fof, fringe], follows: [friend], links: links, depth: 3,
                               scope: scope(bar: 3))
        XCTAssertEqual(l.web, [me, friend, fof, fringe])
        XCTAssertEqual(l.hop3, [])
    }

    func testWebBuildCarriesBlocksAndMutes() {
        let mutes = MuteList(privateTags: [["p", stranger]])
        let w = WebGate.Web.build(saved: [], follows: [friend], links: nil, depth: 2, scope: scope(),
                                  whitelist: [alt], blocked: [fof], mutes: mutes)
        XCTAssertEqual(w.blocked, [fof, stranger])
        XCTAssertEqual(w.whitelist, [alt])
        XCTAssertEqual(w.own, [me])
    }

    func testHop3NeverOverlapsTheWeb() {
        let w = WebGate.Web(own: [me], web: [friend], hop3: [friend, fringe])
        XCTAssertEqual(w.hop3, [fringe])
    }

    // MARK: - Hop 3 ration

    private struct Row { let author: String; let verdict: WebGate.Verdict; let reply: Bool }

    private func capped(_ rows: [Row]) -> [Row] {
        WebGate.capHop3(rows, verdict: \.verdict, author: \.author, isReply: \.reply)
    }

    func testCapKeepsOrderAndOtherRows() {
        let rows = [Row(author: "w1", verdict: .inside, reply: false),
                    Row(author: "h1", verdict: .hop3, reply: false),
                    Row(author: "x", verdict: .outside, reply: false),
                    Row(author: "w2", verdict: .inside, reply: false)]
        XCTAssertEqual(capped(rows).map(\.author), ["w1", "h1", "x", "w2"])
    }

    func testCapOnePerAuthorAndNoReplies() {
        let rows = [Row(author: "h1", verdict: .hop3, reply: false),
                    Row(author: "H1", verdict: .hop3, reply: false),
                    Row(author: "h2", verdict: .hop3, reply: true),
                    Row(author: "h3", verdict: .hop3, reply: false)]
        XCTAssertEqual(capped(rows).map(\.author), ["h1", "h3"])
    }

    func testCapIsAFifthWithAFloor() {
        let hop3 = (0..<40).map { Row(author: "h\($0)", verdict: .hop3, reply: false) }
        XCTAssertEqual(capped(hop3).count, WebGate.hop3Floor, "a list of only hop 3 still shows the floor")
        let inside = (0..<100).map { Row(author: "w\($0)", verdict: .inside, reply: false) }
        let mixed = capped(inside + hop3)
        XCTAssertEqual(mixed.filter { $0.verdict == .hop3 }.count, 20, "100 others / 5")
        XCTAssertEqual(mixed.filter { $0.verdict == .inside }.count, 100)
    }
}
