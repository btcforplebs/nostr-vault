import CoreGraphics

/// Point sizes behind the app's `Font.app*` text styles.
///
/// The iPhone sizes are Apple's iOS text styles (body 17). The Mac used them
/// too, so a Mac window read like a blown-up phone: 17 pt body next to the
/// 13 pt that Mac-only views hand-code, and Settings rows down at 8 pt.
/// On the Mac the same styles take the macOS sizes (body 13, headline 13
/// semibold, title2 17), and nothing drawn through `Font.appSystem` goes
/// below `macMinimum`.
enum AppTypeScale {
    enum Style: CaseIterable {
        case largeTitle, title, title2, title3, headline, body
        case callout, subheadline, footnote, caption, caption2
    }

    /// Smallest size the Mac draws through `Font.appSystem`.
    static let macMinimum: CGFloat = 10

    static func size(_ style: Style, mac: Bool) -> CGFloat {
        mac ? macSize(style) : iOSSize(style)
    }

    /// `size`, raised to `macMinimum` on the Mac.
    static func floored(_ size: CGFloat, mac: Bool) -> CGFloat {
        mac ? max(size, macMinimum) : size
    }

    private static func iOSSize(_ style: Style) -> CGFloat {
        switch style {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline: return 17
        case .body: return 17
        case .callout: return 16
        case .subheadline: return 15
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        }
    }

    private static func macSize(_ style: Style) -> CGFloat {
        switch style {
        case .largeTitle: return 26
        case .title: return 22
        case .title2: return 17
        case .title3: return 15
        case .headline: return 13
        case .body: return 13
        case .callout: return 12
        case .subheadline: return 11
        case .footnote: return 10
        case .caption: return 10
        case .caption2: return 10
        }
    }
}
