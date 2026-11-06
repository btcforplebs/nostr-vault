import XCTest
@testable import MediaLogic

/// The copy screens after Logen's iPad ← Mac run (2026-11-06): a moving
/// bar and counts while saving, Skip that goes in while saving and the relay
/// catch-up carry on, and the local-network prompt before the scan.
final class CopySavingTests: XCTestCase {
    private func line(_ s: String) throws -> MeshCopyV2.Progress {
        try XCTUnwrap(MeshCopyV2.parseLine("COPY " + s))
    }

    func testSavingAndCatchUpSlide() throws {
        XCTAssertTrue(CopySaving.slides(try line("stage=restoring part=notes bytes=0/5000 items=0/0 source=mesh")))
        XCTAssertTrue(CopySaving.slides(try line("stage=restoring part=media bytes=0/0 items=25/300 source=mesh")))
        XCTAssertTrue(CopySaving.slides(try line("stage=relays part=- bytes=0/0 items=0/0 source=relays")))
        XCTAssertFalse(CopySaving.slides(try line("stage=fetching part=notes bytes=10/5000 items=0/0 source=mesh")))
        XCTAssertFalse(CopySaving.slides(try line("stage=done part=- bytes=0/0 items=9/9 source=mesh")))
    }

    /// Skip is there for as long as the bar slides (saving and the catch-up).
    func testSkipWhileSavingAndCatchingUp() throws {
        XCTAssertTrue(CopySaving.canSkip(try line("stage=relays part=- bytes=0/0 items=0/0 source=relays")))
        XCTAssertTrue(CopySaving.canSkip(try line("stage=restoring part=notes bytes=0/5000 items=0/0 source=mesh")))
        XCTAssertTrue(CopySaving.canSkip(try line("stage=restoring part=media bytes=0/0 items=25/300 source=mesh")))
        XCTAssertFalse(CopySaving.canSkip(try line("stage=fetching part=notes bytes=10/5000 items=0/0 source=mesh")))
    }

    /// The copy is in at the relay catch-up: setup goes in then, not after
    /// the catch-up's `done` (iPad ← Mac, 2026-11-06).
    func testCopyFinishedAtTheCatchUp() throws {
        XCTAssertTrue(CopySaving.copyFinished(try line("stage=relays part=- bytes=0/0 items=0/0 source=relays")))
        XCTAssertTrue(CopySaving.copyFinished(try line("stage=done part=- bytes=0/0 items=9/9 source=mesh")))
        XCTAssertFalse(CopySaving.copyFinished(try line("stage=restoring part=media bytes=0/0 items=25/300 source=mesh")))
        XCTAssertFalse(CopySaving.copyFinished(try line("stage=failed part=- bytes=0/0 items=0/0 source=mesh error=hash_mismatch")))
    }

    /// Saving sends no lines for minutes: never a stall. Fetching can be.
    func testSavingNeverStalls() throws {
        XCTAssertFalse(CopySaving.mayStall(try line("stage=restoring part=notes bytes=0/5000 items=0/0 source=mesh")))
        XCTAssertFalse(CopySaving.mayStall(try line("stage=relays part=- bytes=0/0 items=0/0 source=relays")))
        XCTAssertTrue(CopySaving.mayStall(try line("stage=fetching part=notes bytes=10/5000 items=0/0 source=mesh")))
        XCTAssertTrue(CopySaving.mayStall(nil))
    }

    func testCountsLine() throws {
        let notes = try line("stage=restoring part=notes bytes=0/5000 items=0/0 source=mesh")
        let media = try line("stage=restoring part=media bytes=0/0 items=340/1200 source=mesh")
        XCTAssertNil(CopySaving.countsLine(notes: nil, progress: notes))
        XCTAssertEqual(CopySaving.countsLine(notes: 12345, progress: notes), "12,345 notes")
        XCTAssertEqual(CopySaving.countsLine(notes: 1, progress: notes), "1 note")
        XCTAssertEqual(CopySaving.countsLine(notes: 12345, progress: media), "12,345 notes · 340 of 1,200 photos and videos")
        XCTAssertEqual(CopySaving.countsLine(notes: nil, progress: media), "340 of 1,200 photos and videos")
        // Items on any other line are not photos.
        let notesItems = try line("stage=restoring part=notes bytes=0/5000 items=3/9 source=mesh")
        XCTAssertEqual(CopySaving.countsLine(notes: 7, progress: notesItems), "7 notes")
    }

    func testRouterAddressIsPrivateOnly() {
        XCTAssertEqual(LocalNetworkPermission.routerFor("192.168.1.42"), "192.168.1.1")
        XCTAssertEqual(LocalNetworkPermission.routerFor("10.44.194.35"), "10.44.194.1")
        XCTAssertEqual(LocalNetworkPermission.routerFor("172.20.3.9"), "172.20.3.1")
        XCTAssertNil(LocalNetworkPermission.routerFor("172.32.3.9"))
        XCTAssertNil(LocalNetworkPermission.routerFor("8.8.8.8"))
        XCTAssertNil(LocalNetworkPermission.routerFor("169.254.1.2"))
        XCTAssertNil(LocalNetworkPermission.routerFor("nope"))
    }

    // MARK: Wiring (source checks)

    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repo.appendingPathComponent(path), encoding: .utf8)
    }

    /// The saved total counts every store, every kind (it sat at 342, the
    /// public kind-1 count, while 34k were saved on the iPad).
    func testSavedTotalCountsEveryStore() throws {
        XCTAssertEqual(CopySaving.storePaths, ["", "inbox", "private", "chat"])
        let view = try source("HavenApp/HavenApp/Views/SetupWizard/CopySavingProgress.swift")
        XCTAssertTrue(view.contains("RelayCounter.count([\"all\": [:]]"))
        XCTAssertFalse(view.contains("\"kinds\": [1]"))
        XCTAssertTrue(view.contains("RelayCountSession.countable("))
    }

    /// After a copy setup goes straight in; the relay check can always be skipped.
    func testStraightInAfterACopy() throws {
        let wizard = try source("HavenApp/HavenApp/Views/SetupWizard/SetupWizardView.swift")
        let done = try XCTUnwrap(wizard.range(of: "private func bringItOverDone() {"))
        let body = wizard[done.upperBound...].prefix(120)
        XCTAssertTrue(body.contains("saveAndComplete()"))
        XCTAssertFalse(body.contains("go(to:"))
        XCTAssertTrue(wizard.contains("}, onSkip: { saveAndComplete() })"))
        let check = try source("HavenApp/HavenApp/Views/SetupWizard/RelayCheckStep.swift")
        XCTAssertTrue(check.contains("Button(\"Skip\", action: onSkip)"))
    }

    /// The copy step asks for the local network when it opens, and shows
    /// the sliding saving view with Skip wired.
    func testCopyStepWiring() throws {
        let step = try source("HavenApp/HavenApp/Views/SetupWizard/BringItOverStep.swift")
        XCTAssertTrue(step.contains(".onAppear { LocalNetworkPermission.ask() }"))
        XCTAssertTrue(step.contains("onSkip: done)"))
        XCTAssertTrue(step.contains("if let progress, CopySaving.slides(progress) {"))
        XCTAssertTrue(step.contains("CopySavingProgress(progress: progress, onSkip: onSkip)"))
        XCTAssertTrue(step.contains("if CopySaving.copyFinished(p) { return done() }"))
        XCTAssertTrue(step.contains("CopySaving.mayStall(copy.progress)"))
    }
}
