import XCTest

/// Mac twin of FeedEndOfListTests: the end-of-list footer draws at the bottom
/// of Popular (with a Refresh button: no pull on a Mac) and never on Home.
///
/// Needs Automation Mode on (`automationmodetool enable-automationmode-without-authentication`)
/// and a Nostr Vault Mac app already set up with a TEST account: it drives the
/// app with bundle id MAC_APP_BUNDLE_ID (default com.havenapp.relay), and a
/// Mac app's data lives in its container, so never point it at a Mac that
/// holds a real account. See README.md.
final class FeedEndOfListMacTests: XCTestCase {
    private let bundleID = ProcessInfo.processInfo.environment["MAC_APP_BUNDLE_ID"] ?? "com.havenapp.relay"

    func testFooterDrawsOnPopularAndNotOnHome() {
        let app = XCUIApplication(bundleIdentifier: bundleID)
        app.launch()
        let footer = app.descendants(matching: .any)["feed.endOfList"]

        var found = false
        let deadline = Date().addingTimeInterval(15 * 60)
        while !found && Date() < deadline {
            XCTAssertTrue(pick("Popular", in: app), "could not open Popular")
            found = scrollToEnd(app, until: footer, scrolls: 60)
            if !found { sleep(30) }
        }
        XCTAssertTrue(found, "no end-of-list footer at the bottom of Popular")
        if found {
            XCTAssertTrue(footer.label.contains("That's what's popular from the last day."), "footer copy: \(footer.label)")
            XCTAssertTrue(footer.label.contains("Refresh Feed") || app.buttons["Refresh Feed"].exists, "no Refresh button")
        }

        XCTAssertTrue(pick("Following", in: app), "could not open Home")
        XCTAssertFalse(scrollToEnd(app, until: footer, scrolls: 25), "footer drew on Home")
    }

    private func pick(_ feed: String, in app: XCUIApplication) -> Bool {
        let picker = app.descendants(matching: .any)["feed.picker"]
        guard picker.waitForExistence(timeout: 30) else { return false }
        picker.click(); sleep(1)
        let item = app.menuItems[feed].firstMatch
        guard item.waitForExistence(timeout: 5) else { app.typeKey(.escape, modifierFlags: []); return false }
        item.click(); sleep(6)
        return true
    }

    private func scrollToEnd(_ app: XCUIApplication, until element: XCUIElement, scrolls: Int) -> Bool {
        let list = app.scrollViews.firstMatch
        for _ in 0..<scrolls {
            if element.exists { return true }
            list.scroll(byDeltaX: 0, deltaY: -2000)
        }
        sleep(2)
        return element.exists
    }
}
