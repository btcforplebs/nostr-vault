import XCTest
@testable import MediaLogic

final class TrustedWebMemoTests: XCTestCase {
    func testMatchesTrustMapWebAndFollowsChanges() {
        let memo = TrustedWebMemo()
        let saved: Set<String> = ["a", "b"]
        XCTAssertEqual(memo.web(saved: saved, follows: ["c"]), TrustMap.web(saved: saved, follows: ["c"]))
        XCTAssertEqual(memo.web(saved: saved, follows: ["c"]), ["a", "b", "c"])
        XCTAssertEqual(memo.web(saved: saved, follows: ["d"]), ["a", "b", "d"])
        XCTAssertEqual(memo.web(saved: saved.union(["e"]), follows: ["d"]), ["a", "b", "d", "e"])
        // No graph yet: fails closed, as TrustMap.web does.
        XCTAssertEqual(memo.web(saved: [], follows: ["d"]), [])
    }
}
