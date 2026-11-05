import Foundation
import XCTest
@testable import MediaLogic

/// Mac bug hunt 2026-11-05, composer follow-ups.
final class MacComposerFixesTests: XCTestCase {
    /// ⌘V attaches a copied photo or video, never in place of text.
    func testPasteAttachesOnlyAnImageOrVideoWithNoText() {
        XCTAssertTrue(ComposePasteRule.pastesMedia(types: ["public.png"]))
        XCTAssertTrue(ComposePasteRule.pastesMedia(types: ["public.tiff", "public.png"]))
        XCTAssertTrue(ComposePasteRule.pastesMedia(types: ["public.mpeg-4"]))
        XCTAssertFalse(ComposePasteRule.pastesMedia(types: ["public.utf8-plain-text"]))
        // A web page's image with its text, and a file copied in Finder (its
        // icon as TIFF beside its name and URL) stay text pastes.
        XCTAssertFalse(ComposePasteRule.pastesMedia(types: ["public.html", "public.utf8-plain-text", "public.tiff"]))
        XCTAssertFalse(ComposePasteRule.pastesMedia(types: ["public.file-url", "public.utf8-plain-text", "public.tiff"]))
        XCTAssertFalse(ComposePasteRule.pastesMedia(types: ["NSStringPboardType", "public.png"]))
    }

    /// Edit on the countdown pill from another tab goes to Feed, whose
    /// composer reopens the post.
    func testEditFromAnotherTabGoesToFeed() {
        XCTAssertTrue(PendingPostEdit.switchesToFeed(hasRequest: true, onFeed: false))
        XCTAssertFalse(PendingPostEdit.switchesToFeed(hasRequest: true, onFeed: true))
        XCTAssertFalse(PendingPostEdit.switchesToFeed(hasRequest: false, onFeed: false))
    }

    /// No screen tells people to run `pkill -9 haven`: the relay runs inside
    /// the app, so there is no such process and it killed nothing.
    func testNoScreenSaysToRunPkill() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("HavenApp")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
        var scanned = 0
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" || url.pathExtension == "xcstrings" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains("pkill -9 haven") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue } // history in comments is fine
                offenders.append("\(url.lastPathComponent): \(trimmed)")
            }
        }
        XCTAssertGreaterThan(scanned, 100, "scanned the wrong folder")
        XCTAssertEqual(offenders, [])
    }
}
