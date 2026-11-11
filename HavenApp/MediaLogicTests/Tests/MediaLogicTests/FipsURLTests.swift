import XCTest
@testable import MediaLogic

/// The in-app browser's `.fips` addresses: what opens over the mesh, what
/// opens on the web, and that a `.fips` URL never falls through to DNS.
final class FipsURLTests: XCTestCase {
    // A random string in the npub charset, not a real account.
    private let npub = "npub1z2g42utgkc5tv49xgwy7lplfd8048vuwv9krcc23m828kdjm3cl68tgcyy"
    private let base = URL(string: "http://127.0.0.1:41234/abcdef0123456789")!

    private func url(_ s: String) -> URL { URL(string: s)! }

    func testFipsHostsAreRecognisedWhateverTheName() {
        XCTAssertTrue(FipsURL.isFipsHost("\(npub).fips"))
        XCTAssertTrue(FipsURL.isFipsHost("\(npub.uppercased()).FIPS"))
        XCTAssertTrue(FipsURL.isFipsHost("site.fips"), "a hosts-file name is still .fips: it must not reach DNS")
        XCTAssertTrue(FipsURL.isFipsHost("\(npub).fips."))
        XCTAssertFalse(FipsURL.isFipsHost("fips.example.com"))
        XCTAssertFalse(FipsURL.isFipsHost("example.fipsx"))
        XCTAssertFalse(FipsURL.isFipsHost(nil))
        XCTAssertEqual(FipsURL.npub(inFipsHost: "\(npub).fips"), npub)
        XCTAssertEqual(FipsURL.npub(inFipsHost: "\(npub.uppercased()).Fips"), npub)
        XCTAssertNil(FipsURL.npub(inFipsHost: "site.fips"))
        XCTAssertNil(FipsURL.npub(inFipsHost: "\(npub.dropLast()).fips"), "a truncated npub is not one")
    }

    func testASiteMapsToTheViewerAndBack() {
        let site = url("http://\(npub).fips/blog/a%20b.html?x=1&y=%2F#top")
        let viewer = FipsURL.viewerURL(forSite: site)
        XCTAssertEqual(viewer?.absoluteString, "nvfips://\(npub)/blog/a%20b.html?x=1&y=%2F#top")
        XCTAssertEqual(viewer.flatMap(FipsURL.siteURL(forViewer:)), site)
        XCTAssertEqual(FipsURL.viewerURL(forSite: url("http://\(npub).fips"))?.absoluteString, "nvfips://\(npub)/")
        XCTAssertEqual(FipsURL.viewerURL(forSite: url("https://\(npub).fips/a"))?.absoluteString, "nvfips://\(npub)/a",
                       "https is read as http: the mesh session is the encryption")
        XCTAssertEqual(FipsURL.viewerURL(forSite: url("http://\(npub).fips:80/a"))?.absoluteString, "nvfips://\(npub)/a")
        XCTAssertEqual(FipsURL.viewerURL(forSite: url("http://user:pw@\(npub).fips/"))?.absoluteString, "nvfips://\(npub)/")
    }

    func testOnlyTheDoorsPortAndNpubHostsMap() {
        XCTAssertNil(FipsURL.viewerURL(forSite: url("http://\(npub).fips:8080/")), "the door serves port 80 only")
        XCTAssertNil(FipsURL.viewerURL(forSite: url("http://site.fips/")))
        XCTAssertNil(FipsURL.viewerURL(forSite: url("http://example.com/")))
        XCTAssertNil(FipsURL.viewerURL(forSite: url("ftp://\(npub).fips/")))
        XCTAssertNil(FipsURL.npub(inViewer: url("nvfips://example.com/")))
        XCTAssertNil(FipsURL.siteURL(forViewer: url("https://\(npub).fips/")))
    }

    func testTheDoorRequestKeepsTheTokenAndThePath() {
        let viewer = url("nvfips://\(npub)/css/site.css?v=2#x")
        XCTAssertEqual(FipsURL.ingressURL(base: base, forViewer: viewer)?.absoluteString,
                       "http://127.0.0.1:41234/abcdef0123456789/css/site.css?v=2")
        XCTAssertEqual(FipsURL.ingressURL(base: url("http://127.0.0.1:41234/abcdef0123456789/"), forViewer: url("nvfips://\(npub)"))?.absoluteString,
                       "http://127.0.0.1:41234/abcdef0123456789/")
        XCTAssertEqual(FipsURL.ingressURL(base: base, forViewer: url("nvfips://\(npub)/a%2Fb"))?.absoluteString,
                       "http://127.0.0.1:41234/abcdef0123456789/a%2Fb", "encoded path bytes pass through as they are")
        XCTAssertNil(FipsURL.ingressURL(base: url("http://example.com/t"), forViewer: viewer), "only a loopback door")
        XCTAssertNil(FipsURL.ingressURL(base: base, forViewer: url("http://\(npub).fips/")))
        XCTAssertEqual(FipsURL.hostHeader(forViewer: viewer), "\(npub).fips")
    }

    func testRedirectsStayOnTheMeshOrLeaveItOpenly() {
        let page = url("nvfips://\(npub)/old/page")
        XCTAssertEqual(FipsURL.redirectTarget("/new", from: page)?.absoluteString, "nvfips://\(npub)/new")
        XCTAssertEqual(FipsURL.redirectTarget("next", from: page)?.absoluteString, "nvfips://\(npub)/old/next")
        XCTAssertEqual(FipsURL.redirectTarget("http://\(npub).fips/x", from: page)?.absoluteString, "nvfips://\(npub)/x")
        XCTAssertEqual(FipsURL.redirectTarget("https://example.com/", from: page)?.absoluteString, "https://example.com/")
        XCTAssertNil(FipsURL.redirectTarget("http://site.fips/", from: page), "an unservable .fips target never reaches DNS")
        XCTAssertNil(FipsURL.redirectTarget("http://\(npub).fips:8443/", from: page))
    }

    func testLinkTapsRouteByHost() {
        let site = url("http://\(npub).fips/")
        XCTAssertEqual(FipsURL.route(site, inApp: true), .mesh(url("nvfips://\(npub)/")))
        XCTAssertEqual(FipsURL.route(site, inApp: false), .mesh(url("nvfips://\(npub)/")),
                       "with the toggle off a .fips link still never goes to the system browser")
        XCTAssertEqual(FipsURL.route(url("http://site.fips/"), inApp: true), .refusedFips)
        XCTAssertEqual(FipsURL.route(url("http://site.fips/"), inApp: false), .refusedFips)
        XCTAssertEqual(FipsURL.route(url("https://example.com/a"), inApp: true), .web(url("https://example.com/a")))
        XCTAssertEqual(FipsURL.route(url("http://example.com/a"), inApp: true), .web(url("http://example.com/a")))
        XCTAssertEqual(FipsURL.route(url("https://example.com/a"), inApp: false), .system)
        XCTAssertEqual(FipsURL.route(url("mailto:a@example.com"), inApp: true), .system)
        XCTAssertEqual(FipsURL.route(url("lightning:lnbc1"), inApp: true), .system)
        XCTAssertEqual(FipsURL.route(url("nvfips://\(npub)/a"), inApp: false), .mesh(url("nvfips://\(npub)/a")))
        XCTAssertEqual(FipsURL.route(url("nvfips://example.com/"), inApp: true), .refusedFips)
    }

    func testNothingInsideThePageReachesAFipsHostOverTheNetwork() {
        let site = url("http://\(npub).fips/a")
        XCTAssertEqual(FipsURL.navigation(to: site, isMainFrame: true), .load(url("nvfips://\(npub)/a")))
        XCTAssertEqual(FipsURL.navigation(to: site, isMainFrame: false), .refuse, "a .fips frame is refused, not loaded")
        XCTAssertEqual(FipsURL.navigation(to: url("ws://\(npub).fips/"), isMainFrame: true), .refuse)
        XCTAssertEqual(FipsURL.navigation(to: url("https://site.fips/"), isMainFrame: true), .refuse)
        XCTAssertEqual(FipsURL.navigation(to: url("nvfips://\(npub)/x"), isMainFrame: false), .allow)
        XCTAssertEqual(FipsURL.navigation(to: url("nvfips://site/"), isMainFrame: true), .refuse)
        XCTAssertEqual(FipsURL.navigation(to: url("https://example.com/"), isMainFrame: false), .allow)
        XCTAssertEqual(FipsURL.navigation(to: url("about:blank"), isMainFrame: true), .allow)
        XCTAssertEqual(FipsURL.navigation(to: url("data:text/html,hi"), isMainFrame: true), .refuse)
        XCTAssertEqual(FipsURL.navigation(to: url("nostr:npub1abc"), isMainFrame: true), .external)
        XCTAssertEqual(FipsURL.navigation(to: url("lightning:lnbc1"), isMainFrame: true), .external)
    }

    func testTypedAddressesGetAScheme() {
        XCTAssertEqual(FipsURL.typedURL("\(npub).fips/a")?.absoluteString, "http://\(npub).fips/a")
        XCTAssertEqual(FipsURL.typedURL("  example.com  ")?.absoluteString, "https://example.com")
        XCTAssertEqual(FipsURL.typedURL("https://example.com/x")?.absoluteString, "https://example.com/x")
        XCTAssertEqual(FipsURL.typedURL("http://\(npub).fips/")?.absoluteString, "http://\(npub).fips/")
        XCTAssertNil(FipsURL.typedURL(""))
        XCTAssertNil(FipsURL.typedURL("two words"))
    }

    func testPageTextIsEscaped() {
        XCTAssertEqual(FipsURL.htmlEscaped(#"<a href="x">'&'</a>"#), "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;")
        XCTAssertEqual(FipsURL.htmlEscaped("plain"), "plain")
    }
}

/// The engine's ingress codes as the browser reads them.
final class MeshSiteIngressTests: XCTestCase {
    func testNoTreeParentIsWaitingAndEverythingElseFailed() {
        XCTAssertEqual(MeshSiteIngress(failure: -10), .notReady)
        XCTAssertTrue(MeshSiteIngress(failure: -10).isWaiting)
        for rc: Int32 in [-1, -3, -5, -6, -9, -11] {
            XCTAssertEqual(MeshSiteIngress(failure: rc), .failed, "rc \(rc)")
        }
        XCTAssertFalse(MeshSiteIngress.failed.isWaiting)
        let base = URL(string: "http://127.0.0.1:1/t")!
        XCTAssertEqual(MeshSiteIngress.ready(base).url, base)
        XCTAssertNil(MeshSiteIngress.notReady.url)
    }
}
