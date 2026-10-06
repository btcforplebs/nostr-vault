import XCTest
@testable import MediaLogic

final class ReactionGroupingTests: XCTestCase {
    private func rx(_ content: String, _ pubkey: String, _ at: Int64) -> (content: String, pubkey: String, createdAt: Int64) {
        (content: content, pubkey: pubkey, createdAt: at)
    }

    func testMostReactionsFirst() {
        let groups = ReactionGrouping.groups([rx("🔥", "a", 1), rx("+", "b", 2), rx("❤️", "c", 3)])
        XCTAssertEqual(groups.map(\.emoji), ["❤️", "🔥"])
        XCTAssertEqual(groups.map(\.count), [2, 1])
        XCTAssertEqual(groups[0].reactorPubkeys, ["b", "c"])
    }

    func testTieGoesToTheEmojiUsedFirst() {
        let groups = ReactionGrouping.groups([rx("🤙", "a", 30), rx("🔥", "b", 10), rx("⚡", "c", 20)])
        XCTAssertEqual(groups.map(\.emoji), ["🔥", "⚡", "🤙"])
    }

    func testOrderDoesNotDependOnArrivalOrHashOrder() {
        let reactions = (0..<12).map { rx(["🔥", "⚡", "🤙", "😂", "🫂", "👀"][$0 % 6], "p\($0)", Int64(100 - $0 % 6)) }
        let expected = ReactionGrouping.groups(reactions).map(\.emoji)
        for _ in 0..<50 {
            XCTAssertEqual(ReactionGrouping.groups(reactions.shuffled()).map(\.emoji), expected)
        }
    }

    func testSameTimeTieFallsBackToEmojiText() {
        let groups = ReactionGrouping.groups([rx("😂", "a", 5), rx("🔥", "b", 5)])
        XCTAssertEqual(groups.map(\.emoji), ["🔥", "😂"].sorted())
    }

    func testSkipsLongContent() {
        XCTAssertEqual(ReactionGrouping.groups([rx(":custom_emoji:", "a", 1), rx("🔥", "b", 2)]).map(\.emoji), ["🔥"])
    }
}
