import XCTest
@testable import MediaLogic

final class DeletedPostsStoreTests: XCTestCase {

    private let me = String(repeating: "a", count: 64)
    private let other = String(repeating: "b", count: 64)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deleted-posts-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func post(
        id: String = String(repeating: "1", count: 64),
        pubkey: String? = nil,
        tags: [[String]] = [["e", String(repeating: "9", count: 64), "", "reply"], ["p", String(repeating: "8", count: 64)]],
        deletedAt: Date? = nil
    ) -> DeletedPost {
        DeletedPost(
            id: id, pubkey: pubkey ?? me, createdAt: 1_700_000_000, kind: 1, tags: tags,
            content: "vault delete test, ignore\nhttps://blossom.example/x.jpg",
            sig: String(repeating: "f", count: 128), deletedAt: deletedAt ?? now
        )
    }

    // MARK: - Round trip

    /// A saved copy reads back field for field from a fresh store on the same
    /// directory, the way it would after a relaunch.
    func testSavedPostReadsBackAfterRelaunch() {
        let saved = post()
        DeletedPostsStore(directory: directory).save(saved, now: now)

        let reread = DeletedPostsStore(directory: directory).posts(account: me, now: now)
        XCTAssertEqual(reread, [saved])
    }

    func testAccountsDoNotSeeEachOthersPosts() {
        let store = DeletedPostsStore(directory: directory)
        store.save(post(id: String(repeating: "1", count: 64)), now: now)
        store.save(post(id: String(repeating: "2", count: 64), pubkey: other), now: now)

        XCTAssertEqual(store.posts(account: me, now: now).map(\.id), [String(repeating: "1", count: 64)])
        XCTAssertEqual(store.posts(account: other, now: now).map(\.id), [String(repeating: "2", count: 64)])
    }

    func testRemoveDropsOnlyThatPost() {
        let store = DeletedPostsStore(directory: directory)
        let a = post(id: String(repeating: "1", count: 64))
        let b = post(id: String(repeating: "2", count: 64))
        store.save(a, now: now)
        store.save(b, now: now)

        store.remove(id: a.id, account: me)
        XCTAssertEqual(store.posts(account: me, now: now), [b])
    }

    func testDeletingTheSameIdTwiceKeepsOneCopy() {
        let store = DeletedPostsStore(directory: directory)
        store.save(post(deletedAt: now.addingTimeInterval(-day)), now: now)
        store.save(post(deletedAt: now), now: now)

        XCTAssertEqual(store.posts(account: me, now: now).map(\.deletedAt), [now])
    }

    func testAccountThatIsNotAPubkeyIsNeverWritten() {
        let store = DeletedPostsStore(directory: directory)
        store.save(post(pubkey: "../../escape"), now: now)

        XCTAssertEqual(store.posts(account: "../../escape", now: now), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: - 30-day expiry

    func testPostsOlderThanThirtyDaysExpire() {
        let store = DeletedPostsStore(directory: directory)
        let fresh = post(id: String(repeating: "1", count: 64), deletedAt: now.addingTimeInterval(-29 * day))
        let stale = post(id: String(repeating: "2", count: 64), deletedAt: now.addingTimeInterval(-31 * day))
        store.save(fresh, now: now.addingTimeInterval(-31 * day))
        store.save(stale, now: now.addingTimeInterval(-31 * day))

        XCTAssertEqual(store.posts(account: me, now: now), [fresh])
        // The expired copy is gone from disk too, not only hidden.
        XCTAssertEqual(DeletedPostsStore(directory: directory).posts(account: me, now: now.addingTimeInterval(-31 * day)), [fresh])
    }

    func testMostRecentlyDeletedComesFirst() {
        let older = post(id: String(repeating: "1", count: 64), deletedAt: now.addingTimeInterval(-2 * day))
        let newer = post(id: String(repeating: "2", count: 64), deletedAt: now.addingTimeInterval(-day))
        XCTAssertEqual(DeletedPostsStore.unexpired([older, newer], now: now), [newer, older])
    }

    // MARK: - Un-delete event

    /// Un-delete signs the same kind, text and tags, so a deleted reply comes
    /// back in its thread. The new `created_at` comes from the signer.
    func testRepublishDraftKeepsKindContentAndTags() {
        let saved = post()
        let draft = saved.republishDraft()
        XCTAssertEqual(draft.kind, saved.kind)
        XCTAssertEqual(draft.content, saved.content)
        XCTAssertEqual(draft.tags, saved.tags)
    }

    func testRepublishDraftDropsTheOldProofOfWork() {
        let saved = post(tags: [["p", other], ["nonce", "12345", "20"]])
        XCTAssertEqual(saved.republishDraft().tags, [["p", other]])
    }

    /// A passed NIP-40 expiry would make relays refuse the new event.
    func testRepublishDraftDropsTheExpiration() {
        let saved = post(tags: [["p", other], ["expiration", "1700000100"]])
        XCTAssertEqual(saved.republishDraft().tags, [["p", other]])
    }

    /// Posted again with today's time, an old replaceable or addressable
    /// version would replace the newer one live at that address.
    func testReplaceableAndAddressableKindsGetNoCopy() {
        for kind in [1, 6, 16, 20, 1068, 1111] { XCTAssertTrue(DeletedPost.keepsCopy(kind: kind), "\(kind)") }
        for kind in [0, 3, 10000, 10002, 19999, 30023, 30402, 39999] { XCTAssertFalse(DeletedPost.keepsCopy(kind: kind), "\(kind)") }
    }

    func testChangesAreAnnounced() {
        let store = DeletedPostsStore(directory: directory)
        let saved = expectation(forNotification: DeletedPostsStore.didChange, object: nil)
        store.save(post(), now: now)
        wait(for: [saved], timeout: 1)
        let removed = expectation(forNotification: DeletedPostsStore.didChange, object: nil)
        store.remove(id: post().id, account: me)
        wait(for: [removed], timeout: 1)
    }
}
