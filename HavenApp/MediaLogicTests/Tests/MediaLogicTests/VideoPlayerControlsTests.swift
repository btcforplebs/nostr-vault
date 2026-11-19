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

    /// Tron's #2255 review: a clip closed while it loads never takes the
    /// lock screen, and the music works its buttons out again on hand-back
    /// instead of getting a stale snapshot.
    func testClosedWhileLoadingAndFreshMusicButtons() throws {
        let full = try source("HavenApp/Views/VideoPlayer/FullScreenVideoPlayer.swift")
        XCTAssertEqual(full.components(separatedBy: "guard stillOnScreen else { return }").count - 1, 2,
                       "both the URL and the mesh path check after their await")
        for begin in ["guard stillOnScreen else { return }\n            self.player = cachedPlayer",
                      "guard stillOnScreen else { return }\n        player = meshPlayer"] {
            XCTAssertTrue(full.contains(begin), begin)
        }
        let now = try source("HavenApp/Services/VideoNowPlaying.swift")
        XCTAssertFalse(now.contains("savedEnabled"))
        XCTAssertTrue(now.contains("MusicPlayerService.shared.refreshRemoteCommandStates()"))
        let music = try source("HavenApp/Services/MusicPlayerService.swift")
        XCTAssertEqual(music.components(separatedBy: "nextTrackCommand.isEnabled").count - 1, 1,
                       "Next is set in one place, which stands aside while a clip holds the lock screen")
        XCTAssertTrue(music.contains("func refreshRemoteCommandStates() {\n        guard !VideoNowPlaying.isActive else { return }"))
    }

    private func source(_ path: String) throws -> String {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: app.appendingPathComponent(path), encoding: .utf8)
    }
}
