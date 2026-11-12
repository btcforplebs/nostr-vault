import XCTest
@testable import MediaLogic

/// Auto-Mirror on Logen's iPhone 18 (2026-11-12): every launch re-downloaded
/// every photo whose link is not named by its hash, and asked the bunker for
/// one signature per photo — about 1,100 in 25 minutes with nothing new saved.
final class AutoMirrorLedgerTests: XCTestCase {
    private let hashA = String(repeating: "a", count: 64)
    private let hashB = String(repeating: "b", count: 64)
    private let named = URL(string: "https://image.nostr.build/photo123.jpg")!
    private let other = URL(string: "https://void.cat/d/xyz.png")!

    /// The bug: a saved photo whose link name isn't its hash was downloaded again.
    func testSavedPhotoIsNotDownloadedAgain() {
        var ledger = AutoMirrorLedger()
        ledger.remember(url: named, sha256: hashA)
        XCTAssertEqual(ledger.toDownload([named, other], localHashes: [hashA]), [other])
    }

    func testHashNamedLinkAlreadyHereIsSkipped() {
        let hashNamed = URL(string: "https://blossom.primal.net/\(hashB).jpg")!
        XCTAssertEqual(AutoMirrorLedger().toDownload([hashNamed, other], localHashes: [hashB]), [other])
    }

    /// Once saved means once: a photo deleted from the vault later is not brought back.
    func testRememberedPhotoStaysSkippedAfterDelete() {
        var ledger = AutoMirrorLedger()
        ledger.remember(url: named, sha256: hashA)
        XCTAssertEqual(ledger.toDownload([named], localHashes: []), [])
    }

    /// A run stopped part way: what it saved is on disk, so the next run starts after it.
    func testStoppedRunResumesFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("automirror-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var ledger = AutoMirrorLedger.load(from: dir)
        ledger.remember(url: named, sha256: hashA)
        try ledger.save(to: dir)

        let next = AutoMirrorLedger.load(from: dir)
        XCTAssertEqual(next.toDownload([named, other], localHashes: []), [other])
    }

    func testUnreadableLedgerStartsEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("automirror-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not json".utf8).write(to: dir.appendingPathComponent(AutoMirrorLedger.fileName))
        XCTAssertEqual(AutoMirrorLedger.load(from: dir), AutoMirrorLedger())
    }

    /// Downloaded and already in the vault: stored nowhere, signed for by nobody.
    func testDownloadAlreadyInVaultNeedsNoSave() {
        XCTAssertEqual(AutoMirrorSave.decide(sha256: hashA.uppercased(), localHashes: [hashA]), .alreadyHere)
        XCTAssertEqual(AutoMirrorSave.decide(sha256: hashB, localHashes: [hashA]), .store)
    }
}

final class AutoMirrorSigningTests: XCTestCase {
    /// The owner's own vault takes the files in-process: no signer asked at all.
    func testOwnerRunAsksNoSigner() {
        XCTAssertEqual(AutoMirrorSigning.plan(keyless: false, activeIsOwner: true), .none)
        XCTAssertEqual(AutoMirrorSigning.plan(keyless: true, activeIsOwner: false), .none)
    }

    /// Another account files them under its own key: one signature per batch, not per photo.
    func testOtherAccountSignsPerBatch() {
        XCTAssertEqual(AutoMirrorSigning.plan(keyless: false, activeIsOwner: false), .batch)
    }

    func testBatchesCapHashesPerSignature() {
        let hashes = (0..<450).map { String(format: "%064x", $0) }
        let batches = AutoMirrorSigning.batches(hashes)
        XCTAssertEqual(batches.map(\.count), [200, 200, 50])
        XCTAssertEqual(batches.flatMap { $0 }, hashes)
        XCTAssertEqual(AutoMirrorSigning.batches([String]()).count, 0)
    }
}
