import XCTest

/// Search results must sit in lazy stacks. A common word returns 1000+
/// people and 100 notes; in an eager `VStack` every row was rebuilt on each
/// streamed update, and the field froze after a couple of characters.
/// The view pulls in SwiftUI and the whole app and can't be built here, so
/// this reads its source.
final class SearchResultsLazyStackTests: XCTestCase {
    private func resultsSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HavenApp/Views/Search/SearchView+Results.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testEveryResultListIsInALazyStack() throws {
        let lines = try resultsSource().components(separatedBy: "\n")
        var lists = 0
        for (i, line) in lines.enumerated() where line.contains("ForEach(searchResults.") {
            lists += 1
            let opener = lines[..<i].last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
            XCTAssertTrue(opener.contains("LazyVStack("), "line \(i + 1) is not in a LazyVStack: \(opener)")
        }
        XCTAssertEqual(lists, 4, "expected the users, notes, hashtags and links lists")
    }

    func testTheResultsScrollStackIsLazy() throws {
        let source = try resultsSource()
        guard let body = source.range(of: "var resultsContent: some View {") else {
            return XCTFail("resultsContent not found")
        }
        let after = source[body.upperBound...]
        guard let scroll = after.range(of: "ScrollView {") else { return XCTFail("no ScrollView") }
        let firstStack = after[scroll.upperBound...].range(of: "VStack(")
        XCTAssertNotNil(firstStack)
        if let firstStack {
            XCTAssertTrue(after[..<firstStack.lowerBound].hasSuffix("Lazy"), "the ScrollView's stack is eager")
        }
    }
}
