import XCTest
@testable import MediaLogic

/// Article, recipe and poll drafts survive a restart, stay with their
/// account and kind, and keep their cover photo.
final class ComposerDraftStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-drafts-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func recipe() -> ComposerDraft {
        var d = ComposerDraft(kind: .recipe)
        d.title = "Pancakes"
        d.prepTime = "10 min"
        d.cookTime = "15 min"
        d.servings = "4"
        d.ingredients = "2 eggs\n1 cup flour"
        d.directions = "Whisk\nFry"
        d.categories = "breakfast"
        d.body = "Use buttermilk."
        return d
    }

    func testEveryRecipeFieldComesBackFromDisk() {
        let draft = recipe()
        ComposerDraftStore(directory: directory).save(draft, cover: nil, account: "acct")
        let reopened = ComposerDraftStore(directory: directory)
        XCTAssertEqual(reopened.drafts(.recipe, account: "acct"), [draft])
    }

    func testPollOptionsAndClosingComeBack() {
        var poll = ComposerDraft(kind: .poll)
        poll.question = "Tea or coffee?"
        poll.options = ["Tea", "Coffee", ""]
        poll.multipleChoice = true
        poll.closing = "Pick a time"
        poll.customEnd = Date(timeIntervalSince1970: 1_800_000_000)
        ComposerDraftStore(directory: directory).save(poll, cover: nil, account: "acct")
        let back = ComposerDraftStore(directory: directory).drafts(.poll, account: "acct")
        XCTAssertEqual(back, [poll])
    }

    func testCoverIsKeptBesideTheDraftAndRemovedWithIt() {
        let store = ComposerDraftStore(directory: directory)
        var article = ComposerDraft(kind: .article)
        article.title = "Hello"
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0x01])
        store.save(article, cover: jpeg, account: "acct")
        let saved = ComposerDraftStore(directory: directory).drafts(.article, account: "acct")[0]
        XCTAssertTrue(saved.hasCover)
        XCTAssertEqual(store.cover(for: saved, account: "acct"), jpeg)

        store.save(saved, cover: nil, account: "acct")
        let cleared = store.drafts(.article, account: "acct")[0]
        XCTAssertFalse(cleared.hasCover)
        XCTAssertNil(store.cover(for: saved, account: "acct"))

        store.save(cleared, cover: jpeg, account: "acct")
        store.delete(id: cleared.id, account: "acct")
        XCTAssertNil(store.cover(for: saved, account: "acct"))
        XCTAssertEqual(store.drafts(.article, account: "acct"), [])
    }

    func testSavingAgainReplacesTheSameDraft() {
        let store = ComposerDraftStore(directory: directory)
        var draft = recipe()
        store.save(draft, cover: nil, account: "acct")
        draft.title = "Better pancakes"
        store.save(draft, cover: nil, account: "acct")
        XCTAssertEqual(store.drafts(.recipe, account: "acct").map(\.title), ["Better pancakes"])
    }

    func testKindsAndAccountsAreKeptApart() {
        let store = ComposerDraftStore(directory: directory)
        store.save(recipe(), cover: nil, account: "one")
        XCTAssertEqual(store.drafts(.article, account: "one"), [])
        XCTAssertEqual(store.drafts(.recipe, account: "two"), [])
        XCTAssertEqual(store.drafts(.recipe, account: "one").count, 1)
    }

    func testNewestFirst() {
        let store = ComposerDraftStore(directory: directory)
        var old = ComposerDraft(kind: .article)
        old.title = "Old"
        old.updatedAt = Date(timeIntervalSince1970: 100)
        var new = ComposerDraft(kind: .article)
        new.title = "New"
        new.updatedAt = Date(timeIntervalSince1970: 200)
        store.save(old, cover: nil, account: "acct")
        store.save(new, cover: nil, account: "acct")
        XCTAssertEqual(store.drafts(.article, account: "acct").map(\.title), ["New", "Old"])
    }

    func testAnEmptyFormIsNotADraft() {
        XCTAssertFalse(ComposerDraft(kind: .poll).hasContent)
        var closingOnly = ComposerDraft(kind: .poll)
        closingOnly.closing = "1 week"
        XCTAssertFalse(closingOnly.hasContent)
        var spaces = ComposerDraft(kind: .article)
        spaces.title = "   \n"
        XCTAssertFalse(spaces.hasContent)
    }

    func testSavingAnEmptiedDraftDeletesIt() {
        let store = ComposerDraftStore(directory: directory)
        var draft = recipe()
        store.save(draft, cover: nil, account: "acct")
        draft = ComposerDraft(kind: .recipe)
        draft.id = store.drafts(.recipe, account: "acct")[0].id
        store.save(draft, cover: nil, account: "acct")
        XCTAssertEqual(ComposerDraftStore(directory: directory).drafts(.recipe, account: "acct"), [])
    }

    func testPreviewFallsBackWhenUntitled() {
        var poll = ComposerDraft(kind: .poll)
        poll.options = ["Tea", " ", "Coffee"]
        XCTAssertEqual(poll.previewTitle, "Untitled poll")
        XCTAssertEqual(poll.previewDetail, "Tea · Coffee")
    }

    func testSameContentIgnoresSaveTime() {
        var a = recipe()
        var b = a
        b.updatedAt = a.updatedAt.addingTimeInterval(60)
        XCTAssertTrue(a.sameContent(as: b))
        a.servings = "6"
        XCTAssertFalse(a.sameContent(as: b))
    }
}
