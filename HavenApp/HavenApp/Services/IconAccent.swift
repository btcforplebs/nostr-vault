import Foundation

/// The app icon follows the accent (Logen, 2026-11-17): eight alternate
/// home-screen icons on iPhone/iPad, one per `AccentMath.presets` colour; a
/// colour from the wheel uses the nearest of them. On the Mac the running
/// app's icon is tinted to any colour instead (IconAccentApply). Off by
/// default: iOS shows a pop-up every time the icon changes.
/// Pure, so MediaLogicTests checks it. Android: not yet.
enum IconAccent {
    /// UserDefaults key of Settings › Appearance › "Icon follows accent".
    static let followsKey = "iconFollowsAccent"

    /// The alternate icon for each preset, in `AccentMath.presets` order (art:
    /// Frida, RESEARCH/NV_ACCENT_ICONS/<hex>-light/-dark.png). Each set has a
    /// light icon and a dark one (iOS 18 picks by appearance). The
    /// names are the asset catalog's `AppIcon-*.appiconset` folders and
    /// project.yml's ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES.
    static let icons: [(hex: String, name: String)] = [
        ("#e67326", "AppIcon-Orange"), ("#ffb800", "AppIcon-Gold"), ("#3ddc84", "AppIcon-Green"),
        ("#00c2b8", "AppIcon-Teal"), ("#2e7dff", "AppIcon-Blue"), ("#662482", "AppIcon-Purple"),
        ("#ff2d87", "AppIcon-Pink"), ("#a8071a", "AppIcon-Red"),
    ]

    /// The preset closest to `hex` as people see it: OKLab distance with
    /// lightness counting a quarter, so hue and colourfulness decide (pure red
    /// is Blood red, not the lighter Pink). A preset is its own nearest.
    static func nearestPresetHex(_ hex: String) -> String {
        let (L, A, B) = AccentMath.toLab(AccentMath.rgb(hex.lowercased()))
        func distance(_ preset: String) -> Double {
            let (l, a, b) = AccentMath.toLab(AccentMath.rgb(preset))
            let dL = (L - l) * lightnessWeight
            return dL * dL + (A - a) * (A - a) + (B - b) * (B - b)
        }
        return icons.min { distance($0.hex) < distance($1.hex) }!.hex
    }

    static let lightnessWeight = 0.25

    /// The alternate icon to show: nil (the app's own icon) when the setting
    /// is off, else the icon of the nearest preset.
    static func iconName(accentHex: String, follows: Bool) -> String? {
        guard follows else { return nil }
        let nearest = nearestPresetHex(accentHex)
        return icons.first { $0.hex == nearest }?.name
    }

    /// The Mac tint: how far (radians) to turn the hue of the icon's orange
    /// to land on `hex`, and how much to scale its saturation (greys go grey).
    static func macTint(toHex hex: String) -> (hueAngle: Double, saturation: Double) {
        let from = hsv(AccentMath.rgb(AccentMath.presets[0].hex))
        let to = hsv(AccentMath.rgb(hex.lowercased()))
        var angle = (to.h - from.h) * 2 * Double.pi
        if angle > Double.pi { angle -= 2 * Double.pi }
        if angle < -Double.pi { angle += 2 * Double.pi }
        return (angle, min(1.5, to.s / from.s))
    }

    /// Hue (0..<1) and saturation (0...1) of an RGB colour.
    static func hsv(_ c: AccentMath.RGB) -> (h: Double, s: Double) {
        let r = c.r / 255, g = c.g / 255, b = c.b / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        guard mx > 0, d > 0 else { return (0, 0) }
        var h: Double
        if mx == r { h = (g - b) / d } else if mx == g { h = 2 + (b - r) / d } else { h = 4 + (r - g) / d }
        h /= 6
        if h < 0 { h += 1 }
        return (h, d / mx)
    }
}
