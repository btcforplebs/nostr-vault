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
    static var platformControlBackground: Color {
        #if canImport(AppKit)
        Color(NSColor.windowBackgroundColor)
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

    static var platformSecondaryGroupedBackground: Color {
        Color(red: 0.12, green: 0.12, blue: 0.16)
    }

    static var platformTertiaryGroupedBackground: Color {
        Color(red: 0.15, green: 0.15, blue: 0.2)
    }

    static var platformSeparator: Color {
        Color(red: 0.2, green: 0.2, blue: 0.25)
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

    @ViewBuilder
    func mediaTabViewStyleCompat() -> some View {
        #if os(iOS)
        self.tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
        #else
        self
        #endif
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
        if #available(iOS 26.0, *) {
            self.background(
                Color.clear
                    .overlay(
                        Capsule()
                            .glassEffect(.regular, in: .capsule)
                    )
            )
        } else {
            self
                .background(
                    Color.clear
                        .overlay(
                            Capsule()
                                .fill(.ultraThinMaterial)
                        )
                )
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(.white.opacity(0.15), lineWidth: 0.5)
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
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(.white.opacity(0.15), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
        }
        #else
        self
        #endif
    }
}

