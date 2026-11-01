import XCTest
@testable import MediaLogic

/// Sweep 2026-11-01 #1: Hashtags feed authors never got a name or photo.
final class ProfileLookupBatchTests: XCTestCase {
    func testChunksSplitLargeBatchesInOrder() {
        let keys = (0..<403).map { String(format: "%064x", $0) }
        let chunks = ProfileLookupBatch.chunks(keys)
        XCTAssertEqual(chunks.map(\.count), [100, 100, 100, 100, 3])
        XCTAssertEqual(chunks.flatMap { $0 }, keys)
        XCTAssertEqual(ProfileLookupBatch.chunks([]), [])
        XCTAssertEqual(ProfileLookupBatch.chunks(["a", "b"], size: 0), [["a"], ["b"]])
    }

    /// What a new WebSocketClient publishes on connect: its starting value,
    /// connect()'s teardown, then .connecting and .connected.
    func testANewSocketIsNotClosedBeforeItOpens() {
        var watch = ProfileLookupBatch.OpenWatch()
        XCTAssertFalse(watch.isClosed(.disconnected), "starting value")
        XCTAssertFalse(watch.isClosed(.disconnected), "connect() teardown")
        XCTAssertFalse(watch.isClosed(.connecting))
        XCTAssertFalse(watch.isClosed(.connected))
        XCTAssertTrue(watch.isClosed(.disconnected), "a real close")
    }

    func testAnErrorAlwaysCloses() {
        var refused = ProfileLookupBatch.OpenWatch()
        XCTAssertFalse(refused.isClosed(.disconnected))
        XCTAssertTrue(refused.isClosed(.error), "blocked relay")
        var dropped = ProfileLookupBatch.OpenWatch()
        _ = dropped.isClosed(.connecting)
        XCTAssertTrue(dropped.isClosed(.error))
    }

    /// The lookup socket goes through the watch and sends chunked REQs.
    func testProfilesUseTheWatchAndChunks() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../HavenApp/Services/Nostr/NostrService+Profiles.swift").standardized
        let src = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(src.contains("watch.isClosed(state.lookupState)"))
        XCTAssertTrue(src.contains("for chunk in ProfileLookupBatch.chunks(pubkeys)"))
        XCTAssertFalse(src.contains("case .disconnected, .error:\n                    // Only forget it"))
    }
}
