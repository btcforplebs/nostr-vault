import XCTest
import Combine
@testable import MediaLogic

final class ProfileWriteBatchTests: XCTestCase {
    private final class Store: ObservableObject {
        @Published var profiles: [String: FeedProfile] = [:]
    }

    private func profile(_ n: Int, at createdAt: Int64? = 100) -> FeedProfile {
        var p = FeedProfile(pubkey: "pk\(n)", name: "name\(n)")
        p.metadataCreatedAt = createdAt
        return p
    }

    func testFlushPublishesOnceForManyProfiles() {
        let store = Store()
        var publishes = 0
        let sink = store.objectWillChange.sink { publishes += 1 }
        defer { sink.cancel() }
        var batch = ProfileWriteBatch()
        for n in 0..<50 { batch.add(profile(n)) }
        XCTAssertEqual(publishes, 0)

        let written = batch.flush(into: &store.profiles)

        XCTAssertEqual(publishes, 1)
        XCTAssertEqual(written.count, 50)
        XCTAssertEqual(store.profiles.count, 50)
        XCTAssertEqual(store.profiles["pk7"]?.name, "name7")
        XCTAssertTrue(batch.isEmpty)
    }

    /// The control: the old one-at-a-time writes publish once per profile.
    func testOneByOneWritesPublishPerProfile() {
        let store = Store()
        var publishes = 0
        let sink = store.objectWillChange.sink { publishes += 1 }
        defer { sink.cancel() }
        for n in 0..<50 { store.profiles[profile(n).pubkey] = profile(n) }
        XCTAssertEqual(publishes, 50)
    }

    func testStoresTheSameAsOneByOne() {
        var batch = ProfileWriteBatch()
        var oneByOne: [String: FeedProfile] = ["old": profile(99)]
        var batched = oneByOne
        for n in 0..<10 {
            batch.add(profile(n))
            oneByOne[profile(n).pubkey] = profile(n)
        }
        _ = batch.flush(into: &batched)
        XCTAssertEqual(batched, oneByOne)
    }

    func testCurrentPrefersWaitingProfile() {
        var batch = ProfileWriteBatch()
        let stored = ["pk1": profile(1, at: 10)]
        XCTAssertEqual(batch.current("pk1", stored: stored)?.metadataCreatedAt, 10)
        batch.add(profile(1, at: 20))
        XCTAssertEqual(batch.current("pk1", stored: stored)?.metadataCreatedAt, 20)
        batch.add(profile(1, at: 30))
        XCTAssertEqual(batch.pending.count, 1)
    }

    func testNewerDirectWriteIsKept() {
        var batch = ProfileWriteBatch()
        batch.add(profile(1, at: 10))
        var newer = profile(1, at: 50)
        newer.name = "edited"
        var profiles = ["pk1": newer]
        XCTAssertEqual(batch.flush(into: &profiles), [])
        XCTAssertEqual(profiles["pk1"]?.name, "edited")
    }

    func testEmptyFlushWritesNothing() {
        var batch = ProfileWriteBatch()
        var profiles: [String: FeedProfile] = [:]
        XCTAssertEqual(batch.flush(into: &profiles), [])
    }
}
