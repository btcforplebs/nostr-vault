import XCTest

/// "Show a code for another device" on the iPhone sign-in step (Logen
/// 2026-11-23: the nostrconnect QR everywhere, like web). Needs a FRESH
/// install: it walks the front door to "Bring an account", opens the signer
/// options and checks the QR is on screen without leaving for Clave. Nothing
/// is signed or posted: the code is a throwaway client key waiting on relays.
/// Screenshots go to TEST_RUNNER_SIGNIN_SHOTS when set.
final class SignInQRTests: XCTestCase {
    private let shots = ProcessInfo.processInfo.environment["SIGNIN_SHOTS"]

    private func shot(_ name: String) {
        guard let shots else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png"))
    }

    func testOtherDeviceCodeShowsOnTheKeyStep() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.havenapp.relay")
        app.launch()

        let bring = app.buttons["Bring an account"].firstMatch
        XCTAssertTrue(bring.waitForExistence(timeout: 60), "front door not shown: needs a fresh install")
        bring.tap()

        let useSigner = app.buttons["Use a signer app"].firstMatch
        XCTAssertTrue(useSigner.waitForExistence(timeout: 20), "no signer option on the key step")
        useSigner.tap()

        // The same-phone hand-off stays.
        XCTAssertTrue(app.buttons["Sign in with Clave"].waitForExistence(timeout: 10))
        let show = app.buttons["showNostrConnectQR"].firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 10), "no 'Show a code for another device' button")
        show.tap()

        let code = app.descendants(matching: .any)["nostrConnectQR"].firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 10), "no QR after tapping Show a code")
        XCTAssertGreaterThan(code.frame.width, 150)
        // Still here, not handed to Clave.
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.buttons["Copy link"].exists)
        shot("iphone-signin-qr")

        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(show.waitForExistence(timeout: 10), "Cancel did not go back")
        XCTAssertFalse(code.exists)
    }
}
