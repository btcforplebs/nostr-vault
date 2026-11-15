import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Settings › Appearance › Mode (PLANS/NV_LIGHT_MODE_AND_CUSTOM_COLORS.md).
/// Stored as `HavenConfig.appearanceMode`; dark unless the person picks otherwise.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case dark, light, system

    var id: String { rawValue }

    @MainActor var title: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .system: return AppAppearance.matchDeviceTitle
        }
    }
}

/// Puts the chosen mode on every window. The colour tokens (`Color.ink`,
/// `surface0`...) are dynamic, so they follow whatever the window says.
/// Screens that stay dark in every mode (the in-app browser, the trust globe,
/// the players) set dark on themselves and are left alone.
@MainActor
enum AppAppearance {
    static var mode: AppearanceMode {
        AppearanceMode(rawValue: ConfigService.shared.config.appearanceMode) ?? .dark
    }

    /// For `.preferredColorScheme`: nil follows the device.
    static var colorScheme: ColorScheme? {
        switch mode {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }

    static var matchDeviceTitle: String {
        #if os(macOS)
        return "Match Mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "Match iPad" : "Match Phone"
        #endif
    }

    #if os(iOS)
    static var interfaceStyle: UIUserInterfaceStyle {
        switch mode {
        case .dark: return .dark
        case .light: return .light
        case .system: return .unspecified
        }
    }
    #endif

    /// Call at launch and whenever the setting changes.
    static func apply() {
        #if os(macOS)
        switch mode {
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .system: NSApp.appearance = nil
        }
        #else
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                window.overrideUserInterfaceStyle = interfaceStyle
            }
        }
        #endif
    }
}

extension Color {
    /// One colour per mode, resolved by the window's light/dark trait.
    init(light: Color, dark: Color) {
        #if os(macOS)
        let l = NSColor(light), d = NSColor(dark)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l
        })
        #else
        let l = UIColor(light), d = UIColor(dark)
        self.init(uiColor: UIColor { t in (t.userInterfaceStyle == .light ? l : d).resolvedColor(with: t) })
        #endif
    }

    init(lightHex: UInt32, darkHex: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) {
        self.init(light: Color(hex: lightHex).opacity(lightAlpha), dark: Color(hex: darkHex).opacity(darkAlpha))
    }

    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
