import XCTest
@testable import MediaLogic

final class IconAccentTests: XCTestCase {
    func testOneIconPerPresetInOrder() {
        XCTAssertEqual(IconAccent.icons.map(\.hex), AccentMath.presets.map(\.hex))
        XCTAssertEqual(Set(IconAccent.icons.map(\.name)).count, AccentMath.presets.count)
    }

    func testPresetIsItsOwnNearest() {
        for preset in AccentMath.presets {
            XCTAssertEqual(IconAccent.nearestPresetHex(preset.hex), preset.hex, preset.name)
        }
    }

    func testWheelColourTakesNearestPreset() {
        XCTAssertEqual(IconAccent.nearestPresetHex("#ff0000"), "#a8071a") // pure red -> Blood red
        XCTAssertEqual(IconAccent.nearestPresetHex("#0040ff"), "#2e7dff") // royal blue -> Blue
        XCTAssertEqual(IconAccent.nearestPresetHex("#ffd700"), "#ffb800") // gold-ish -> Gold
        XCTAssertEqual(IconAccent.nearestPresetHex("#7b2fa0"), "#662482") // violet -> Nostr purple
        XCTAssertEqual(IconAccent.nearestPresetHex("#00FF7F"), "#3ddc84") // upper case works
    }

    func testOffMeansTheAppsOwnIcon() {
        XCTAssertNil(IconAccent.iconName(accentHex: "#2e7dff", follows: false))
        XCTAssertEqual(IconAccent.iconName(accentHex: "#2e7dff", follows: true), "AppIcon-Blue")
        XCTAssertEqual(IconAccent.iconName(accentHex: "#e67326", follows: true), "AppIcon-Orange")
    }

    /// The names must match the asset catalog and the build setting, or iOS
    /// refuses the change at run time.
    func testIconsExistInAssetsAndProject() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        let line = try XCTUnwrap(project.split(separator: "\n").first { $0.contains("ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES") })
        for icon in IconAccent.icons {
            XCTAssertTrue(line.contains(icon.name), icon.name)
            let png = root.appendingPathComponent("Resources/Assets.xcassets/\(icon.name).appiconset/icon_1024x1024.png")
            XCTAssertTrue(FileManager.default.fileExists(atPath: png.path), png.path)
        }
    }

    func testMacTint() {
        let same = IconAccent.macTint(toHex: "#e67326")
        XCTAssertEqual(same.hueAngle, 0, accuracy: 1e-9)
        XCTAssertEqual(same.saturation, 1, accuracy: 1e-9)
        XCTAssertEqual(IconAccent.macTint(toHex: "#808080").saturation, 0, accuracy: 1e-9) // grey stays grey
        let blue = IconAccent.macTint(toHex: "#2e7dff")
        XCTAssertGreaterThan(abs(blue.hueAngle), 2) // across the wheel
        XCTAssertLessThanOrEqual(abs(blue.hueAngle), Double.pi)
    }
}
