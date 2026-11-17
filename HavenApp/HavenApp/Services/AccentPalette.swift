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
/// - Dark is neon (`AccentMath.neon`): the same hue pushed to the most colour
///   sRGB allows, lighter only as far as text needs to read 4.5:1 on a card.
///   Buttons and text both use it.
/// - Light shows the colour exactly as picked on buttons and fills
///   (`primary`); only accent text (`text`: #tags, links) is darkened, and only
///   for colours under 3.5:1 on white (gold, green, teal, orange), to 4.5:1.
/// - A label on an accent fill is white whenever white reads (3:1, a bold
///   label), otherwise black, so yellow and teal buttons get black labels.
///
/// Saved as `HavenConfig.themeColor`: "orange" (the default) or "#rrggbb".
struct AccentPalette {
    /// The fill: buttons, rings, borders, toggles.
    let primary: Color
    /// Accent text: #tags, links, accent-coloured labels and icons.
    let text: Color
    let light: Color
    let dark: Color
    let onAccent: Color
    /// The page and its two lower steps (`Color.surface0/2/3`): in Light a
    /// near-neutral paper with `paperTint` of the picked colour mixed in, so
    /// the page leans toward the accent; Dark keeps Apple's greys untouched.
    let surface0: Color
    let surface2: Color
    let surface3: Color

    /// How much of the picked colour goes into the Light page (sRGB mix).
    /// With the default orange this lands on the warm paper (about F6F0EC).
    static let paperTint = 0.05
    /// The Light bases before the tint: page, field-in-card, overlay.
    static let paperBases: (s0: UInt32, s2: UInt32, s3: UInt32) = (0xF7F7F6, 0xF0EFEC, 0xE2E0DC)

    static let defaultHex = "#e67326"

    /// The ready-made row, orange first: three anchors (the app's orange, Nostr
    /// purple from the Nostr logo, Android green) and the colours around them.
    static let presets: [(hex: String, name: String)] = AccentMath.presets

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
        // A new accent (picked here, synced, or at launch): the icon follows
        // when the setting is on. After this render, not during it.
        DispatchQueue.main.async { IconAccentApply.apply(accentHex: hex) }
        return palette
    }

    @MainActor private static var cached: (hex: String, palette: AccentPalette)?

    static func make(_ hex: String) -> AccentPalette {
        let pick = normalize(hex) ?? defaultHex
        let t = AccentMath.tokens(AccentMath.rgb(pick))
        func both(_ light: AccentMath.RGB, _ dark: AccentMath.RGB) -> Color { Color(light: color(light), dark: color(dark)) }
        func label(_ white: Bool) -> Color { white ? .white : .black }
        return AccentPalette(
            primary: both(t.lightFill, t.darkFill),
            text: both(t.lightText, t.darkFill),
            light: both(t.lightLight, t.darkLight),
            dark: both(t.lightDeep, t.darkDeep),
            onAccent: Color(light: label(t.lightWhiteLabel), dark: label(t.darkWhiteLabel)),
            surface0: paper(paperBases.s0, pick, darkHex: 0x000000),
            surface2: paper(paperBases.s2, pick, darkHex: 0x2C2C2E),
            surface3: paper(paperBases.s3, pick, darkHex: 0x3A3A3C)
        )
    }

    static func color(_ c: AccentMath.RGB) -> Color { Color(red: c.r / 255, green: c.g / 255, blue: c.b / 255) }

    /// A Light surface: the base with `paperTint` of the pick mixed in.
    static func paper(_ base: UInt32, _ pick: String, darkHex: UInt32) -> Color {
        Color(light: color(AccentMath.mix(paperHex: base, pick: pick, amount: paperTint)),
              dark: Color(hex: darkHex))
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
        color(AccentMath.rgb(normalize(hex) ?? defaultHex))
    }

    /// True when Light darkens the colour's text to make it read, so the
    /// picker can say #tags look deeper in Light.
    static func shiftsInLight(_ hex: String) -> Bool {
        AccentMath.textDarkenedInLight(AccentMath.rgb(normalize(hex) ?? defaultHex))
    }
}

