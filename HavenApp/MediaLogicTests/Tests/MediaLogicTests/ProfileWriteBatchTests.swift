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

    // MARK: - LatestOnlySave

    private final class Recorder {
        let lock = NSLock()
        var values: [Int] = []
        var concurrent = 0
        var maxConcurrent = 0
    }

    func testSavesWhileOneRunsCollapseToTheNewest() {
        let queue = DispatchQueue(label: "test.save", attributes: .concurrent)
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let done = expectation(description: "drained")
        let rec = Recorder()
        let saver = LatestOnlySave<Int>(queue: queue) { value in
            rec.lock.lock(); rec.concurrent += 1; rec.maxConcurrent = max(rec.maxConcurrent, rec.concurrent); rec.lock.unlock()
            if value == 1 { started.signal(); gate.wait() }
            rec.lock.lock(); rec.values.append(value); rec.concurrent -= 1; rec.lock.unlock()
            if value == 4 { done.fulfill() }
        }
        saver.save(1)
        started.wait()
        saver.save(2)
        saver.save(3)
        saver.save(4)
        gate.signal()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(rec.values, [1, 4])
        XCTAssertEqual(rec.maxConcurrent, 1)
    }

    func testSaveAfterDrainRunsAgain() {
        let queue = DispatchQueue(label: "test.save2")
        let rec = Recorder()
        let saver = LatestOnlySave<Int>(queue: queue) { value in
            rec.lock.lock(); rec.values.append(value); rec.lock.unlock()
        }
        saver.save(1)
        queue.sync {}
        saver.save(2)
        queue.sync {}
        XCTAssertEqual(rec.values, [1, 2])
    }

    // MARK: - ProfileCacheShards

    private func fp(_ pubkey: String, _ name: String = "a") -> FeedProfile {
        FeedProfile(pubkey: pubkey, name: name)
    }

    func testUnchangedProfilesWriteNothing() {
        var shards = ProfileCacheShards(loaded: ["aa01": CachedProfile(p: fp("aa01"), s: 5)])
        XCTAssertTrue(shards.plan(["aa01": fp("aa01")], now: 10, keep: []).isEmpty)
    }

    func testAChangedProfileRewritesOnlyItsShardWhole() {
        var shards = ProfileCacheShards(loaded: [
            "aa01": CachedProfile(p: fp("aa01"), s: 5),
            "aa02": CachedProfile(p: fp("aa02"), s: 6),
            "bb01": CachedProfile(p: fp("bb01"), s: 7),
        ])
        let writes = shards.plan(["aa01": fp("aa01", "new"), "aa02": fp("aa02"), "bb01": fp("bb01")], now: 10, keep: [])
        XCTAssertEqual(Set(writes.keys), ["aa"])
        XCTAssertEqual(writes["aa"]?["aa01"], CachedProfile(p: fp("aa01", "new"), s: 10))
        XCTAssertEqual(writes["aa"]?["aa02"], CachedProfile(p: fp("aa02"), s: 6))
    }

    func testCapDropsOldestButNeverKept() {
        var shards = ProfileCacheShards(loaded: [
            "aa01": CachedProfile(p: fp("aa01"), s: 1),
            "bb01": CachedProfile(p: fp("bb01"), s: 2),
            "cc01": CachedProfile(p: fp("cc01"), s: 3),
        ])
        let all = ["aa01": fp("aa01"), "bb01": fp("bb01"), "cc01": fp("cc01"), "dd01": fp("dd01")]
        let writes = shards.plan(all, now: 10, keep: ["aa01"], cap: 2)
        XCTAssertEqual(Set(shards.onDisk.keys), ["aa01", "dd01"])
        XCTAssertEqual(writes["bb"], [:])
        XCTAssertEqual(writes["cc"], [:])
        XCTAssertEqual(writes["dd"]?["dd01"]?.s, 10)
        XCTAssertNil(writes["aa"])
        // Left off disk but still in memory and unchanged: not written back.
        XCTAssertTrue(shards.plan(all, now: 11, keep: ["aa01"], cap: 2).isEmpty)
    }

    func testLegacyCacheWritesEveryShardOnce() {
        var dated = fp("aa01")
        dated.metadataCreatedAt = 7
        var shards = ProfileCacheShards(legacy: ["aa01": dated, "Zq": fp("Zq")])
        let writes = shards.plan(["aa01": dated, "Zq": fp("Zq")], now: 10, keep: [])
        XCTAssertEqual(writes.count, 257)
        XCTAssertEqual(writes["aa"]?["aa01"]?.s, 7)
        XCTAssertEqual(writes["zz"]?["Zq"]?.s, 0)
        XCTAssertTrue(shards.plan(["aa01": dated, "Zq": fp("Zq")], now: 11, keep: []).isEmpty)
    }

    func testRemovedProfileLeavesItsShard() {
        var shards = ProfileCacheShards(loaded: ["aa01": CachedProfile(p: fp("aa01"), s: 5)])
        XCTAssertEqual(shards.plan([:], now: 10, keep: []), ["aa": [:]])
    }
}

