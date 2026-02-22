import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Platform Image

#if canImport(AppKit)
typealias PlatformImage = NSImage
#elseif canImport(UIKit)
typealias PlatformImage = UIImage
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
