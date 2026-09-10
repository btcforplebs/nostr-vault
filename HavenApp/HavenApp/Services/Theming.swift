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
