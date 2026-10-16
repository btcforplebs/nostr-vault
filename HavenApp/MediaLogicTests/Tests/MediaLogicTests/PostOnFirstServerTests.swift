import XCTest
@testable import MediaLogic

/// A post needs one Blossom server to have the file; the others must never
/// hold it (Logen, 2026-10-16).
final class PostOnFirstServerTests: XCTestCase {
    private static let hang: UInt64 = 5_000_000_000  // longer than the 2 s the post may take

    /// One server answers in 50 ms, another never does (a dead host). The post
    /// gets the first server's link right away.
    func testAHangingServerDoesNotHoldThePost() async {
        let started = Date()
        let url = await FirstAnswer.first([
            { try? await Task.sleep(nanoseconds: Self.hang); return "hung" },
            { try? await Task.sleep(nanoseconds: 50_000_000); return "https://blossom.nostr.build/x" },
        ])
        XCTAssertEqual(url, "https://blossom.nostr.build/x")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    /// A failing server (nil) doesn't count as an answer; the next one does.
    func testAFailedServerIsPassedOver() async {
        let url = await FirstAnswer.first([
            { nil },
            { try? await Task.sleep(nanoseconds: 30_000_000); return "second" },
        ])
        XCTAssertEqual(url, "second")
    }

    func testEveryServerFailingIsNil() async {
        let none: String? = await FirstAnswer.first([{ nil }, { nil }, { nil }])
        XCTAssertNil(none)
        let empty: String? = await FirstAnswer.first([])
        XCTAssertNil(empty)
    }

    /// The slower servers still finish in the background, and the temp file
    /// is only let go once all of them have.
    func testTheOthersFinishInTheBackground() async {
        let late = expectation(description: "slower server finished")
        let allDone = expectation(description: "all done")
        let url = await FirstAnswer.first([
            { "fast" },
            { try? await Task.sleep(nanoseconds: 200_000_000); return "slow" },
        ], onLate: { index, result in
            if index == 1, result == "slow" { late.fulfill() }
        }, onAllDone: { allDone.fulfill() })
        XCTAssertEqual(url, "fast")
        await fulfillment(of: [late, allDone], timeout: 2, enforceOrder: true)
    }

    // MARK: - Server addresses

    func testNostrBuildWebsiteAddressesUploadToItsBlossomServer() {
        for typed in ["https://nostr.build", "https://nostr.build/", "https://logen.nostr.build", "https://image.nostr.build", " https://NOSTR.BUILD "] {
            XCTAssertEqual(HavenConfig.blossomUploadServer(typed), "https://blossom.nostr.build", typed)
        }
        XCTAssertEqual(HavenConfig.blossomUploadServer("https://blossom.nostr.build"), "https://blossom.nostr.build")
    }

    func testDeadNostrBandIsSkipped() {
        XCTAssertNil(HavenConfig.blossomUploadServer("https://blossom.nostr.band"))
        XCTAssertNil(HavenConfig.blossomUploadServer("https://nostr.band"))
    }

    func testOtherServersAreLeftAlone() {
        for typed in ["https://blossom.primal.net", "https://npub1abc.blossom.band", "https://notnostr.build.example", "http://192.168.1.20:3355"] {
            XCTAssertEqual(HavenConfig.blossomUploadServer(typed), typed)
        }
    }

    func testActiveMirrorsMapAndDeduplicate() {
        var config = HavenConfig()
        config.blossomMirrors = ["https://logen.nostr.build", "https://blossom.nostr.band", "https://blossom.nostr.build", "https://blossom.primal.net"]
        XCTAssertEqual(config.activeBlossomMirrors, ["https://blossom.nostr.build", "https://blossom.primal.net"])
    }
}
