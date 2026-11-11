import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Where a tapped link opens, and the presenter for the in-app browser.
///
/// Every `OpenURLAction` that used to fall through to `.systemAction` asks
/// `route(_:)`: a `.fips` site always opens here over the mesh (never in
/// the system browser, which would send its npub to DNS); an http(s) page
/// opens here while "Open Links in Nostr Vault" is on (the default); any
/// other scheme goes to the system as before.
///
/// The browser is presented over whatever is on top (a note or profile
/// sheet included): full screen on iPhone and iPad, its own window on the Mac.
@MainActor
enum InAppBrowser {
    /// Settings → Privacy → Open Links in Nostr Vault.
    static let openLinksKey = "browser.openLinksInApp"

    static var opensLinksInApp: Bool {
        UserDefaults.standard.object(forKey: openLinksKey) as? Bool ?? true
    }

    /// The answer for an `OpenURLAction`.
    static func route(_ url: URL) -> OpenURLAction.Result {
        switch FipsURL.route(url, inApp: opensLinksInApp) {
        case .mesh(let viewer): open(viewer)
        case .web(let page): open(page)
        // Shown as the browser's "can't open here" page, not handed on.
        case .refusedFips: open(url)
        case .system: return .systemAction
        }
        return .handled
    }

    static func openInSystemBrowser(_ url: URL) {
        // Never a .fips address: there it would resolve the npub through DNS.
        guard !FipsURL.isFipsHost(url.host), url.scheme?.lowercased() != FipsURL.scheme else { return }
        #if os(iOS)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }

    // MARK: - Presenting

    #if os(iOS)
    static func open(_ url: URL) {
        guard let top = topViewController() else { return }
        let model = InAppBrowserModel(url: url)
        weak var host: UIViewController?
        let close = {
            model.close()
            host?.dismiss(animated: true)
        }
        model.onExternal = { link in
            close()
            // nostr: comes back into the app through its URL scheme.
            UIApplication.shared.open(link)
        }
        let controller = UIHostingController(rootView: InAppBrowserView(model: model, onClose: close))
        controller.modalPresentationStyle = .fullScreen
        controller.overrideUserInterfaceStyle = .dark
        host = controller
        top.present(controller, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        // The app's own window, not the banner window that floats above it.
        let window = scene?.windows.first { $0.isKeyWindow }
            ?? scene?.windows.first { $0.windowLevel == .normal && !$0.isHidden }
        guard var top = window?.rootViewController else { return nil }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
    #else
    private static var windows: [NSWindow] = []

    static func open(_ url: URL) {
        let model = InAppBrowserModel(url: url)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 480, height: 400)
        window.title = "Nostr Vault Browser"
        window.tabbingMode = .preferred
        model.onExternal = { [weak window] link in
            window?.close()
            NSWorkspace.shared.open(link)
        }
        window.contentView = NSHostingView(rootView: InAppBrowserView(model: model) { [weak window] in window?.close() }
            .padding(.top, 22))
        windows.append(window)
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                model.close()
                windows.removeAll { $0 === window }
                if let token { NotificationCenter.default.removeObserver(token) }
            }
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    #endif
}
