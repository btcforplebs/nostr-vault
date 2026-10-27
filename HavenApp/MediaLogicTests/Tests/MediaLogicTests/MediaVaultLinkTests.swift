import XCTest
@testable import MediaLogic

final class MediaVaultLinkTests: XCTestCase {
    func testFipsLinksAreTheVault() {
        let npub = "npub1qqxjlq4nw7zz0xdq8tgy0d6pxz8kjlv7xz0wyz5fz9l6ynmx8hls4ygwkp"
        for s in ["http://\(npub).fips/487dc1578912f424773b0befc4eff491f026f0f24652f1d4ff66a85639455217",
                  "http://\(npub.uppercased()).FIPS/abc.jpg",
                  "http://\(npub).fips./abc"] {
            XCTAssertTrue(MediaVaultLink.isVault(URL(string: s)!), s)
        }
    }

    func testHttpsServersAreNot() {
        for s in ["https://blossom.primal.net/487dc157.jpg",
                  "https://image.nostr.build/a.png",
                  "https://fips.example.com/a.png",          // fips in the name, not the TLD
                  "https://example.com/photo.fips",           // .fips in the path
                  "https://logen.btcforplebs.com/abc.jpg"] {  // the owner's own https blossom
            XCTAssertFalse(MediaVaultLink.isVault(URL(string: s)!), s)
        }
    }
}
