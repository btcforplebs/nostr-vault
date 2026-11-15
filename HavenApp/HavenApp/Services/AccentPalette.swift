import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Settings › Appearance › Accent: the app's orange, one of eight ready-made
/// colours, or any colour from the wheel (PLANS/NV_LIGHT_MODE_AND_CUSTOM_COLORS.md).
/// Same rules as web-vault/src/net/accent.js:
///
/// - Dark shows the colour as picked, lifted only if it would be too dark to
///   read on a card (4.5:1 on #1C1C1E).
/// - Light never puts a pale colour on the paper as text: the accent there is
///   the colour darkened in OKLab until it reads (4.5:1 on white).
/// - A label on an accent fill is white whenever white reads (3:1, a bold
///   label), otherwise black, so yellow and teal buttons get black labels.
///
/// Saved as `HavenConfig.themeColor`: "orange" (the default) or "#rrggbb".
struct AccentPalette {
    let primary: Color
    let light: Color
    let dark: Color
    let onAccent: Color

    static let defaultHex = "#e67326"

    /// The ready-made row, orange first. Apple's system colours, so each sits well on black.
    static let presets: [(hex: String, name: String)] = [
        ("#e67326", "Orange"), ("#ffd60a", "Yellow"), ("#30d158", "Green"), ("#40c8e0", "Teal"),
        ("#0a84ff", "Blue"), ("#5e5ce6", "Indigo"), ("#bf5af2", "Purple"), ("#ff375f", "Pink"),
    ]

    /// The saved colour as "#rrggbb"; anything else is the default orange.
    static func hex(fromSetting setting: String) -> String {
        normalize(setting) ?? defaultHex
    }

    static func normalize(_ value: String) -> String? {
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard v.range(of: "^#[0-9a-f]{6}$", options: .regularExpression) != nil else { return nil }
        return v
    }

    /// What `themeColor` should hold for a pick: the default stays "orange".
    static func setting(forHex hex: String) -> String {
        let pick = normalize(hex) ?? defaultHex
        return pick == defaultHex ? AppTheme.orange.rawValue : pick
    }

    @MainActor
    static var current: AccentPalette {
        let hex = hex(fromSetting: ConfigService.shared.config.themeColor)
        if let cached, cached.hex == hex { return cached.palette }
        let palette = make(hex)
        cached = (hex, palette)
        return palette
    }

    @MainActor private static var cached: (hex: String, palette: AccentPalette)?

    static func make(_ hex: String) -> AccentPalette {
        let pick = normalize(hex) ?? defaultHex
        if pick == defaultHex {
            // The orange keeps its hand-tuned ramp exactly.
            let t = AppTheme.orange
            return AccentPalette(primary: t.primaryColor, light: t.lightColor, dark: t.darkColor, onAccent: .white)
        }
        let rgb = AccentMath.rgb(pick)
        let darkText = AccentMath.readable(rgb, on: AccentMath.cardDark, min: 4.5, dir: 1)
        let lightText = AccentMath.readable(rgb, on: AccentMath.white, min: 4.5, dir: -1)
        return AccentPalette(
            primary: Color(light: AccentMath.color(lightText), dark: AccentMath.color(darkText)),
            light: Color(light: AccentMath.color(AccentMath.readable(rgb, on: AccentMath.white, min: 3, dir: -1)),
                         dark: AccentMath.color(AccentMath.shade(darkText, 0.08))),
            dark: Color(light: AccentMath.color(AccentMath.shade(lightText, -0.1)),
                        dark: AccentMath.color(AccentMath.shade(darkText, -0.12))),
            onAccent: Color(light: AccentMath.labelOn(lightText), dark: AccentMath.labelOn(darkText))
        )
    }

    /// A colour from the wheel as "#rrggbb" (sRGB).
    static func hex(of color: Color) -> String {
        #if os(macOS)
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .orange
        let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)).getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        func byte(_ v: CGFloat) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
    }

    /// The picked colour itself (no lift or deepening), for swatches.
    static func swatch(_ hex: String) -> Color {
        AccentMath.color(AccentMath.rgb(normalize(hex) ?? defaultHex))
    }

    /// True when light mode had to darken the colour a lot to make it read,
    /// so the picker can say the light version looks different.
    static func shiftsInLight(_ hex: String) -> Bool {
        AccentMath.contrast(AccentMath.rgb(normalize(hex) ?? defaultHex), AccentMath.white) < 3
    }
}

/// Colour maths, a port of web-vault/src/net/accent.js. RGB is 0...255.
enum AccentMath {
    typealias RGB = (r: Double, g: Double, b: Double)

    static let white: RGB = (255, 255, 255)
    static let cardDark: RGB = (28, 28, 30)

    static func rgb(_ hex: String) -> RGB {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0xE67326
        return (Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF), Double(v & 0xFF))
    }

    static func color(_ c: RGB) -> Color { Color(red: c.r / 255, green: c.g / 255, blue: c.b / 255) }

    private static func lin(_ c: Double) -> Double { let x = c / 255; return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
    private static func unlin(_ c: Double) -> Double { 255 * (c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055) }

    static func luminance(_ c: RGB) -> Double { 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b) }

    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// OKLab (Björn Ottosson): changing only L keeps the hue and how colourful it looks.
    private static func toLab(_ c: RGB) -> (Double, Double, Double) {
        let r = lin(c.r), g = lin(c.g), b = lin(c.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s)
    }

    private static func fromLab(_ L: Double, _ A: Double, _ B: Double) -> RGB {
        let l = pow(L + 0.3963377774 * A + 0.2158037573 * B, 3)
        let m = pow(L - 0.1055613458 * A - 0.0638541728 * B, 3)
        let s = pow(L - 0.0894841775 * A - 1.291485548 * B, 3)
        func ch(_ v: Double) -> Double { (unlin(min(1, max(0, v)))).rounded() }
        return (ch(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                ch(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                ch(-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s))
    }

    /// The colour moved lighter (dir 1) or darker (-1) in small steps until it reads at `min` on `bg`.
    static func readable(_ c: RGB, on bg: RGB, min: Double, dir: Double) -> RGB {
        if contrast(c, bg) >= min { return c }
        let (L, A, B) = toLab(c)
        for i in 1...100 {
            let next = fromLab(Swift.min(1, Swift.max(0, L + dir * Double(i) * 0.01)), A, B)
            if contrast(next, bg) >= min { return next }
        }
        return dir < 0 ? (0, 0, 0) : white
    }

    static func shade(_ c: RGB, _ dL: Double) -> RGB {
        let (L, A, B) = toLab(c)
        return fromLab(min(1, max(0, L + dL)), A, B)
    }

    /// White or black for a label on a fill of this colour: white whenever it reads as a bold label.
    static func labelOn(_ c: RGB) -> Color { contrast(white, c) >= 3 ? .white : .black }
}
