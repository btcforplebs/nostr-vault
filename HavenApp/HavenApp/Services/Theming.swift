import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The app has exactly one appearance: OLED black with the orange accent.
///
/// This was a six-way colour picker (purple/blue/green/orange/pink/slate) paired
/// with an OLED toggle. Both are gone. The enum survives only so `themeColor`
/// keeps decoding — a config saved under any of the retired keys resolves to
/// `.orange` via `AppTheme(rawValue:) ?? .orange`, so old installs migrate
/// silently instead of failing to parse.
enum AppTheme: String, CaseIterable, Identifiable {
    case orange = "orange"

    var id: String { self.rawValue }

    var displayName: String { "Sunset Orange" }

    // Light mode deepens each step so orange text reads on the paper page
    // (#C2571A is 4.6:1 on white; #E67326 is 3.1:1). White labels still read
    // on the deeper fill.
    var primaryColor: Color { Color(lightHex: 0xC2571A, darkHex: 0xE67326) }
    var lightColor: Color { Color(lightHex: 0xE67326, darkHex: 0xFA9447) }
    var darkColor: Color { Color(lightHex: 0x9A4512, darkHex: 0xB35214) }
    var paleColor: Color { primaryColor.opacity(0.1) }
}

extension Color {
    // The accent ramp (Settings › Appearance › Accent, AccentPalette). The
    // names predate the orange; they are the accent, whatever colour it is.
    @MainActor static var havenPurple: Color { AccentPalette.current.primary }
    @MainActor static var havenPurpleLight: Color { AccentPalette.current.light }
    @MainActor static var havenPurpleDark: Color { AccentPalette.current.dark }
    @MainActor static var havenPurplePale: Color { AccentPalette.current.primary.opacity(0.1) }

    // Colors are now primarily defined here to ensure project-wide availability

    /// The one "things are working" green in the app. Status dots, running-state
    /// pills, and go-ahead buttons (Start Relay) all mean the same thing and
    /// should read as the same color — not a system default in one place and a
    /// custom mint somewhere else.
    static var havenOnline: Color { Color(light: Color(hex: 0x1A9E57), dark: Color(red: 0.2, green: 0.85, blue: 0.5)) }

    /// The one zap gold (#F2A33A): a warm step off the brand orange, so sats read
    /// as their own thing without leaving the palette. Was three ambers.
    static let havenZapGold = Color(red: 0.949, green: 0.639, blue: 0.227)

    /// The colour of a log line, by level.
    ///
    /// Three consoles carried their own copy of this switch and disagreed on
    /// the default: the relay dashboard and the Blossom pane painted INFO
    /// green, the Logs window painted it blue. Blue wins — green in this app
    /// means "running", and an INFO line is the *ordinary* case, so colouring
    /// every one of them with the health colour drowns out the dot that
    /// actually reports health.
    static func logLevel(_ level: String) -> Color {
        switch level {
        case "ERROR": return .red
        case "WARN": return .orange
        case "DEBUG": return .gray
        default: return .blue
        }
    }

    /// Vouched-for. The NIP-05 seal, a MUTUAL follow badge, and the vault's
    /// tag-based filters (Tagged, Whitelisted) all say the same thing about an
    /// account: someone stands behind it.
    ///
    /// Deliberately not [havenOnline]. That green means *running* — a service
    /// health signal — and the two were close enough (#33CC99 against #33D980)
    /// that the app had drifted into using a health colour for trust and a
    /// second, brighter teal (#33E6B3) for the same idea two views away.
    static let havenVerified = Color(light: Color(hex: 0x16916B), dark: Color(red: 0.2, green: 0.8, blue: 0.6))

    // MARK: - Surface ramp
    //
    // The app is OLED-black and had no elevation: four semantically distinct
    // surface tokens in PlatformCompat all resolved to `Color.black`, so a card,
    // the window behind it and the text field inside it painted the same #000.
    // Nothing sat on top of anything.
    //
    // These are Apple's own dark-mode grouped-background values. Two reasons for
    // borrowing them rather than inventing a ramp: they are literally what
    // `secondarySystemGroupedBackground` and friends resolve to on iOS in dark
    // mode, so macOS matching them *is* matching iOS; and the steps are wide
    // enough to see — an even ~8 points of L* each (0 / 10.3 / 18.1 / 24.5),
    // where a tighter ramp reads as one flat black on anything but an OLED panel.
    //
    // Use the semantic `platform*` tokens in views. These are the raw steps.

    /// The page. Windows, scroll backgrounds, anything the content sits *on*.
    static let surface0 = Color(lightHex: 0xF6F1EB, darkHex: 0x000000)    // light: warm paper

    /// Resting content: cards, grouped rows, controls, sheets.
    static let surface1 = Color(lightHex: 0xFFFFFF, darkHex: 0x1C1C1E)    // light: white cards

    /// Content on top of `surface1`: a field inside a card, a nested row.
    static let surface2 = Color(lightHex: 0xEFE9E2, darkHex: 0x2C2C2E)

    /// Transient overlays: menus, popovers, tooltips, pressed states.
    static let surface3 = Color(lightHex: 0xE2DBD3, darkHex: 0x3A3A3C)

    // MARK: - Borders
    //
    // `platformCardBorder` was white at 2% opacity, which is 1.03:1 against
    // black — not a subtle border, an absent one. Clearing the 3:1 floor for a
    // non-text boundary needs white at 36%, which is a hard, visible line and
    // wrong for a card whose fill already separates it. So the token splits:
    // a hairline for boundaries the surface ramp already carries, and a real
    // one for the cases where the border is the *only* cue.

    /// 1.35:1 on `surface0`. A seam, not a boundary. Only legitimate when the
    /// two sides already differ in fill.
    static let borderHairline = Color(lightHex: 0x1C1C1E, darkHex: 0xFFFFFF, lightAlpha: 0.16, darkAlpha: 0.14)

    /// 3.14:1 on `surface0`. Meets the non-text contrast floor. Use wherever the
    /// border alone communicates the control — an unselected checkbox, a focus
    /// ring, an empty drop target.
    static let borderStrong = Color(lightHex: 0x3A3A3C, darkHex: 0xFFFFFF, lightAlpha: 0.6, darkAlpha: 0.36)

    // MARK: - Ink, shade and labels
    //
    // Each flips with Settings › Appearance › Mode (AppAppearance)
    // (PLANS/NV_LIGHT_MODE_AND_CUSTOM_COLORS.md). Pick by what the colour sits on:
    //
    // - `ink`: text, icons, strokes and tints on the app's own surfaces
    //   (`surface0`-`surface3`, `platform*`). Use `.ink.opacity(x)` for the
    //   dimmer steps. Flips to near-black in light.
    // - `shade`: shadows and dimming drawn over the app's own surfaces. Flips to a
    //   warm brown-grey in light.
    // - `onAccent`: a label on an accent fill (`havenPurple` buttons, badges).
    //   Follows the accent, not the mode.
    // - Plain `.white` / `.black`: only where the backdrop is dark in every mode,
    //   such as text over a photo or video, the media viewer, the player, the
    //   trust globe, or a black scrim.

    static let ink = Color(lightHex: 0x000000, darkHex: 0xFFFFFF)
    /// Light: a warm brown-grey, so shadows look like the paper's own.
    static let shade = Color(lightHex: 0x3C2814, darkHex: 0x000000)
    @MainActor static var onAccent: Color { AccentPalette.current.onAccent }

    /// A note card's outline: the accent in dark, the dark greys in light
    /// (an orange ring round every card on the paper page was too loud).
    @MainActor
    static func cardLine(_ darkOpacity: Double) -> Color {
        Color(light: Color(hex: 0x1C1C1E).opacity(0.22), dark: .havenPurple.opacity(darkOpacity))
    }

    static var controlBackgroundColor: Color {
        #if os(macOS)
        return Color(NSColor.controlBackgroundColor)
        #else
        return Color(UIColor.systemBackground)
        #endif
    }
}

extension Font {
    @MainActor
    static func appSystem(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        let scale = ConfigService.shared.config.textSizeScale
        return .system(size: AppTypeScale.floored(size * CGFloat(scale), mac: isMac), weight: weight, design: design)
    }

    private static var isMac: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    @MainActor
    private static func app(_ style: AppTypeScale.Style, weight: Font.Weight) -> Font {
        .appSystem(size: AppTypeScale.size(style, mac: isMac), weight: weight)
    }

    // Scaled semantic text styles: iOS sizes on iPhone/iPad, macOS sizes on
    // the Mac (see AppTypeScale).
    @MainActor static var appLargeTitle: Font { app(.largeTitle, weight: .regular) }
    @MainActor static var appTitle: Font { app(.title, weight: .bold) }
    @MainActor static var appTitle2: Font { app(.title2, weight: .bold) }
    @MainActor static var appTitle3: Font { app(.title3, weight: .regular) }
    @MainActor static var appHeadline: Font { app(.headline, weight: .semibold) }
    @MainActor static var appBody: Font { app(.body, weight: .regular) }
    @MainActor static var appCallout: Font { app(.callout, weight: .regular) }
    @MainActor static var appSubheadline: Font { app(.subheadline, weight: .regular) }
    @MainActor static var appFootnote: Font { app(.footnote, weight: .regular) }
    @MainActor static var appCaption: Font { app(.caption, weight: .regular) }
    @MainActor static var appCaption2: Font { app(.caption2, weight: .regular) }
}
