import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Platform Image

#if canImport(AppKit)
typealias PlatformImage = NSImage
let isIOSDevice = false
#elseif canImport(UIKit)
typealias PlatformImage = UIImage
let isIOSDevice = true
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: platformImage)
        #elseif canImport(UIKit)
        self.init(uiImage: platformImage)
        #endif
    }
}

extension PlatformImage {
    #if canImport(UIKit)
    convenience init?(cgImage: CGImage, size: CGSize) {
        self.init(cgImage: cgImage)
    }
    #endif
}

// MARK: - Platform Colors

extension Color {
    @MainActor
    /// Resting content: cards, grouped rows, controls, sheets. NOT the page —
    /// a full-bleed background wants `platformWindowBackground`.
    static var platformControlBackground: Color {
        if ConfigService.shared.config.useOLED {
            return .surface1
        }
        #if canImport(AppKit)
        return Color(NSColor.windowBackgroundColor)
        #else
        return Color(UIColor.secondarySystemGroupedBackground)
        #endif
    }

    @MainActor
    /// The page. Everything else sits on this.
    static var platformWindowBackground: Color {
        if ConfigService.shared.config.useOLED {
            return .surface0
        }
        return Color(red: 0.08, green: 0.08, blue: 0.1)
    }

    @MainActor
    static var platformTextBackground: Color {
        if ConfigService.shared.config.useOLED {
            return .surface1
        }
        #if canImport(AppKit)
        return Color(NSColor.textBackgroundColor)
        #else
        return Color(UIColor.systemBackground)
        #endif
    }

    @MainActor
    static var platformSecondaryGroupedBackground: Color {
        if ConfigService.shared.config.useOLED {
            return .surface1
        }
        return Color(red: 0.12, green: 0.12, blue: 0.16)
    }

    @MainActor
    static var platformTertiaryGroupedBackground: Color {
        if ConfigService.shared.config.useOLED {
            return .surface2
        }
        return Color(red: 0.15, green: 0.15, blue: 0.2)
    }

    @MainActor
    static var platformSeparator: Color {
        if ConfigService.shared.config.useOLED {
            return .borderHairline
        }
        return Color(red: 0.2, green: 0.2, blue: 0.25)
    }

    /// Card/container backgrounds (StatsCard, RelayRow, KindRow, etc.)
    @MainActor
    static var platformCardBackground: Color {
        if ConfigService.shared.config.useOLED {
            return .surface1
        }
        return Color(red: 0.12, green: 0.12, blue: 0.12).opacity(0.6)
    }

    /// The seam around a card whose fill already separates it from the page.
    /// If the border is the only thing making a control visible, that control
    /// wants `Color.borderStrong` instead — this one does not meet 3:1.
    @MainActor
    static var platformCardBorder: Color {
        if ConfigService.shared.config.useOLED {
            return .borderHairline
        }
        return Color.white.opacity(0.04)
    }

    /// Console/terminal header background
    @MainActor
    static var platformConsoleHeaderBackground: Color {
        if ConfigService.shared.config.useOLED {
            return .surface2
        }
        return Color(red: 0.12, green: 0.12, blue: 0.15)
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

    /// Read string from clipboard (for URLs)
    static func getString() -> String? {
        #if canImport(AppKit)
        return NSPasteboard.general.string(forType: .string)
        #elseif canImport(UIKit)
        return UIPasteboard.general.string
        #endif
    }

    /// Read image data from clipboard
    static func getImageData() -> Data? {
        #if canImport(AppKit)
        guard let items = NSPasteboard.general.pasteboardItems else { return nil }
        for item in items {
            if let data = item.data(forType: NSPasteboard.PasteboardType.png) { return data }
            if let data = item.data(forType: NSPasteboard.PasteboardType.tiff) { return data }
            // Also check for generic image type
            if let data = item.data(forType: NSPasteboard.PasteboardType("public.image")) { return data }
        }
        return nil
        #elseif canImport(UIKit)
        // Try to get raw data in original format to preserve GIFs
        if let data = UIPasteboard.general.data(forPasteboardType: "com.compuserve.gif") { return data }
        if let data = UIPasteboard.general.data(forPasteboardType: "public.png") { return data }
        // Fallback: convert UIImage (loses GIF animation)
        return UIPasteboard.general.image?.jpegData(compressionQuality: 0.85)
        #endif
    }

    /// Check if clipboard contains an image
    static func hasImage() -> Bool {
        #if canImport(AppKit)
        guard let types = NSPasteboard.general.types else { return false }
        return types.contains(.png) || types.contains(.tiff)
            || types.contains(NSPasteboard.PasteboardType("public.image"))
        #elseif canImport(UIKit)
        return UIPasteboard.general.hasImages
        #endif
    }
}

// MARK: - Open URL

struct PlatformURL {
    @MainActor
    static func open(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }
}

// MARK: - Screen Scale

struct PlatformScreen {
    static var backingScaleFactor: CGFloat {
        #if canImport(AppKit)
        NSScreen.main?.backingScaleFactor ?? 2.0
        #else
        UIScreen.main.scale
        #endif
    }
}

// MARK: - Form Style Compat

extension View {
    @ViewBuilder
    func groupedFormStyleCompat() -> some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            self.formStyle(.grouped)
        } else {
            self
        }
    }

}

#if os(iOS)
/// Walks up to the presenting UIHostingController's view and clears its
/// background so a `.fullScreenCover` can show a translucent backdrop instead
/// of the default opaque system background.
struct ClearFullScreenBackground: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            view.superview?.superview?.backgroundColor = .clear
        }
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif

extension View {
    @ViewBuilder
    func applyGlassCapsule() -> some View {
        #if os(iOS)
        let isOLED = ConfigService.shared.config.useOLED
        if #available(iOS 26.0, *) {
            self.background(
                Color.clear
                    .overlay(
                        Capsule()
                            .glassEffect(.clear, in: .capsule)
                    )
            )
        } else {
            self
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .opacity(isOLED ? 0.65 : 0.35)
                )
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(.white.opacity(isOLED ? 0.20 : 0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 4)
        }
        #else
        self
        #endif
    }
    
    @ViewBuilder
    func applyGlassCircle() -> some View {
        #if os(iOS)
        let isOLED = ConfigService.shared.config.useOLED
        if #available(iOS 26.0, *) {
            self.background(
                Color.clear
                    .overlay(
                        Circle()
                            .glassEffect(.regular, in: .circle)
                    )
            )
        } else {
            self
                .background(
                    Color.clear
                        .overlay(
                            Circle()
                                .fill(.ultraThinMaterial)
                                .opacity(isOLED ? 0.85 : 1.0)
                        )
                )
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(.white.opacity(isOLED ? 0.30 : 0.15), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func applyGlassRect(cornerRadius: CGFloat = 16) -> some View {
        #if os(iOS)
        let isOLED = ConfigService.shared.config.useOLED
        if #available(iOS 26.0, *) {
            self.background(
                Color.clear
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
                    )
            )
        } else {
            self
                .background(
                    Color.clear
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .fill(.ultraThinMaterial)
                                .opacity(isOLED ? 0.85 : 1.0)
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(.white.opacity(isOLED ? 0.30 : 0.15), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
        }
        #else
        self
        #endif
    }

    /// Consistent bottom padding so scroll content clears the floating tab bar on iOS.
    @ViewBuilder
    func tabBarBottomPadding() -> some View {
        self
    }

    /// Conditionally apply a modifier only when a condition is true.
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

