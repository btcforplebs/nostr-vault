import XCTest
@testable import MediaLogic

/// One confirmation wording on both platforms (Logen 2026-11-05, RESEARCH
/// NV_MIRROR_DELETE_ANDROID_VS_IOS #7). Android's DeleteBlobConfirmDialog
/// carries these exact strings; change both together.
final class MediaDeleteWordingTests: XCTestCase {
    func testTheAgreedWords() {
        XCTAssertEqual(MediaDeleteWording.mirrors,
                       "Removes this file from your media servers. This device and your mobile or desktop vault keep their copies.")
        XCTAssertEqual(MediaDeleteWording.everywhere,
                       "Permanently removes this file from this device, your mobile or desktop vault and your media servers. This cannot be undone.")
    }

    /// Fits a Mac as well as a phone, and names the home vault.
    func testWordingFitsEveryDevice() {
        for text in [MediaDeleteWording.mirrors, MediaDeleteWording.everywhere] {
            XCTAssertFalse(text.contains("phone"), text)
            XCTAssertTrue(text.contains("mobile or desktop vault"), text)
        }
    }
}

/// Delete from mirrors names an own vault it left alone (Tron #1783
/// follow-up 2): it used to be left out, so the banner read "Deleted from
/// mirrors". Android `mirrorsDeleteMessage` and the web vault say the same.
final class MirrorsDeleteReportTests: XCTestCase {
    func testASkippedVaultIsNamedNextToTheDelete() {
        let r = MediaDeleteWording.mirrorsReport(deleted: ["https://blossom.band"], failedHosts: [],
                                                 skippedHosts: ["studio-mac.example.net"])
        XCTAssertEqual(r.text, "Deleted from mirrors. Skipped: studio-mac.example.net (your own vault)")
        XCTAssertTrue(r.ok)
    }

    func testOnlyOwnVaultsIsNoMirrorsAndSaysWhy() {
        let r = MediaDeleteWording.mirrorsReport(deleted: [], failedHosts: [], skippedHosts: ["studio-mac.example.net"])
        XCTAssertEqual(r.text, "No mirrors to delete from. Skipped: studio-mac.example.net (your own vault)")
        XCTAssertFalse(r.ok)
    }

    func testEachOutcome() {
        XCTAssertEqual(MediaDeleteWording.mirrorsReport(deleted: [], failedHosts: [], skippedHosts: []).text, "No mirrors to delete from")
        XCTAssertEqual(MediaDeleteWording.mirrorsReport(deleted: ["https://blossom.band"], failedHosts: [], skippedHosts: []).text,
                       "Deleted from mirrors")
        let left = MediaDeleteWording.mirrorsReport(deleted: ["https://blossom.band"], failedHosts: ["cdn.example.org"],
                                                    skippedHosts: ["a.example.net", "b.example.net"])
        XCTAssertEqual(left.text, "Still on cdn.example.org. Skipped: a.example.net and b.example.net (your own vaults)")
        XCTAssertFalse(left.ok)
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
