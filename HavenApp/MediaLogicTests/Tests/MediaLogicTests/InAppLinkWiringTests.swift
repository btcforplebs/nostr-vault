import XCTest

/// The views pull in the whole app and can't be built here, so this reads
/// their source. A link someone wrote or shared opens in the in-app browser
/// (`PlatformURL.openLink` / `InAppBrowser.route`); only the app's own
/// hand-offs (a signer app, the Mac's local web UI, the browser's own
/// "Open in Safari") go straight to the system (Logen, 2026-11-11).
final class InAppLinkWiringTests: XCTestCase {
    private var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HavenApp")
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private static let systemOpens = ["PlatformURL.open(", "UIApplication.shared.open(", "NSWorkspace.shared.open("]

    /// Files allowed a direct system open, and why.
    private static let systemAllowed: Set<String> = [
        "Views/PlatformCompat.swift",          // the helpers themselves
        "Views/WebViewer/InAppBrowser.swift",  // the browser's "Open in Safari" and non-web links
        "Views/Components/SignInWithClaveView.swift", // hands a request to the signer app
        "Views/Dashboard/DashboardView.swift", // Mac: opens this Mac's own relay web UI
    ]

    /// Every Swift file under Views/ that opens a URL with the system directly.
    private func filesWithSystemOpens() throws -> Set<String> {
        let views = appRoot.appendingPathComponent("Views")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil))
        var found: Set<String> = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if Self.systemOpens.contains(where: text.contains) {
                found.insert("Views/" + url.path.replacingOccurrences(of: views.path + "/", with: ""))
            }
        }
        return found
    }

    func testOnlyAppHandoffsOpenTheSystemDirectly() throws {
        let found = try filesWithSystemOpens()
        // Positive control: the scan does see the known system openers.
        XCTAssertTrue(found.contains("Views/PlatformCompat.swift"))
        XCTAssertTrue(found.contains("Views/WebViewer/InAppBrowser.swift"))
        XCTAssertEqual(found.subtracting(Self.systemAllowed), [],
                       "user content should open with PlatformURL.openLink, not the system")
    }

    func testEachSurfaceOpensTheInAppBrowser() throws {
        let surfaces = [
            "Views/Components/LinkPreviewCard.swift",       // preview card + domain-only card
            "Views/Components/OpenInWebButton.swift",       // "Open in zap.cooking" and friends
            "Views/Articles/ArticleReaderView.swift",       // the reader's "Open in <site>"
            "Views/Articles/GatedArticleBody.swift",        // "Open in Fanfares"
            "Views/MarketplaceFeedViews.swift",             // "Buy on Plebeian"
            "Views/Profile/ProfileContent+Header.swift",    // website chip
            "Views/TrustWeb/TrustWebView+TrustCard.swift",  // a person's web button
            "Views/Music/MusicSheetHost.swift",             // "Open on Wavlake"
        ]
        for path in surfaces {
            let src = try source(path)
            XCTAssertTrue(src.contains("PlatformURL.openLink("), "\(path) opens its link in the in-app browser")
            XCTAssertFalse(src.contains("openURL(url)"), "\(path) does not lean on an inherited openURL")
        }
    }

    func testDMLinksAreTappableAndRouted() throws {
        let src = try source("Views/DMThreadView.swift")
        XCTAssertTrue(src.contains("ProfileBioLinks.attributed("), "a DM's links are marked")
        XCTAssertTrue(src.contains("OpenURLAction { InAppBrowser.route($0) }"), "a DM link tap goes to the browser")
    }

    func testOpenLinkUsesTheBrowserRules() throws {
        let src = try source("Views/PlatformCompat.swift")
        let start = try XCTUnwrap(src.range(of: "static func openLink(_ url: URL)"))
        let body = src[start.upperBound...].prefix(400)
        XCTAssertTrue(body.contains("FipsURL.route(url, inApp: InAppBrowser.opensLinksInApp) == .system"))
        XCTAssertTrue(body.contains("InAppBrowser.route(url)"))
    }
}
