import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum AppTheme: String, CaseIterable, Identifiable {
    case purple = "purple"
    case blue = "blue"
    case green = "green"
    case orange = "orange"
    case pink = "pink"
    case slate = "slate"
    
    var id: String { self.rawValue }
    
    var displayName: String {
        switch self {
        case .purple: return "Haven Purple"
        case .blue: return "Ocean Blue"
        case .green: return "Emerald Green"
        case .orange: return "Sunset Orange"
        case .pink: return "Rose Pink"
        case .slate: return "Monochrome Slate"
        }
    }
    
    var primaryColor: Color {
        switch self {
        case .purple: return Color(red: 0.42, green: 0.18, blue: 0.56) // #6B2D8F
        case .blue: return Color(red: 0.09, green: 0.45, blue: 0.74)   // #1773BD - Rich Ocean Blue
        case .green: return Color(red: 0.13, green: 0.58, blue: 0.41)  // #219469 - Emerald Green
        case .orange: return Color(red: 0.90, green: 0.45, blue: 0.15) // #E67326 - Sunset Orange
        case .pink: return Color(red: 0.88, green: 0.22, blue: 0.44)   // #E03870 - Rose Pink
        case .slate: return Color(red: 0.45, green: 0.50, blue: 0.55)  // #73808C - Modern Slate
        }
    }
    
    var lightColor: Color {
        switch self {
        case .purple: return Color(red: 0.54, green: 0.30, blue: 0.69) // #8A4DB0
        case .blue: return Color(red: 0.20, green: 0.58, blue: 0.88)   // #3394E0
        case .green: return Color(red: 0.22, green: 0.73, blue: 0.53)  // #38BA87
        case .orange: return Color(red: 0.98, green: 0.58, blue: 0.28) // #FA9447
        case .pink: return Color(red: 0.95, green: 0.35, blue: 0.58)   // #F25994
        case .slate: return Color(red: 0.58, green: 0.63, blue: 0.68)  // #94A1AE
        }
    }
    
    var darkColor: Color {
        switch self {
        case .purple: return Color(red: 0.33, green: 0.14, blue: 0.44) // #542370
        case .blue: return Color(red: 0.05, green: 0.32, blue: 0.55)   // #0D528C
        case .green: return Color(red: 0.08, green: 0.42, blue: 0.29)  // #146B4A
        case .orange: return Color(red: 0.70, green: 0.32, blue: 0.08) // #B35214
        case .pink: return Color(red: 0.68, green: 0.13, blue: 0.31)   // #AE214F
        case .slate: return Color(red: 0.32, green: 0.37, blue: 0.41)  // #525E69
        }
    }
    
    var paleColor: Color {
        return primaryColor.opacity(0.1)
    }
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
    
    static var controlBackgroundColor: Color {
        #if os(macOS)
        return Color(NSColor.controlBackgroundColor)
        #else
        return Color(UIColor.systemBackground)
        #endif
    }
}
