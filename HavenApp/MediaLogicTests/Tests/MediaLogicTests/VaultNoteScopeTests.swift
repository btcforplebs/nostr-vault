import XCTest
@testable import MediaLogic

final class VaultNoteScopeTests: XCTestCase {
    /// The relay tab's note kinds as NostrService lists them.
    private let all = [1, 6, 30023, 1111, 9802, 1068]

    func testNotesDropArticlesAndHighlightsInTheVaultTab() {
        XCTAssertEqual(VaultNoteScope.notes.kinds(from: all, split: true), [1, 6, 1111, 1068])
    }

    func testNotesKeepEveryKindWithoutTheMenu() {
        XCTAssertEqual(VaultNoteScope.notes.kinds(from: all, split: false), Set(all))
    }

    func testArticlesAndHighlightsAreOneKindEach() {
        XCTAssertEqual(VaultNoteScope.articles.kinds(from: all, split: true), [30023])
        XCTAssertEqual(VaultNoteScope.highlights.kinds(from: all, split: true), [9802])
        XCTAssertEqual(VaultNoteScope.articles.kinds(from: all, split: false), [30023])
    }

    func testEveryKindLandsInExactlyOneScope() {
        let scopes = VaultNoteScope.allCases.map { $0.kinds(from: all, split: true) }
        XCTAssertEqual(scopes.reduce(Set<Int>()) { $0.union($1) }, Set(all))
        XCTAssertEqual(scopes.map(\.count).reduce(0, +), all.count)
    }

    func testRecipeTagsMatchCaseInsensitively() {
        XCTAssertTrue(VaultNoteScope.isRecipe(tags: [["t", "ZapCooking"]]))
        XCTAssertTrue(VaultNoteScope.isRecipe(tags: [["d", "x"], ["t", "nostrcooking"]]))
        XCTAssertFalse(VaultNoteScope.isRecipe(tags: [["t", "cooking"]]))
        XCTAssertFalse(VaultNoteScope.isRecipe(tags: [["p", "zapcooking"]]))
        XCTAssertFalse(VaultNoteScope.isRecipe(tags: [["t"]]))
    }

    /// The app's recipe feed and the Vault's Recipes filter must agree.
    func testRecipeTopicsMatchTheRecipeFeed() {
        XCTAssertEqual(VaultNoteScope.recipeTopics, ["zapcooking", "nostrcooking"])
    }
}
