import XCTest
@testable import MediaLogic

/// A standalone draft picked inside a Reply composer posted as a reply to
/// that composer's note.
final class ComposerContextTests: XCTestCase {
    func testAStandaloneDraftInAReplyComposerIsNotAReply() {
        XCTAssertNil(ComposerContext.effective(draftLoaded: true, draft: nil as String?, composer: "noteX"))
    }

    func testALoadedDraftKeepsItsOwnTarget() {
        XCTAssertEqual(ComposerContext.effective(draftLoaded: true, draft: "noteY", composer: "noteX"), "noteY")
        XCTAssertEqual(ComposerContext.effective(draftLoaded: true, draft: "noteY", composer: nil), "noteY")
    }

    func testWithoutADraftTheComposersTargetIsUsed() {
        XCTAssertEqual(ComposerContext.effective(draftLoaded: false, draft: nil, composer: "noteX"), "noteX")
        XCTAssertNil(ComposerContext.effective(draftLoaded: false, draft: nil as String?, composer: nil))
    }
}
