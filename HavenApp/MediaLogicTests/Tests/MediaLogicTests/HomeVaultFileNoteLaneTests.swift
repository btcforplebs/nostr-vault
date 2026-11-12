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
    // MARK: Tron's PR 1990 follow-ups, Apple side

    func testFileNotesHaveTheirOwnCap() {
        let blobs = (0..<3).map { i in
            HomeVaultItem(kind: .blob, id: String(format: "%064x", i), ownerHex: owner, eventJSON: nil,
                          contentType: "image/jpeg", added: Date(), attempts: 0, notBefore: nil)
        }
        let notes = (0..<3).map { i in item(.add, sha: String(format: "%064x", 100 + i)) }
        let queue = blobs + notes
        XCTAssertTrue(HomeVaultLogic.hasRoom(for: blobs[0], in: notes + blobs.prefix(2), max: 3),
                      "waiting notes never take a blob's place")
        XCTAssertFalse(HomeVaultLogic.hasRoom(for: blobs[0], in: queue, max: 3))
        XCTAssertFalse(HomeVaultLogic.hasRoom(for: item(.add, sha: String(format: "%064x", 999)), in: queue, max: 3),
                       "notes stop at their own cap")
        XCTAssertTrue(HomeVaultLogic.hasRoom(for: item(.add, sha: String(format: "%064x", 999)), in: blobs, max: 3))
    }

    func testTheKind5GoesOnlyWhenTheHomeVaultTookTheDelete() {
        let home = "npub1home"
        let homeKey = MeshDeleteTarget(npub: home, name: "").key
        XCTAssertTrue(HomeVaultLogic.homeVaultTookDelete(homeVaultNpub: home, deleted: [homeKey, "https://nostr.build"]))
        XCTAssertFalse(HomeVaultLogic.homeVaultTookDelete(homeVaultNpub: home, deleted: ["https://nostr.build"]),
                       "a mirror taking it while the vault keeps the blob must not empty the room")
        XCTAssertFalse(HomeVaultLogic.homeVaultTookDelete(homeVaultNpub: home, deleted: [MeshDeleteTarget(npub: "npub1mac", name: "").key]))
        XCTAssertFalse(HomeVaultLogic.homeVaultTookDelete(homeVaultNpub: nil, deleted: [homeKey]))
        XCTAssertFalse(HomeVaultLogic.homeVaultTookDelete(homeVaultNpub: "", deleted: [homeKey]))
    }

    func testWhatTheRoomsAnswerMeans() {
        XCTAssertEqual(HomeVaultLogic.fileNoteOutcome(accepted: true, message: ""), .sent)
        XCTAssertEqual(HomeVaultLogic.fileNoteOutcome(accepted: false, message: "duplicate: have it"), .sent)
        XCTAssertEqual(HomeVaultLogic.fileNoteOutcome(accepted: false, message: "restricted: not paired"),
                       .rejected("restricted: not paired"))
        XCTAssertEqual(HomeVaultLogic.fileNoteOutcome(accepted: false, message: "blocked: deleted"),
                       .unreachable("blocked: deleted"), "only restricted drops; anything else waits")
        XCTAssertEqual(HomeVaultLogic.fileNoteOutcome(accepted: false, message: "error: db"), .unreachable("error: db"))
    }

    func testTheServingServerIsNamedFirst() {
        let configured = ["https://a.example", "https://b.example"]
        XCTAssertEqual(HomeVaultLogic.fileNoteServers(configured: configured, hosted: URL(string: "https://B.example/x.jpg")),
                       ["https://b.example", "https://a.example"])
        XCTAssertEqual(HomeVaultLogic.fileNoteServers(configured: configured, hosted: URL(string: "https://cdn.example/x.jpg")),
                       configured, "a CDN answer keeps the configured order")
        XCTAssertEqual(HomeVaultLogic.fileNoteServers(configured: configured, hosted: nil), configured)
        XCTAssertEqual(HomeVaultLogic.fileNoteServers(configured: [], hosted: URL(string: "https://a.example/x")), [])
    }
}
