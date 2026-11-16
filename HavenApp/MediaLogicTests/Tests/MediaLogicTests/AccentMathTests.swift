import XCTest
@testable import MediaLogic

/// The accent row Logen picked (nv-ui c5abde71): neon in Dark for buttons and
/// text, exact in Light for buttons, and only the pale colours' #tag text
/// darkened in Light. Same table as web-vault/test/accent.test.mjs.
final class AccentMathTests: XCTestCase {
    let neonDark: [String: String] = [
        "#e67326": "#ea7013", "#ffb800": "#ffb800", "#3ddc84": "#1fde7f", "#00c2b8": "#00c2b8",
        "#2e7dff": "#327fff", "#662482": "#c641fc", "#ff2d87": "#ff2d87", "#a8071a": "#fc2c37",
    ]
    let darkened: Set<String> = ["#e67326", "#ffb800", "#3ddc84", "#00c2b8"]

    func testPresetRowOrder() {
        XCTAssertEqual(AccentMath.presets.map(\.hex), ["#e67326", "#ffb800", "#3ddc84", "#00c2b8", "#2e7dff", "#662482", "#ff2d87", "#a8071a"])
        XCTAssertEqual(AccentMath.presets.map(\.name), ["Orange", "Gold", "Green", "Teal", "Blue", "Nostr purple", "Pink", "Blood red"])
    }

    func testNeonDarkExactLightOnlyPaleTextDarkened() {
        for p in AccentMath.presets {
            let t = AccentMath.tokens(AccentMath.rgb(p.hex))
            XCTAssertEqual(AccentMath.hex(t.darkFill), neonDark[p.hex], "\(p.name) dark")
            XCTAssertEqual(AccentMath.hex(t.lightFill), p.hex, "\(p.name) light fill exact")
            if darkened.contains(p.hex) {
                XCTAssertNotEqual(AccentMath.hex(t.lightText), p.hex, "\(p.name) light text darkened")
                XCTAssertGreaterThanOrEqual(AccentMath.contrast(t.lightText, AccentMath.white), 4.5)
            } else {
                XCTAssertEqual(AccentMath.hex(t.lightText), p.hex, "\(p.name) light text exact")
            }
        }
    }

    func testDefaultOrangeTokensMatchWeb() {
        let t = AccentMath.tokens(AccentMath.rgb("#e67326"))
        XCTAssertEqual(AccentMath.hex(t.darkFill), "#ea7013")
        XCTAssertEqual(AccentMath.hex(t.darkLight), "#ff8a3a")
        XCTAssertEqual(AccentMath.hex(t.darkDeep), "#c04a00")
        XCTAssertEqual(AccentMath.hex(t.lightText), "#c35400")
        XCTAssertEqual(AccentMath.hex(t.lightLight), "#e67326")
        XCTAssertTrue(t.lightWhiteLabel)
        XCTAssertTrue(t.darkWhiteLabel)
    }

    func testGreysStayGrey() {
        XCTAssertEqual(AccentMath.hex(AccentMath.neon(AccentMath.rgb("#000000"))), "#868686")
        XCTAssertEqual(AccentMath.hex(AccentMath.neon(AccentMath.rgb("#ffffff"))), "#ffffff")
    }

    func testAnyColourReadsInBothModes() {
        var seed: UInt64 = 7
        for _ in 0..<300 {
            seed = (seed * 16807) % 2147483647
            let v = Int(Double(seed) / 2147483647 * Double(0xffffff))
            let hex = String(format: "#%06x", v)
            let t = AccentMath.tokens(AccentMath.rgb(hex))
            XCTAssertGreaterThanOrEqual(AccentMath.contrast(t.darkFill, AccentMath.cardDark), 4.5, "\(hex) dark")
            XCTAssertGreaterThanOrEqual(AccentMath.contrast(t.lightText, AccentMath.white), 3.5, "\(hex) light text")
            let label: AccentMath.RGB = t.lightWhiteLabel ? AccentMath.white : (0, 0, 0)
            XCTAssertGreaterThanOrEqual(AccentMath.contrast(label, t.lightLight), 3, "\(hex) light label on light end")
        }
    }
}
