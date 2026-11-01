import XCTest
@testable import MediaLogic

final class UploadSignerTests: XCTestCase {
    private let a = String(repeating: "a", count: 64)
    private let b = String(repeating: "b", count: 64)

    func testSameAccountDoesNotReupload() {
        XCTAssertFalse(UploadSigner.needsReupload(signer: a, lockedHex: a))
    }

    func testOtherAccountReuploads() {
        // Picked as A, posted as B: A's link must not go out in B's note.
        XCTAssertTrue(UploadSigner.needsReupload(signer: a, lockedHex: b))
    }

    func testNothingSignedDoesNotReupload() {
        // Picked from this device's relay: no upload was signed.
        XCTAssertFalse(UploadSigner.needsReupload(signer: nil, lockedHex: b))
    }

    func testRecordedKeepsAnUnchangedAccount() {
        XCTAssertEqual(UploadSigner.recorded(atStart: a, atEnd: a), a)
    }

    func testAccountChangedMidUploadAlwaysReuploads() {
        let signer = UploadSigner.recorded(atStart: a, atEnd: b)
        XCTAssertTrue(UploadSigner.needsReupload(signer: signer, lockedHex: a))
        XCTAssertTrue(UploadSigner.needsReupload(signer: signer, lockedHex: b))
    }
}
