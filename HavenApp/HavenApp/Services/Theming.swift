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

    var primaryColor: Color { Color(red: 0.90, green: 0.45, blue: 0.15) } // #E67326
    var lightColor: Color { Color(red: 0.98, green: 0.58, blue: 0.28) }   // #FA9447
    var darkColor: Color { Color(red: 0.70, green: 0.32, blue: 0.08) }    // #B35214
    var paleColor: Color { primaryColor.opacity(0.1) }
}

extension Color {
    @MainActor
    static var havenPurple: Color {
        let themeName = ConfigService.shared.config.themeColor
        return AppTheme(rawValue: themeName)?.primaryColor ?? AppTheme.orange.primaryColor
    }

    @MainActor
    static var havenPurpleLight: Color {
        let themeName = ConfigService.shared.config.themeColor
        return AppTheme(rawValue: themeName)?.lightColor ?? AppTheme.orange.lightColor
    }

    @MainActor
    static var havenPurpleDark: Color {
        let themeName = ConfigService.shared.config.themeColor
        return AppTheme(rawValue: themeName)?.darkColor ?? AppTheme.orange.darkColor
    }

    @MainActor
    static var havenPurplePale: Color {
        let themeName = ConfigService.shared.config.themeColor
        return AppTheme(rawValue: themeName)?.paleColor ?? AppTheme.orange.paleColor
    }
    
    // Colors are now primarily defined here to ensure project-wide availability

    /// The one "things are working" green in the app. Status dots, running-state
    /// pills, and go-ahead buttons (Start Relay) all mean the same thing and
    /// should read as the same color — not a system default in one place and a
    /// custom mint somewhere else.
    static var havenOnline: Color { Color(red: 0.2, green: 0.85, blue: 0.5) }

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
    static let havenVerified = Color(red: 0.2, green: 0.8, blue: 0.6)

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
    static let surface0 = Color(red: 0.0, green: 0.0, blue: 0.0)          // #000000

    /// Resting content: cards, grouped rows, controls, sheets.
    static let surface1 = Color(red: 0.110, green: 0.110, blue: 0.118)    // #1C1C1E

    /// Content on top of `surface1`: a field inside a card, a nested row.
    static let surface2 = Color(red: 0.173, green: 0.173, blue: 0.180)    // #2C2C2E

    /// Transient overlays: menus, popovers, tooltips, pressed states.
    static let surface3 = Color(red: 0.227, green: 0.227, blue: 0.235)    // #3A3A3C

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
    static let borderHairline = Color.white.opacity(0.14)

    /// 3.14:1 on `surface0`. Meets the non-text contrast floor. Use wherever the
    /// border alone communicates the control — an unselected checkbox, a focus
    /// ring, an empty drop target.
    static let borderStrong = Color.white.opacity(0.36)

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
        return .system(size: size * CGFloat(scale), weight: weight, design: design)
    }

    // Scaled semantic font styles (approximate HIG base sizes)
    @MainActor static var appLargeTitle: Font { .appSystem(size: 34, weight: .regular) }
    @MainActor static var appTitle: Font { .appSystem(size: 28, weight: .bold) }
    @MainActor static var appTitle2: Font { .appSystem(size: 22, weight: .bold) }
    @MainActor static var appTitle3: Font { .appSystem(size: 20, weight: .regular) }
    @MainActor static var appHeadline: Font { .appSystem(size: 17, weight: .semibold) }
    @MainActor static var appBody: Font { .appSystem(size: 17, weight: .regular) }
    @MainActor static var appCallout: Font { .appSystem(size: 16, weight: .regular) }
    @MainActor static var appSubheadline: Font { .appSystem(size: 15, weight: .regular) }
    @MainActor static var appFootnote: Font { .appSystem(size: 13, weight: .regular) }
    @MainActor static var appCaption: Font { .appSystem(size: 12, weight: .regular) }
    @MainActor static var appCaption2: Font { .appSystem(size: 11, weight: .regular) }
}
