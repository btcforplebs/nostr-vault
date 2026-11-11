import XCTest

/// Underrated's empty screen picks its button from the relay's reason
/// (Logen 2026-11-11: a follows-only web said "Check back later" and offered
/// Refresh, which cannot help). Drives the installed app end to end on a
/// fresh install: first run keeps the web to your follows (depth 2) until
/// the Vault's wider_network job runs, so Underrated must offer Build your
/// wider network; once that job has run, it must not. Read-only npub, no key
/// on the sim. See README.md.
final class UnderratedEmptyStateTests: XCTestCase {
    private let npub = ProcessInfo.processInfo.environment["TOPBAR_NPUB"]
        ?? "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6"
    private let shots = ProcessInfo.processInfo.environment["TOPBAR_SHOTS"]

    func testFollowsOnlyWebOffersBuildYourWiderNetworkAndAWiderWebDoesNot() {
        let app = XCUIApplication(bundleIdentifier: "com.havenapp.relay")
        app.launch()
        setUpReadOnlyIfNeeded(app)
        for _ in 0..<3 where app.buttons["Skip"].exists { app.buttons["Skip"].firstMatch.tap(); sleep(1) }
        dismissGuideCard(app)
        XCTAssertTrue(pick("Underrated", in: app), "could not open Underrated")

        let build = app.buttons["underrated.buildWiderNetwork"]
        let refresh = app.buttons["underrated.refreshFeed"]
        let building = app.descendants(matching: .any)["underrated.buildingWiderNetwork"]

        // The web is follows only: the empty screen says so and offers the job.
        // (The trust graph may still be building first: the screen then
        // reloads Underrated once it is.)
        XCTAssertTrue(waitForEither(build, refresh, timeout: 240), "Underrated never settled on an empty screen")
        shot("1-follows-only")
        XCTAssertTrue(build.exists, "a follows-only web must offer Build your wider network")
        XCTAssertFalse(refresh.exists, "a follows-only web must not offer Refresh Feed")
        XCTAssertTrue(app.staticTexts["Underrated needs your wider web"].exists)
        XCTAssertEqual(build.label, "Build your wider network")

        // Running it shows it running...
        build.tap()
        XCTAssertTrue(building.waitForExistence(timeout: 20), "no running state after Build your wider network")
        shot("2-building")

        // ...and when it ends Underrated is asked again, with the wider web.
        XCTAssertTrue(waitUntilGone(building, timeout: 900), "the wider network never finished")
        sleep(20)
        shot("3-wider-web")
        XCTAssertFalse(build.exists, "a wider web must not offer Build your wider network again")
        XCTAssertFalse(app.staticTexts["Underrated needs your wider web"].exists)
    }

    // MARK: - Driving

    private func shot(_ name: String) {
        if let shots { try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/underrated-\(name).png")) }
    }

    private func waitForEither(_ a: XCUIElement, _ b: XCUIElement, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            dismissGuideCard(XCUIApplication(bundleIdentifier: "com.havenapp.relay"))
            if a.exists || b.exists { return true }
            sleep(2)
        }
        return false
    }

    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if !element.exists { return true }
            sleep(3)
        }
        return false
    }

    /// The "Fill your feed" card comes up on a fresh install with few follows.
    /// It is opaque and centred, so it sits right over Underrated's empty
    /// screen (still there behind it); close it first.
    private func dismissGuideCard(_ app: XCUIApplication) {
        let notNow = app.buttons["Not now"].firstMatch
        if notNow.exists && notNow.isHittable { notNow.tap(); sleep(1) }
    }

    private func feedPicker(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Feed:'")).firstMatch
    }

    private func pick(_ feed: String, in app: XCUIApplication) -> Bool {
        let picker = feedPicker(app)
        guard picker.waitForExistence(timeout: 30) else { return false }
        picker.tap(); sleep(2)
        var item = app.buttons[feed].firstMatch
        if item.exists && !item.isHittable { app.swipeUp(); sleep(1); item = app.buttons[feed].firstMatch }
        guard item.exists && item.isHittable else { return false }
        item.tap(); sleep(6)
        return true
    }

    /// FeedTopBarTests.setUpReadOnlyIfNeeded: bring an account by npub
    /// (read-only) and let setup finish.
    private func setUpReadOnlyIfNeeded(_ app: XCUIApplication) {
        let steps = ["Yes, bring my notes from my relays", "Start import", "Keep it running in the background",
                     "Bring an account", "Continue", "Next", "Not now", "Skip"]
        for _ in 0..<40 {
            if feedPicker(app).exists { return }
            let field = app.textFields.firstMatch
            if field.exists, field.placeholderValue?.contains("npub") == true,
               (field.value as? String ?? "").contains("npub1") == false {
                field.tap(); field.typeText(npub); sleep(1)
            }
            var tapped = false
            for label in steps {
                let b = app.buttons[label].firstMatch
                if b.exists && b.isHittable && b.isEnabled { b.tap(); tapped = true; break }
            }
            sleep(tapped ? 3 : 5)
        }
        XCTAssertTrue(feedPicker(app).waitForExistence(timeout: 30), "setup did not reach the feed")
    }
}
