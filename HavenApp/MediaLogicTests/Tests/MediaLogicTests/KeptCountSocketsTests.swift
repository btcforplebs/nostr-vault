import XCTest
@testable import MediaLogic

final class KeptCountSocketsTests: XCTestCase {
    private final class Socket {}
    private let priv = URL(string: "ws://127.0.0.1:3355/private")!
    private let chat = URL(string: "ws://127.0.0.1:3355/chat")!

    func testAKeptSocketIsReusedForTheSameOwnerAndRoute() {
        var kept = KeptCountSockets<Socket>()
        let s = Socket()
        XCTAssertNil(kept.socket(owner: "npubA", url: priv))
        kept.keep(s, owner: "npubA", url: priv)
        XCTAssertTrue(kept.socket(owner: "npubA", url: priv) === s)
        XCTAssertNil(kept.socket(owner: "npubA", url: chat), "each route logs in on its own")
        XCTAssertNil(kept.socket(owner: "npubB", url: priv), "never another owner's login")
        XCTAssertNil(kept.socket(owner: "npubA", url: URL(string: "ws://127.0.0.1:4869/private")!))
    }

    func testKeepingANewerSocketHandsBackTheOldOneToClose() {
        var kept = KeptCountSockets<Socket>()
        let old = Socket(), new = Socket()
        XCTAssertNil(kept.keep(old, owner: "o", url: priv))
        XCTAssertTrue(kept.keep(new, owner: "o", url: priv) === old)
        XCTAssertNil(kept.keep(new, owner: "o", url: priv), "the same socket again closes nothing")
    }

    func testDropOnlyForgetsTheSocketItWasGiven() {
        var kept = KeptCountSockets<Socket>()
        let old = Socket(), new = Socket()
        kept.keep(old, owner: "o", url: priv)
        kept.keep(new, owner: "o", url: priv)
        kept.drop(old, owner: "o", url: priv)
        XCTAssertTrue(kept.socket(owner: "o", url: priv) === new)
        kept.drop(new, owner: "o", url: priv)
        XCTAssertNil(kept.socket(owner: "o", url: priv))
    }

    func testAClosedSocketIsForgottenEverywhere() {
        var kept = KeptCountSockets<Socket>()
        let s = Socket(), other = Socket()
        kept.keep(s, owner: "o", url: priv)
        kept.keep(other, owner: "o", url: chat)
        kept.forget(s)
        XCTAssertNil(kept.socket(owner: "o", url: priv))
        XCTAssertTrue(kept.socket(owner: "o", url: chat) === other)
    }
}
