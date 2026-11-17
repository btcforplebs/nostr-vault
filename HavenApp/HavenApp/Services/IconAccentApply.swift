import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
import CoreImage
#endif

/// Puts the accent on the app icon (rules: IconAccent). iPhone/iPad: the
/// nearest preset's alternate icon via setAlternateIconName, which iOS
/// confirms with a pop-up, so it only runs when the icon would change. Mac:
/// the running app's icon (NSApp.applicationIconImage) tinted to the exact
/// colour; quitting puts the bundle icon back.
@MainActor
enum IconAccentApply {
    static var follows: Bool { UserDefaults.standard.bool(forKey: IconAccent.followsKey) }

    /// Whether this device can change its icon (the setting is hidden if not).
    static var isSupported: Bool {
        #if os(iOS)
        UIApplication.shared.supportsAlternateIcons
        #else
        true
        #endif
    }

    /// Match the icon to `accentHex` and the setting. Called when the accent
    /// changes (AccentPalette.current), at launch, and when the toggle flips.
    static func apply(accentHex: String) {
        #if os(iOS)
        let app = UIApplication.shared
        guard app.supportsAlternateIcons else { return }
        let want = IconAccent.iconName(accentHex: accentHex, follows: follows)
        guard app.alternateIconName != want else { return }
        // iOS refuses the change unless the app is in front: wait for it.
        guard app.applicationState == .active else {
            pendingHex = accentHex
            if observer == nil {
                observer = NotificationCenter.default.addObserver(
                    forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
                ) { _ in
                    MainActor.assumeIsolated {
                        if let observer { NotificationCenter.default.removeObserver(observer) }
                        observer = nil
                        if let hex = pendingHex { pendingHex = nil; apply(accentHex: hex) }
                    }
                }
            }
            return
        }
        app.setAlternateIconName(want) { error in
            if let error { print("[IconAccent] icon change failed: \(error.localizedDescription)") }
        }
        #else
        guard follows, let normalized = AccentPalette.normalize(accentHex), normalized != AccentPalette.defaultHex else {
            NSApp.applicationIconImage = nil // the bundle icon
            return
        }
        if let tinted = tintedIcon(hex: normalized) { NSApp.applicationIconImage = tinted }
        #endif
    }

    #if os(iOS)
    private static var observer: NSObjectProtocol?
    private static var pendingHex: String?
    #else
    /// The bundle's icon with its orange turned to `hex`.
    static func tintedIcon(hex: String) -> NSImage? {
        let base = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        var rect = NSRect(x: 0, y: 0, width: 512, height: 512)
        guard let cg = base.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let tint = IconAccent.macTint(toHex: hex)
        let hue = CIFilter(name: "CIHueAdjust", parameters: [
            kCIInputImageKey: CIImage(cgImage: cg), kCIInputAngleKey: tint.hueAngle,
        ])
        let sat = CIFilter(name: "CIColorControls", parameters: [
            kCIInputImageKey: hue?.outputImage as Any, kCIInputSaturationKey: tint.saturation,
        ])
        guard let out = sat?.outputImage,
              let result = CIContext().createCGImage(out, from: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        else { return nil }
        return NSImage(cgImage: result, size: NSSize(width: 512, height: 512))
    }
    #endif
}
