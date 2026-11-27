import XCTest

/// The profile's kind tabs: three on the bar and a fourth "More" button that
/// lists the other kinds (Logen 2026-11-27). Drives the installed app on your
/// own profile (Profile tab), read-only, with a throwaway npub passed as
/// `TEST_RUNNER_TOPBAR_NPUB`. See README.md.
final class ProfileTabsTests: XCTestCase {
    private let npub = ProcessInfo.processInfo.environment["TOPBAR_NPUB"]
        ?? "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6"
    private let shots = ProcessInfo.processInfo.environment["TOPBAR_SHOTS"]

    func testThreeKindTabsAndMoreListsTheRest() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.havenapp.relay")
        app.launch()
        FeedUITestDriving.setUpReadOnlyIfNeeded(app, npub: npub)
        for _ in 0..<3 where app.buttons["Skip"].exists { app.buttons["Skip"].firstMatch.tap(); sleep(1) }
        let notNow = app.buttons["Not now"].firstMatch
        if notNow.exists && notNow.isHittable { notNow.tap(); sleep(1) }

        let profileTab = app.buttons["Profile"].firstMatch
        XCTAssertTrue(profileTab.waitForExistence(timeout: 30), "no Profile tab")
        profileTab.tap()

        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 30), "no More tab on the profile")
        for kind in ["Notes", "Media", "Replies"] {
            XCTAssertTrue(app.buttons[kind].firstMatch.exists, "\(kind) should be on the bar")
        }
        for kind in ["Reposts", "Tagged"] {
            XCTAssertFalse(app.buttons[kind].firstMatch.exists, "\(kind) should be behind More")
        }

        more.tap(); sleep(1)
        let tagged = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Tagged'")).firstMatch
        XCTAssertTrue(tagged.waitForExistence(timeout: 5), "More should list Tagged")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reposts'")).firstMatch.exists,
                      "More should list Reposts")
        shot("1-more-open")
        tagged.tap(); sleep(1)

        // The fourth tab now says what is under it.
        let picked = app.buttons["Tagged"].firstMatch
        XCTAssertTrue(picked.waitForExistence(timeout: 5), "the fourth tab should show the kind picked")
        XCTAssertTrue(picked.isSelected, "the picked kind should read as selected")
        XCTAssertFalse(app.buttons["More"].firstMatch.exists)
        shot("2-tagged-picked")
    }

    private func shot(_ name: String) {
        if let shots { try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/profiletabs-\(name).png")) }
    }
}
