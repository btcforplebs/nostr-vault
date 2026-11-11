import XCTest
@testable import MediaLogic

/// Links in a profile bio: every one the person wrote is tappable, the text
/// stays as written, and a `.fips` link reaches the in-app browser's mesh route.
final class ProfileBioLinksTests: XCTestCase {
    // A random string in the npub charset, not a real account.
    private let npub = "npub1z2g42utgkc5tv49xgwy7lplfd8048vuwv9krcc23m828kdjm3cl68tgcyy"

    private func urls(_ bio: String) -> [String] {
        ProfileBioLinks.links(in: bio).map(\.url.absoluteString)
    }

    private func texts(_ bio: String) -> [String] {
        ProfileBioLinks.links(in: bio).map { String(bio[$0.range]) }
    }

    func testABioFipsLinkRoutesToTheBrowserOverTheMesh() {
        let bio = "[fips] http://\(npub).fips"
        let link = ProfileBioLinks.links(in: bio).first?.url
        XCTAssertEqual(link.map { FipsURL.route($0, inApp: true) }, .mesh(URL(string: "nvfips://\(npub)/")!))
        // "Open links in Nostr Vault" off: still the mesh, never the system browser.
        XCTAssertEqual(link.map { FipsURL.route($0, inApp: false) }, .mesh(URL(string: "nvfips://\(npub)/")!))
    }

    func testABareFipsAddressIsALink() {
        let bio = "my site: \(npub).fips/blog?x=1, come by."
        XCTAssertEqual(urls(bio), ["http://\(npub).fips/blog?x=1"])
        XCTAssertEqual(texts(bio), ["\(npub).fips/blog?x=1"])
        let link = ProfileBioLinks.links(in: bio)[0].url
        XCTAssertEqual(FipsURL.route(link, inApp: true), .mesh(URL(string: "nvfips://\(npub)/blog?x=1")!))
    }

    /// The shapes in a real bio (Laan Tungir's kind 0, 2026-11-11): six tap
    /// through; the Tor address stays text (no Tor, Logen 2026-11-11).
    func testTheLinksOfARealBio() {
        let bio = """
        Falibilist

        If you like my images: \nhttps://laantungir.net/client/slide-show.html?npub=npub1rmz9gu6de0m0u4ysrn39crrud099ahvfgs6pvasl4hpjr5ud7yus54xv06

        If you like nerd thingz:
        [domain] https://laantungir.net
        [ipv4] https://15.235.3.231
        [ipv6] https://[2607:5300:203:bb5c:4a46:c3d3:1dc3:fbe8]
        [tor] http://kn2jam4kyz6s5wacyozo3do3d2zsvh4to45uh7xliulwdust6zjuvnad.onion
        [fips] http://npub1crpldvy49ef8z34wlacwujnfudy4nd7k96aqdx5wgn6ckztz7z8q9t59ud.fips
        [n-site] https://npub1rmz9gu6de0m0u4ysrn39crrud099ahvfgs6pvasl4hpjr5ud7yus54xv06.nsite.run
        """
        XCTAssertEqual(urls(bio), [
            "https://laantungir.net/client/slide-show.html?npub=npub1rmz9gu6de0m0u4ysrn39crrud099ahvfgs6pvasl4hpjr5ud7yus54xv06",
            "https://laantungir.net",
            "https://15.235.3.231",
            "https://[2607:5300:203:bb5c:4a46:c3d3:1dc3:fbe8]",
            "http://npub1crpldvy49ef8z34wlacwujnfudy4nd7k96aqdx5wgn6ckztz7z8q9t59ud.fips",
            "https://npub1rmz9gu6de0m0u4ysrn39crrud099ahvfgs6pvasl4hpjr5ud7yus54xv06.nsite.run",
        ])
        XCTAssertEqual(texts(bio), urls(bio), "each link covers exactly what was written")
        let routes = ProfileBioLinks.links(in: bio).map { FipsURL.route($0.url, inApp: true) }
        XCTAssertEqual(routes.filter { if case .web = $0 { return true }; return false }.count, 5)
        XCTAssertEqual(routes[4], .mesh(URL(string: "nvfips://npub1crpldvy49ef8z34wlacwujnfudy4nd7k96aqdx5wgn6ckztz7z8q9t59ud/")!))
    }

    func testTrailingPunctuationAndBracketsStayOutside() {
        XCTAssertEqual(urls("see https://example.com/a."), ["https://example.com/a"])
        XCTAssertEqual(urls("(https://example.com/a)"), ["https://example.com/a"])
        XCTAssertEqual(urls("https://en.wikipedia.org/wiki/Foo_(bar)"), ["https://en.wikipedia.org/wiki/Foo_(bar)"])
        XCTAssertEqual(urls("<https://example.com>"), ["https://example.com"])
        XCTAssertEqual(urls("\"https://example.com/x?y=1\","), ["https://example.com/x?y=1"])
        XCTAssertEqual(urls("[ipv6] https://[::1]:8080/p]"), ["https://[::1]:8080/p"])
    }

    func testNotLinks() {
        XCTAssertEqual(urls("no links here, just example.com and ftp://x.y"), [])
        XCTAssertEqual(urls("https://"), [])
        XCTAssertEqual(urls("a \(npub.dropLast()).fips truncated npub"), [], "not an npub: no bare .fips link")
        XCTAssertEqual(urls("xhttps://example.com"), [], "a scheme glued to a word is not a link")
        XCTAssertEqual(urls("[tor] http://abc.onion/x and https://abc.onion."), [], "no Tor: .onion stays text")
    }

    func testAttributedKeepsTheTextAndMarksOnlyTheLinks() {
        let bio = "*not bold* go to \(npub).fips or https://a.example/b."
        let attributed = ProfileBioLinks.attributed(bio)
        XCTAssertEqual(String(attributed.characters), bio, "the bio reads exactly as written")
        let marked = attributed.runs.compactMap { run in
            run.link.map { (String(attributed[run.range].characters), $0.absoluteString) }
        }
        XCTAssertEqual(marked.map(\.0), ["\(npub).fips", "https://a.example/b"])
        XCTAssertEqual(marked.map(\.1), ["http://\(npub).fips", "https://a.example/b"])
    }
}
