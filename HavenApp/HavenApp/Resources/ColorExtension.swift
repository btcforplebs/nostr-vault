import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

extension Color {
    // MARK: - Haven Purple Color Palette
    // Based on the app icon purple (#6B2D8F)

    /// Primary purple - main brand color
    static let havenPurple = Color(red: 0.42, green: 0.18, blue: 0.56) // #6B2D8F

    /// Lighter purple for accents and hover states
    static let havenPurpleLight = Color(red: 0.54, green: 0.30, blue: 0.69) // #8A4DB0

    /// Darker purple for depth and shadows
    static let havenPurpleDark = Color(red: 0.33, green: 0.14, blue: 0.44) // #542370

    /// Very light purple for backgrounds and subtle highlights
    static let havenPurplePale = Color(red: 0.42, green: 0.18, blue: 0.56).opacity(0.1)

    // MARK: - Platform Colors

    static var platformControlBackground: Color {
        #if canImport(AppKit)
        Color(NSColor.controlBackgroundColor)
        #else
        Color(UIColor.secondarySystemGroupedBackground)
        #endif
    }

    static var platformWindowBackground: Color {
        #if canImport(AppKit)
        Color(NSColor.windowBackgroundColor)
        #else
        Color(UIColor.systemBackground)
        #endif
    }

    static var platformTextBackground: Color {
        #if canImport(AppKit)
        Color(NSColor.textBackgroundColor)
        #else
        Color(UIColor.systemBackground)
        #endif
    }
}

// MARK: - Clipboard

struct PlatformClipboard {
    static func copy(_ string: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = string
        #endif
    }
}
