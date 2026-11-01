import XCTest
@testable import MediaLogic

final class UploadDeleteRuleTests: XCTestCase {
    private let a = String(repeating: "a", count: 64)
    private let b = String(repeating: "b", count: 64)
    private let sha = String(repeating: "1", count: 64)
    private let servers = ["https://blossom.one", "https://blossom.two"]

    private func fresh(signer: String? = nil) -> UploadDeleteRule.FreshUpload {
        .init(servers: servers, signer: signer ?? a)
    }

    // MARK: isFresh

    func testFreshOnlyWhenEveryServerSaid404() {
        XCTAssertTrue(UploadDeleteRule.isFresh(statuses: [404, 404, 404]))
    }

    func testOneServerHavingItIsNotFresh() {
        // Already in an earlier note on one server.
        XCTAssertFalse(UploadDeleteRule.isFresh(statuses: [404, 200, 404]))
    }

    func testNoAnswerIsNotFresh() {
        XCTAssertFalse(UploadDeleteRule.isFresh(statuses: [404, nil]))
    }

    func testServerErrorOrRedirectIsNotFresh() {
        XCTAssertFalse(UploadDeleteRule.isFresh(statuses: [404, 500]))
        XCTAssertFalse(UploadDeleteRule.isFresh(statuses: [302, 404]))
    }

    func testAskingNobodyIsNotFresh() {
        XCTAssertFalse(UploadDeleteRule.isFresh(statuses: []))
    }

    // MARK: deleteTargets

    func testFreshUploadDeletesFromTheServersAsked() {
        XCTAssertEqual(UploadDeleteRule.deleteTargets(sha256: sha, fresh: fresh(), otherHashes: [b],
                                                      postTapped: false, activeHex: a), servers)
    }

    func testBlobAlreadyOutThereIsNeverDeleted() {
        XCTAssertNil(UploadDeleteRule.deleteTargets(sha256: sha, fresh: nil, otherHashes: [],
                                                    postTapped: false, activeHex: a))
    }

    func testSameHashStillInTheNoteIsNotDeleted() {
        // Two copies of one photo: removing one must not break the other.
        XCTAssertNil(UploadDeleteRule.deleteTargets(sha256: sha, fresh: fresh(), otherHashes: [nil, sha],
                                                    postTapped: false, activeHex: a))
    }

    func testNothingIsDeletedOncePostWasTapped() {
        // A failed or queued send may still publish the link.
        XCTAssertNil(UploadDeleteRule.deleteTargets(sha256: sha, fresh: fresh(), otherHashes: [],
                                                    postTapped: true, activeHex: a))
    }

    func testOnlyTheUploadingAccountDeletes() {
        XCTAssertNil(UploadDeleteRule.deleteTargets(sha256: sha, fresh: fresh(signer: a), otherHashes: [],
                                                    postTapped: false, activeHex: b))
        XCTAssertNil(UploadDeleteRule.deleteTargets(sha256: sha,
                                                    fresh: .init(servers: servers, signer: UploadSigner.changedDuringUpload),
                                                    otherHashes: [], postTapped: false, activeHex: a))
    }

    func testNoServersAskedMeansNoDelete() {
        XCTAssertNil(UploadDeleteRule.deleteTargets(sha256: sha, fresh: .init(servers: [], signer: a),
                                                    otherHashes: [], postTapped: false, activeHex: a))
    }

    func testNoDeleteWhileAnotherPhotoIsStillUploading() {
        // A second copy still checking the servers would see the blob as there
        // and link to it just before the delete lands.
        XCTAssertNil(UploadDeleteRule.deleteTargets(sha256: sha, fresh: fresh(), otherHashes: [nil],
                                                    postTapped: false, activeHex: a, anyUnfinished: true))
    }
}
