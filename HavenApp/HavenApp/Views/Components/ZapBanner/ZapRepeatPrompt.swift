import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// "Your last zap may still be on its way. Zap again?" before a second zap to something whose
/// first zap has no receipt yet (ZapPendingGuard). Asked by ZapService itself, so every zap
/// button gets it. A system alert, not a SwiftUI one: the zap pills live in their own window
/// (SceneDelegate's banner window on iOS), and zaps start from sheets and menus all over the app.
@MainActor
enum ZapRepeatPrompt {
    static let title = "Zap again?"

    static func message(recipientName: String) -> String {
        "Your last zap to \(recipientName) may still be on its way. Zap again?"
    }

    /// True when the user chooses to zap again. No window to ask in counts as no.
    static func confirm(recipientName: String) async -> Bool {
        #if os(iOS)
        guard let top = topViewController() else { return false }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: title, message: message(recipientName: recipientName), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Don't zap", style: .cancel) { _ in continuation.resume(returning: false) })
            alert.addAction(UIAlertAction(title: "Zap again", style: .default) { _ in continuation.resume(returning: true) })
            top.present(alert, animated: true)
        }
        #else
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message(recipientName: recipientName)
        alert.addButton(withTitle: "Zap again")
        alert.addButton(withTitle: "Don't zap")
        return alert.runModal() == .alertFirstButtonReturn
        #endif
    }

    #if os(iOS)
    /// The app's own window, not the banner window above it (as InAppBrowser).
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow }
            ?? scene?.windows.first { $0.windowLevel == .normal && !$0.isHidden }
        guard var top = window?.rootViewController else { return nil }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
    #endif
}
