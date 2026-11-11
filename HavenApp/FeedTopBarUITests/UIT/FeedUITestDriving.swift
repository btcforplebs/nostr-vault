import XCTest

/// Opening feeds and first-run setup, shared by the feed UI tests.
enum FeedUITestDriving {
    static func feedPicker(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Feed:'")).firstMatch
    }

    static func pick(_ feed: String, in app: XCUIApplication) -> Bool {
        let picker = feedPicker(app)
        guard picker.waitForExistence(timeout: 30) else { XCTFail("no feed picker"); return false }
        picker.tap(); sleep(2)
        var item = app.buttons[feed].firstMatch
        if item.exists && !item.isHittable { app.swipeUp(); sleep(1); item = app.buttons[feed].firstMatch }
        guard item.exists && item.isHittable else {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap(); sleep(1)
            return false
        }
        item.tap(); sleep(6)
        return true
    }

    /// A fresh install: bring an account by npub (read-only) and let setup
    /// finish. Does nothing once the feed is up.
    static func setUpReadOnlyIfNeeded(_ app: XCUIApplication, npub: String) {
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
