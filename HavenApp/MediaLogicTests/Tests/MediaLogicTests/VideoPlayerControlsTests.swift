import XCTest
@testable import MediaLogic

/// The full-screen player's extras (Logen 2026-11-19: keep our player, add
/// speed, AirPlay, skip, captions and lock-screen controls).
final class VideoPlayerControlsTests: XCTestCase {
    func testSpeedsAndLabels() {
        XCTAssertEqual(VideoPlayerControls.speeds, [0.5, 1, 1.25, 1.5, 2])
        XCTAssertEqual(VideoPlayerControls.speedLabel(1), "1×")
        XCTAssertEqual(VideoPlayerControls.speedLabel(2), "2×")
        XCTAssertEqual(VideoPlayerControls.speedLabel(0.5), "0.5×")
        XCTAssertEqual(VideoPlayerControls.speedLabel(1.25), "1.25×")
    }

    func testSkipStaysInsideTheClip() {
        XCTAssertEqual(VideoPlayerControls.skipTarget(current: 30, by: 10, duration: 60), 40)
        XCTAssertEqual(VideoPlayerControls.skipTarget(current: 4, by: -10, duration: 60), 0, "not before the start")
        XCTAssertEqual(VideoPlayerControls.skipTarget(current: 55, by: 10, duration: 60), 60, "not past the end")
        XCTAssertEqual(VideoPlayerControls.skipTarget(current: 55, by: 10, duration: nil), 65, "length unknown")
        XCTAssertEqual(VideoPlayerControls.skipTarget(current: .nan, by: 10, duration: .nan), 10)
    }

    func testLiveHasNoSpeedOrSkip() {
        XCTAssertFalse(VideoPlayerControls.showsSpeedAndSkip(isLive: true))
        XCTAssertTrue(VideoPlayerControls.showsSpeedAndSkip(isLive: false))
    }

    /// The music player stands aside while a clip holds the lock screen, and
    /// the shared player goes back to 1× wherever full screen lets it go.
    func testLockScreenHandOffAndSpeedReset() throws {
        let music = try source("HavenApp/Services/MusicPlayerService.swift")
        let commands = try XCTUnwrap(music.range(of: "private func configureRemoteCommands() {"))
        let handlers = music[commands.upperBound...].prefix(2000)
        XCTAssertEqual(handlers.components(separatedBy: "guard !VideoNowPlaying.isActive else { return .commandFailed }").count - 1, 6,
                       "every music command handler stands aside")
        XCTAssertTrue(music.contains("func updateNowPlaying() {\n        guard !VideoNowPlaying.isActive else { return }"))
        for path in ["HavenApp/Views/VideoPlayer/FullScreenVideoPlayer.swift", "HavenApp/Views/VideoPlayer/PiPManager.swift"] {
            let text = try source(path)
            XCTAssertTrue(text.contains("player.defaultRate = 1"), path)
            XCTAssertTrue(text.contains("VideoNowPlaying.shared.end(player: player)"), path)
        }
    }

    private func source(_ path: String) throws -> String {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: app.appendingPathComponent(path), encoding: .utf8)
    }
}
