import XCTest

/// Underrated, Popular and Catch Up are fixed sets: the list ends. A footer
/// under the last note says so (Logen 2026-11-11: Underrated ran out onto
/// the background and looked broken). Home pages on, so it never draws there.
/// Drives the installed app read-only, like FeedTopBarTests; see README.md.
final class FeedEndOfListTests: XCTestCase {
    private let npub = ProcessInfo.processInfo.environment["TOPBAR_NPUB"]
        ?? "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6"
    private let shots = ProcessInfo.processInfo.environment["TOPBAR_SHOTS"]

    func testFooterDrawsOnPopularAndNotOnHome() {
        let app = XCUIApplication(bundleIdentifier: "com.havenapp.relay")
        app.launch()
        FeedUITestDriving.setUpReadOnlyIfNeeded(app, npub: npub)
        for _ in 0..<3 where app.buttons["Skip"].exists { app.buttons["Skip"].firstMatch.tap(); sleep(1) }

        // Popular, not Underrated: Underrated needs the trust graph and on a
        // read-only sim can stay empty (its empty state, no footer) for good.
        // Popular can still take a few minutes the first time.
        let footer = app.descendants(matching: .any)["feed.endOfList"]
        var found = false
        let deadline = Date().addingTimeInterval(15 * 60)
        while !found && Date() < deadline {
            XCTAssertTrue(FeedUITestDriving.pick("Popular", in: app), "could not open Popular")
            found = scrollToEnd(app, until: footer, swipes: 60)
            if !found { sleep(30) }
        }
        shot("Popular end")
        XCTAssertTrue(found, "no end-of-list footer at the bottom of Popular")
        if found {
            XCTAssertTrue(footer.label.contains("That's what's popular from the last day."),
                          "footer copy: \(footer.label)")
        }

        XCTAssertTrue(FeedUITestDriving.pick("Following", in: app), "could not open Home")
        XCTAssertFalse(scrollToEnd(app, until: footer, swipes: 25), "footer drew on Home")
        shot("Home scrolled")
    }

    /// Swipes down the list until `element` shows (rows are lazy, so the
    /// footer exists only once near the end) or the swipes run out.
    private func scrollToEnd(_ app: XCUIApplication, until element: XCUIElement, swipes: Int) -> Bool {
        for _ in 0..<swipes {
            if element.exists { return true }
            app.swipeUp(velocity: .fast)
        }
        sleep(2)
        return element.exists
    }

    private func shot(_ name: String) {
        guard let shots else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png"))
    }
}
