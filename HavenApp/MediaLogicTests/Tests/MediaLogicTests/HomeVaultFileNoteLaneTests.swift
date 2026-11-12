import XCTest
@testable import MediaLogic

/// The fileNote lane of the home-vault queue (plan gap 1): one item per
/// blob, signed at send time, old queues still read.
final class HomeVaultFileNoteLaneTests: XCTestCase {
    private let sha = String(repeating: "ab", count: 32)
    private let owner = String(repeating: "11", count: 32)

    private func item(_ action: FileNoteDraft.Action, sha: String? = nil) -> HomeVaultItem {
        HomeVaultLogic.fileNoteItem(FileNoteDraft(action: action, sha256: sha ?? self.sha, mime: "image/jpeg", size: 7,
                                                  servers: ["https://nostr.build"]),
                                    owner: owner, now: Date(timeIntervalSince1970: 1_000))
    }

    func testAnItemCarriesTheDraftNotASignedEvent() {
        let i = item(.add)
        XCTAssertEqual(i.kind, .fileNote)
        XCTAssertEqual(i.id, sha)
        XCTAssertNil(i.eventJSON, "signed at send time, not when queued")
        XCTAssertNil(i.target, "the home vault's lane only")
        XCTAssertEqual(i.fileNote?.action, .add)
    }

    func testRoundTripsThroughJSON() throws {
        let queue = [item(.add), item(.delete, sha: String(repeating: "cd", count: 32))]
        let data = try JSONEncoder().encode(queue)
        XCTAssertEqual(try JSONDecoder().decode([HomeVaultItem].self, from: data), queue)
    }

    func testAnOldQueueStillDecodes() throws {
        let old = """
        [{"kind":"blob","id":"\(sha)","ownerHex":"\(owner)","contentType":"image/jpeg","added":0,"attempts":2}]
        """
        let queue = try JSONDecoder().decode([HomeVaultItem].self, from: Data(old.utf8))
        XCTAssertEqual(queue.count, 1)
        XCTAssertNil(queue[0].fileNote)
    }

    func testADeleteReplacesAWaitingAddForTheSameBlob() {
        var queue = HomeVaultLogic.addingFileNote(item(.add), to: [])
        queue = HomeVaultLogic.addingFileNote(item(.delete), to: queue)
        XCTAssertEqual(queue.map { $0.fileNote?.action }, [.delete])
    }

    func testAnAddReplacesAWaitingDelete() {
        var queue = HomeVaultLogic.addingFileNote(item(.delete), to: [])
        queue = HomeVaultLogic.addingFileNote(item(.add), to: queue)
        XCTAssertEqual(queue.map { $0.fileNote?.action }, [.add])
    }

    func testTheSameAddTwiceIsQueuedOnce() {
        var queue = HomeVaultLogic.addingFileNote(item(.add), to: [])
        queue = HomeVaultLogic.addingFileNote(item(.add), to: queue)
        XCTAssertEqual(queue.count, 1)
    }

    func testOtherItemsAreKept() {
        let blob = HomeVaultItem(kind: .blob, id: sha, ownerHex: owner, eventJSON: nil, contentType: "image/jpeg",
                                 added: Date(), attempts: 0, notBefore: nil)
        let queue = HomeVaultLogic.addingFileNote(item(.delete), to: [blob])
        XCTAssertEqual(queue.map(\.kind), [.blob, .fileNote])
    }

    func testForgettingADeletedBlobKeepsItsDeleteNote() {
        let blob = HomeVaultItem(kind: .blob, id: sha, ownerHex: owner, eventJSON: nil, contentType: "image/jpeg",
                                 added: Date(), attempts: 0, notBefore: nil)
        let kept = HomeVaultLogic.droppingDeleted([blob, item(.delete)], eventIDs: [], author: nil, blob: sha)
        XCTAssertEqual(kept.map(\.kind), [.fileNote], "the blob send goes; the kind 5 for it must still go")
    }

    func testAFileNoteNeedsNoPersonToSign() {
        XCTAssertFalse(HomeVaultLogic.needsAccountSigner(.fileNote), "the device mesh key signs it")
        XCTAssertTrue(HomeVaultLogic.needsAccountSigner(.blob))
        XCTAssertFalse(HomeVaultLogic.needsAccountSigner(.event))
    }
}
