import XCTest

/// The feed's top pills sit on the screen edges on every feed type, open and
/// folded (Logen 2026-11-08: the right pill landed about 3/4 across on some
/// feeds). Drives the installed app; a fresh install is set up read-only
/// with a public npub, so nothing it taps can post. See README.md.
final class FeedTopBarTests: XCTestCase {
    /// fiatjaf, read-only: an npub with a busy feed, no key on the sim.
    private let npub = ProcessInfo.processInfo.environment["TOPBAR_NPUB"]
        ?? "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6"
    private let shots = ProcessInfo.processInfo.environment["TOPBAR_SHOTS"]
    /// How far in from the screen edge a pill's outer edge may sit: the
    /// bar's 16 pt margin plus room for the glass.
    private let edgeSlack: CGFloat = 28

    /// Every feed type but diVines (Reels has no filter pill to place).
    /// TOPBAR_FEEDS (comma separated) checks a few instead.
    private let feeds = ProcessInfo.processInfo.environment["TOPBAR_FEEDS"]?.split(separator: ",").map(String.init) ?? ["Following", "Discover", "Global", "Hashtags", "Popular", "Catch Up", "Underrated",
                         "Media", "Articles", "Recipes", "Marketplace", "Live", "Polls", "Music"]

    func testPillsSitOnTheEdgesOnEveryFeed() {
        let app = XCUIApplication(bundleIdentifier: "com.havenapp.relay")
        app.launch()
        setUpReadOnlyIfNeeded(app)
        for _ in 0..<3 where app.buttons["Skip"].exists { app.buttons["Skip"].firstMatch.tap(); sleep(1) }

        var checked = 0
        for feed in feeds {
            guard pick(feed, in: app) else { continue }
            checkEdges(app, "\(feed) open")
            if fold(app) { checkEdges(app, "\(feed) folded") }
            unfold(app)
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, min(10, feeds.count), "too few feeds could be opened to check")
    }

    // MARK: - Checks

    private func checkEdges(_ app: XCUIApplication, _ state: String) {
        sleep(1)
        if let shots { try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(state).png")) }
        let width = app.windows.firstMatch.frame.width
        let picker = feedPicker(app)
        XCTAssertTrue(picker.exists, "\(state): no feed picker")
        let barBottom = picker.frame.maxY + 4
        XCTAssertLessThanOrEqual(picker.frame.minX, edgeSlack, "\(state): left pill not on the left edge (\(picker.frame))")
        // The right pill: the controls on the picker's row, other than the
        // picker. Folded, the full row shrinks into the circle on the same
        // trailing edge, and feeds with no layouts keep their filter menu
        // there, which accessibility may report as a menu or pop-up button.
        // Frames only: isHittable flickers while the fold settles.
        let candidates = app.descendants(matching: .any).matching(NSPredicate(
            format: "elementType IN %@",
            [XCUIElement.ElementType.button, .menuButton, .popUpButton].map { $0.rawValue }))
        let right = candidates.allElementsBoundByIndex.filter {
            let f = $0.frame
            return f.width > 0 && f.minX.isFinite && f.midY > picker.frame.minY && f.midY < barBottom
                && f.minX > picker.frame.maxX && !$0.label.hasPrefix("Feed:")
        }
        guard let rightmost = right.map(\.frame.maxX).max() else {
            if let shots { try? app.debugDescription.write(toFile: "\(shots)/\(state).txt", atomically: true, encoding: .utf8) }
            return XCTFail("\(state): no right pill buttons on the bar row")
        }
        XCTAssertGreaterThanOrEqual(rightmost, width - edgeSlack,
                                    "\(state): right pill ends at \(rightmost) of \(width), not on the right edge")
    }

    // MARK: - Driving

    private func feedPicker(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Feed:'")).firstMatch
    }

    private func pick(_ feed: String, in app: XCUIApplication) -> Bool {
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

    /// Drags the feed up to fold the bars. False when the feed is too short
    /// to scroll (nothing folded).
    @discardableResult
    private func fold(_ app: XCUIApplication) -> Bool {
        let before = feedPicker(app).frame.width
        let w = app.windows.firstMatch
        w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            .press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
        sleep(2)
        return feedPicker(app).frame.width < before - 20
    }

    private func unfold(_ app: XCUIApplication) {
        let w = app.windows.firstMatch
        w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            .press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
        sleep(2)
    }

    /// A fresh install: bring an account by npub (read-only) and let setup
    /// finish. Does nothing once the feed is up.
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
