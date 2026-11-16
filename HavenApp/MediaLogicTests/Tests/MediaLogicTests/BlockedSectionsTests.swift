import XCTest
@testable import MediaLogic

/// The Blocked page's Public and Private lists. Android: BlockedSectionsTest.
final class BlockedSectionsTests: XCTestCase {
    func testPublicAndPrivateBlocksGoInTheirOwnLists() {
        let lists = BlockedPeople.sections(publicBlocks: ["npub1alice"], privateBlocks: ["npub1bob"])
        XCTAssertEqual(lists.publicBlocks, ["npub1alice"])
        XCTAssertEqual(lists.privateBlocks, ["npub1bob"])
    }

    /// Anyone can already see a public block, so someone in both shows once, as public.
    func testSomeoneInBothIsShownOnceAsPublic() {
        let lists = BlockedPeople.sections(publicBlocks: ["npub1alice", "npub1bob"],
                                           privateBlocks: ["npub1bob", "npub1carol"])
        XCTAssertEqual(lists.publicBlocks, ["npub1alice", "npub1bob"])
        XCTAssertEqual(lists.privateBlocks, ["npub1carol"])
    }

    func testRepeatsAreDroppedAndOrderKept() {
        let lists = BlockedPeople.sections(publicBlocks: ["npub1bob", "npub1alice", "npub1bob"],
                                           privateBlocks: ["npub1carol", "npub1carol"])
        XCTAssertEqual(lists.publicBlocks, ["npub1bob", "npub1alice"])
        XCTAssertEqual(lists.privateBlocks, ["npub1carol"])
    }

    /// The page matches by hex, so an npub typed in capitals is the same person.
    func testKeyDecidesWhenTwoEntriesAreTheSamePerson() {
        let lists = BlockedPeople.sections(publicBlocks: ["NPUB1ALICE"], privateBlocks: ["npub1alice"])
        XCTAssertEqual(lists.publicBlocks, ["NPUB1ALICE"])
        XCTAssertEqual(lists.privateBlocks, [])
    }

    func testNoBlocksMeansTwoEmptyLists() {
        XCTAssertEqual(BlockedPeople.sections(publicBlocks: [], privateBlocks: []),
                       BlockedPeople.Sections(publicBlocks: [], privateBlocks: []))
    }
}
