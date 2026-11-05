import XCTest
@testable import MediaLogic

/// One confirmation wording on both platforms (Logen 2026-11-05, RESEARCH
/// NV_MIRROR_DELETE_ANDROID_VS_IOS #7). Android's DeleteBlobConfirmDialog
/// carries these exact strings; change both together.
final class MediaDeleteWordingTests: XCTestCase {
    func testTheAgreedWords() {
        XCTAssertEqual(MediaDeleteWording.mirrors,
                       "Removes this file from your media servers. This device and your home vault keep their copies.")
        XCTAssertEqual(MediaDeleteWording.everywhere,
                       "Permanently removes this file from this device, your home vault and your media servers. This cannot be undone.")
    }

    /// Fits a Mac as well as a phone, and names the home vault.
    func testWordingFitsEveryDevice() {
        for text in [MediaDeleteWording.mirrors, MediaDeleteWording.everywhere] {
            XCTAssertFalse(text.contains("phone"), text)
            XCTAssertTrue(text.contains("home vault"), text)
        }
    }
}

/// Mesh settings explain where new photos go instead of offering a picker
/// whose value nothing read (Logen 2026-11-05). The website's home vault help
/// page carries the same words.
final class MeshPhotoPathTests: XCTestCase {
    func testTheAgreedWords() {
        XCTAssertEqual(MeshPhotoPath.explainer, "New photos are saved on this device first. If you have a home vault, a copy goes to it over the mesh, and the home vault puts it on your public media server for you. If this device has its own media server, it uploads there itself.")
    }

    func testHelpPageSaysTheSame() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let page = try String(contentsOf: repo.appendingPathComponent("website/docs/_src/mesh/home-vault.html"), encoding: .utf8)
        XCTAssertTrue(page.contains(MeshPhotoPath.explainer))
        XCTAssertFalse(page.contains("doesn't change anything yet"))
    }
}
