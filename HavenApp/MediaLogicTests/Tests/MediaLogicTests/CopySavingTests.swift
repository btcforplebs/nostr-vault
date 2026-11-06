import XCTest
@testable import MediaLogic

/// The copy screens after Logen's iPad ← Mac run (2026-11-06): a moving
/// bar and counts while saving, Skip on the relay catch-up, and the
/// local-network prompt before the scan.
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

    func testSkipOnlyOnTheCatchUp() throws {
        XCTAssertTrue(CopySaving.canSkip(try line("stage=relays part=- bytes=0/0 items=0/0 source=relays")))
        XCTAssertFalse(CopySaving.canSkip(try line("stage=restoring part=notes bytes=0/5000 items=0/0 source=mesh")))
    }

    func testCountsLine() throws {
        let notes = try line("stage=restoring part=notes bytes=0/5000 items=0/0 source=mesh")
        let media = try line("stage=restoring part=media bytes=0/0 items=340/1200 source=mesh")
        XCTAssertNil(CopySaving.countsLine(notes: nil, progress: notes))
        XCTAssertEqual(CopySaving.countsLine(notes: 12345, progress: notes), "12,345 notes")
        XCTAssertEqual(CopySaving.countsLine(notes: 1, progress: notes), "1 note")
        XCTAssertEqual(CopySaving.countsLine(notes: 12345, progress: media), "12,345 notes · 340 of 1,200 photos and videos")
        XCTAssertEqual(CopySaving.countsLine(notes: nil, progress: media), "340 of 1,200 photos and videos")
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

    /// Skip cancels the engine's own catch-up job, by the engine's name for it.
    func testSkipCancelsTheEnginesSetupJob() throws {
        let go = try source("haven-go/import_jobs.go")
        XCTAssertTrue(go.contains("jobSetup        = \"\(CopySaving.relayJob)\""), "the engine's catch-up job name")
        let service = try source("HavenApp/HavenApp/Services/Relay/MeshCopyV2Service.swift")
        let skip = try XCTUnwrap(service.range(of: "func skipRelays() {"))
        let body = service[skip.upperBound...].prefix(400)
        XCTAssertTrue(body.contains("CopySaving.relayJob.withCString { CancelImportJobC("))
        XCTAssertTrue(body.contains("CopySaving.canSkip"), "only while the catch-up runs")
    }

    /// The copy step asks for the local network when it opens, and shows
    /// the sliding saving view with Skip wired.
    func testCopyStepWiring() throws {
        let step = try source("HavenApp/HavenApp/Views/SetupWizard/BringItOverStep.swift")
        XCTAssertTrue(step.contains(".onAppear { LocalNetworkPermission.ask() }"))
        XCTAssertTrue(step.contains("onSkipRelays: { copy.skipRelays() }"))
        XCTAssertTrue(step.contains("if let progress, CopySaving.slides(progress) {"))
        XCTAssertTrue(step.contains("CopySavingProgress(progress: progress, onSkip: onSkipRelays)"))
    }
}
