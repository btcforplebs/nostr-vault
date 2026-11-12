import XCTest
@testable import MediaLogic

/// The media settings trim (RESEARCH/NV_MEDIA_SETTINGS_TRIM.md, Logen go
/// 2026-11-12), iPhone / iPad / Mac: one Media Servers row and page, three
/// switches cut, one button per action, Autoplay on Feed, no Media & Cache.
final class MediaSettingsTrimTests: XCTestCase {
    private static let app = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.app.appendingPathComponent(path), encoding: .utf8)
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: Self.app.appendingPathComponent(path).path)
    }

    private func count(_ needle: String, in src: String) -> Int {
        src.components(separatedBy: needle).count - 1
    }

    /// Every Swift file the app compiles, for "no one reads it any more".
    private func appSources() throws -> [(path: String, text: String)] {
        let root = Self.app.appendingPathComponent("HavenApp")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertGreaterThan(files.count, 100, "the scan found the app's sources")
        return try files.map { ($0.path, try String(contentsOf: $0, encoding: .utf8)) }
    }

    // MARK: Old saved values

    /// A config saved by an older build loads, and the cut values are not
    /// written back: the first save after launch clears them, once.
    func testOldSavedMediaValuesAreClearedOnSave() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(HavenConfig.default)) as? [String: Any])
        json["disableMediaCache"] = true
        json["cacheTTLDays"] = 30
        json["prefetchProfilePictures"] = false
        json["autoplayVideos"] = false
        let loaded = try JSONDecoder().decode(HavenConfig.self, from: JSONSerialization.data(withJSONObject: json))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(loaded)) as? [String: Any])
        for key in ["disableMediaCache", "cacheTTLDays", "prefetchProfilePictures"] {
            XCTAssertNil(saved[key], "\(key) is not written back")
        }
        XCTAssertEqual(saved["autoplayVideos"] as? Bool, false, "Autoplay is kept: it moved, it was not cut")
    }

    /// Other people's media is kept a fixed week.
    func testMediaIsKeptSevenDays() {
        XCTAssertEqual(HavenConfig.mediaKeepDays, 7)
    }

    func testNoAppCodeReadsTheCutValues() throws {
        for file in try appSources() {
            for name in ["disableMediaCache", "cacheTTLDays", "prefetchProfilePictures", "diskCacheDisabled"] {
                XCTAssertFalse(file.text.contains(name), "\(name) in \(file.path)")
            }
        }
    }

    // MARK: Settings

    func testMediaAndCachePageIsGone() throws {
        XCTAssertFalse(exists("HavenApp/Views/Settings/MediaSettingsView.swift"))
        let settings = try source("HavenApp/Views/Settings/SettingsView.swift")
        XCTAssertFalse(settings.contains("Media & Cache"))
        XCTAssertFalse(settings.contains("case media"))
        XCTAssertFalse(settings.contains("MediaSettingsView"))
    }

    func testAutoplayLivesOnFeed() throws {
        let feed = try source("HavenApp/Views/Settings/FeedSettingsView.swift")
        XCTAssertTrue(feed.contains("$configService.config.autoplayVideos"))
        XCTAssertTrue(feed.contains(".settingInfo(.mediaAutoplay)"))
    }

    func testCutSwitchesHaveNoHelpTopics() throws {
        let help = try source("HavenApp/Models/SettingsHelp.swift")
        for topic in ["mediaDisableCache", "mediaPrefetchAvatars", "mediaCacheTTL", "mediaClearCache"] {
            XCTAssertFalse(help.contains(topic), topic)
        }
    }

    /// Profile pictures are fetched ahead on Wi-Fi, with no switch.
    func testAvatarPrefetchRunsWithoutASwitch() throws {
        let src = try source("HavenApp/Services/ProfilePicturePrefetchService.swift")
        XCTAssertTrue(src.contains("guard isWiFi"), "still Wi-Fi only")
        XCTAssertFalse(src.contains("ConfigService.shared.$config"), "no switch to follow")
        // The iOS target's delegate, not HavenApp/App/iOSAppDelegate.swift (not built).
        let ios = try source("HavenApp-iOS/AppDelegate.swift")
        XCTAssertTrue(ios.contains("ProfilePicturePrefetchService.shared.start()"), "starts on iPhone and iPad")
        let mac = try source("HavenApp/App/AppDelegate.swift")
        XCTAssertTrue(mac.contains("ProfilePicturePrefetchService.shared.start()"), "starts on Mac")
    }

    // MARK: One Media Servers row and page

    func testDashboardHasOneMediaServersRowCountingTheMac() throws {
        let dash = try source("HavenApp/Views/Dashboard/VaultDashboardView.swift")
        XCTAssertEqual(count("BlossomSettingsView()", in: dash), 1)
        XCTAssertFalse(dash.contains("MediaServersPage()"), "the Advanced copy is gone")
        XCTAssertTrue(dash.contains("value: \"\\(config.activeBlossomMirrors.count)\""),
                      "counts what uploads use, the Mac included")
        XCTAssertFalse(dash.contains("config.blossomMirrors.count"))
    }

    /// The one page: list editor, each server's health, and Copy to servers.
    func testMediaServersPageHoldsHealthAndCopy() throws {
        let page = try source("HavenApp/Views/Settings/BlossomSettingsView.swift")
        XCTAssertTrue(page.contains("@StateObject private var health = MediaServersModel()"))
        XCTAssertTrue(page.contains("ServerHealthLine("))
        XCTAssertTrue(page.contains("MediaCopyRows("))
        XCTAssertFalse(page.contains("Mirror Now"), "Import media is on the dashboard")
        XCTAssertFalse(page.contains("runMirror("))
        XCTAssertTrue(page.contains("configService.config.autoMirrorMedia"), "Auto-Mirror stays for now")
        let rows = try source("HavenApp/Views/Dashboard/MediaServersPage.swift")
        XCTAssertFalse(rows.contains("struct MediaServersPage: View"), "no second page")
        XCTAssertTrue(rows.contains("title: \"Copy to servers\""))
    }

    // MARK: One button per action

    func testMacMediaDashboardSheetIsGone() throws {
        XCTAssertFalse(exists("HavenApp/Views/Dashboard/BlossomDashboardView.swift"))
        for file in try appSources() {
            XCTAssertFalse(file.text.contains("BlossomDashboardView"), file.path)
            XCTAssertFalse(file.text.contains("openBlossomDashboard"), file.path)
        }
    }

    /// Import media, clear cache, back up media: one button each, per
    /// platform's dashboard (iPhone/iPad Vault dashboard, Mac relay dashboard).
    func testEachMediaActionHasOneButton() throws {
        // Buttons live in views; Auto-Mirror and moving-in run it from services.
        let sources = try appSources().filter { $0.path.contains("/Views/") }
        let mirrorRuns = sources.filter { $0.text.contains("runMirror(configService:") }.map(\.path)
        XCTAssertEqual(mirrorRuns.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted(),
                       ["DashboardView.swift", "VaultDashboardView.swift"], "Import media")
        let exports = sources.filter { $0.text.contains("exporter.export(.media") }.map { URL(fileURLWithPath: $0.path).lastPathComponent }
        XCTAssertEqual(exports.sorted(), ["DashboardView.swift", "VaultDashboardView.swift"], "Back up media")
        let backup = try source("HavenApp/Views/Settings/BackupSettingsView.swift")
        XCTAssertFalse(backup.contains("Export Media"))
        XCTAssertFalse(backup.contains("exportBlossom"))
        XCTAssertTrue(backup.contains("Import Media"), "restoring a media zip has no other home")
        let clears = sources.filter { $0.text.contains("MediaCacheService.shared.clearCache()") }.map { URL(fileURLWithPath: $0.path).lastPathComponent }
        XCTAssertEqual(clears.sorted(), ["DashboardBreakdowns.swift", "VaultContentsSection.swift"], "Clear cache")
    }
}
