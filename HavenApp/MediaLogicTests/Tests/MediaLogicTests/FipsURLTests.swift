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
        XCTAssertEqual(FipsURL.navigation(to: site, isMainFrame: true, fromMesh: false), .load(url("nvfips://\(npub)/a")))
        XCTAssertEqual(FipsURL.navigation(to: site, isMainFrame: false, fromMesh: false), .refuse, "a .fips frame is refused, not loaded")
        XCTAssertEqual(FipsURL.navigation(to: url("ws://\(npub).fips/"), isMainFrame: true, fromMesh: false), .refuse)
        XCTAssertEqual(FipsURL.navigation(to: url("https://site.fips/"), isMainFrame: true, fromMesh: false), .refuse)
        XCTAssertEqual(FipsURL.navigation(to: url("nvfips://\(npub)/x"), isMainFrame: false, fromMesh: false), .allow)
        XCTAssertEqual(FipsURL.navigation(to: url("nvfips://site/"), isMainFrame: true, fromMesh: false), .refuse)
        XCTAssertEqual(FipsURL.navigation(to: url("https://example.com/"), isMainFrame: false, fromMesh: false), .allow)
        XCTAssertEqual(FipsURL.navigation(to: url("about:blank"), isMainFrame: true, fromMesh: false), .allow)
        XCTAssertEqual(FipsURL.navigation(to: url("data:text/html,hi"), isMainFrame: true, fromMesh: false), .refuse)
        XCTAssertEqual(FipsURL.navigation(to: url("nostr:npub1abc"), isMainFrame: true, fromMesh: false), .external)
        XCTAssertEqual(FipsURL.navigation(to: url("lightning:lnbc1"), isMainFrame: true, fromMesh: false), .external)
    }

    func testAMeshPageReachesNoInternetHostByItself() {
        let web = url("https://owner.example/b")
        XCTAssertEqual(FipsURL.navigation(to: web, isMainFrame: true, fromMesh: true), .leaveMesh(web), "a page leave waits for the reader")
        let leave = url("nvleave:" + web.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)
        XCTAssertEqual(FipsURL.navigation(to: leave, isMainFrame: true, fromMesh: true), .leaveMesh(web), "a clicked link, handed over")
        XCTAssertEqual(FipsURL.navigation(to: leave, isMainFrame: false, fromMesh: true), .refuse)
        let fipsLeave = url("nvleave:" + "http://\(npub).fips/a".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)
        XCTAssertEqual(FipsURL.navigation(to: fipsLeave, isMainFrame: true, fromMesh: true), .load(url("nvfips://\(npub)/a")))
        XCTAssertEqual(FipsURL.navigation(to: url("nvleave:javascript%3Aalert(1)"), isMainFrame: true, fromMesh: true), .refuse)
        XCTAssertEqual(FipsURL.navigation(to: url("nvleave:nostr%3Anpub1abc"), isMainFrame: true, fromMesh: true), .refuse)
        XCTAssertEqual(FipsURL.navigation(to: web, isMainFrame: false, fromMesh: true), .refuse, "a frame off the mesh is refused")
        XCTAssertEqual(FipsURL.navigation(to: url("wss://owner.example/s"), isMainFrame: true, fromMesh: true), .refuse)
        XCTAssertEqual(FipsURL.navigation(to: url("nvfips://\(npub)/x"), isMainFrame: true, fromMesh: true), .allow)
        XCTAssertEqual(FipsURL.navigation(to: url("http://\(npub).fips/a"), isMainFrame: true, fromMesh: true),
                       .load(url("nvfips://\(npub)/a")))
        XCTAssertEqual(FipsURL.navigation(to: web, isMainFrame: true, fromMesh: false), .allow, "web to web is a browser")
    }

    private func matches(_ filters: [String], _ s: String) -> Bool {
        filters.contains { f in
            (try! NSRegularExpression(pattern: f, options: .caseInsensitive))
                .firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
    }

    func testTheBlockRulesCatchEveryFipsHostShape() {
        for scheme in ["http", "https", "ws", "wss"] {
            for host in ["\(npub).fips", "\(npub).fips.", "site.FIPS", "a.b.fips."] {
                for tail in ["/", "/x?y", ":80/", ":443/", ""] {
                    let s = "\(scheme)://\(host)\(tail)"
                    XCTAssertTrue(matches(FipsURL.fipsBlockFilters, s), "not blocked: \(s)")
                }
            }
            XCTAssertFalse(matches(FipsURL.fipsBlockFilters, "\(scheme)://fips.example.com/"))
            XCTAssertFalse(matches(FipsURL.fipsBlockFilters, "\(scheme)://example.com/a.fips"))
        }
        for s in ["https://owner.example/b", "http://1.2.3.4/", "ws://x/", "wss://x:443/"] {
            XCTAssertTrue(matches(FipsURL.offMeshFilters, s), "a mesh page would reach \(s)")
        }
        XCTAssertFalse(matches(FipsURL.offMeshFilters, "nvfips://\(npub)/"))
        XCTAssertFalse(matches(FipsURL.offMeshFilters, "data:text/html,hi"))
        XCTAssertTrue(matches([FipsURL.meshTopURL], "nvfips://\(npub)/"))
        XCTAssertFalse(matches([FipsURL.meshTopURL], "https://example.com/?nvfips:"))
    }

    func testTheOffMeshRulesHoldOnlyOnMeshPages() throws {
        let rules = try JSONSerialization.jsonObject(with: Data(FipsURL.browserRulesJSON.utf8)) as! [[String: Any]]
        let triggers = rules.map { $0["trigger"] as! [String: Any] }
        XCTAssertEqual(rules.count, FipsURL.fipsBlockFilters.count + FipsURL.offMeshFilters.count)
        XCTAssertTrue(rules.allSatisfy { ($0["action"] as? [String: String])?["type"] == "block" })
        for t in triggers where FipsURL.offMeshFilters.contains(t["url-filter"] as! String) {
            XCTAssertEqual(t["if-top-url"] as? [String], [FipsURL.meshTopURL])
        }
        for t in triggers where FipsURL.fipsBlockFilters.contains(t["url-filter"] as! String) {
            XCTAssertNil(t["if-top-url"], ".fips hosts are blocked on every page")
        }
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
