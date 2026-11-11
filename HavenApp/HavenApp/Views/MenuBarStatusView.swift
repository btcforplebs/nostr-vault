import SwiftUI

#if os(macOS)

/// The menu bar surface: a status panel, not a small copy of the app.
///
/// `MenuBarView` used to render here as well as in the popout window, branching
/// internally on `isPoppedOut`. That produced two classes of bug that this file
/// exists to remove:
///
/// * Things sized for the window leaked into the panel. Every sheet reachable
///   from the old default tab declared a `minWidth` larger than the 480pt panel
///   hosting it (the four `DashboardBreakdowns` at 520, `LogsView` at 600,
///   `ComposeView` at 500). A `MenuBarExtra(.window)` panel also dismisses on
///   resign-key, so a sheet raised from it fights its own host.
/// * Two of six tabs resolved to "open the full window" placeholders, and a
///   seventh view (`VaultView`) was reachable only by ⌘5 with no button at all.
///
/// The rule this panel keeps: **nothing here opens a sheet, and nothing here
/// starts a data load.** Anything that wants either belongs in the window.
/// Account switching therefore uses `Menu` rather than `.popover` — a `Menu` is
/// NSMenu-backed and lives outside the panel, so it survives the panel closing.
struct MenuBarStatusView: View {
    @ObservedObject var configService: ConfigService
    @ObservedObject var relayManager: RelayProcessManager

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismissPanel

    var body: some View {
        // The glass panel (spec §1.2); the intents below stay here.
        MacGlassVaultPanel(
            configService: configService,
            relayManager: relayManager,
            onToggleRelay: toggleRelay,
            onNewNote: newPost,
            onOpenApp: { openMainWindow() },
            onSettings: showSettings,
            onQuit: {
                dismissPanel()
                MacQuitConfirmation.confirmAndQuit()
            }
        )
        .onAppear {
            // Deliberately does not call statsService.refreshStats(). That runs a
            // recursive FileManager enumeration over four directories, and because
            // blossom/cache/thumbnails are children of the relay dir they are each
            // walked twice. Fine on a view you open on purpose; not fine on a panel
            // opened dozens of times a day against a full media archive.
            //
            // The app delegate has no SwiftUI environment, so a notification
            // tap cannot open the window scene by itself. This is the panel's
            // own `openWindow`, captured while it is mounted.
            MacWindow.openWindowAction = openWindow
        }
    }

    // MARK: - Intents

    private func toggleRelay() {
        if relayManager.isRunning {
            relayManager.stopRelay {
                relayManager.startRelay(config: configService.config)
            }
        } else {
            relayManager.startRelay(config: configService.config)
        }
    }

    private func newPost() {
        // Compose is a 500pt-wide sheet; it cannot be raised from a 340pt panel
        // that dismisses on resign-key. Open the window and let it compose there.
        //
        // Two mechanisms on purpose, and they are not redundant: the flag covers
        // a window that has yet to mount (cold start), the notification covers a
        // window already on screen, whose view tree will not appear again.
        // Whichever lands first consumes the flag, so it cannot compose twice.
        MacWindow.pendingCompose = true
        openMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .composeFromTabBar, object: 1)
        }
    }

    /// Opens Settings in front, as `openMainWindow` does for the main window.
    /// The app has no Dock icon (LSUIElement), so a Settings window opened
    /// without activating the app can land behind whatever app is in front.
    private func showSettings() {
        openSettings()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.identifier?.rawValue.contains("Settings") == true }?
                .makeKeyAndOrderFront(nil)
            dismissPanel()
        }
    }

    /// Single entry point for showing the main window.
    ///
    /// There were three copies of this before, and only one of them fronted the
    /// window — so the other two could open it *behind* the panel and read as
    /// doing nothing. Consolidated into `MacWindow.openMain`, which also no
    /// longer matches windows by title or hides panels by level.
    private func openMainWindow() {
        MacWindow.openMain(using: openWindow, dismissPanel: dismissPanel)
    }
}

// MARK: - Window management

enum MacWindow {
    static let mainWindowID = "viewer-window"
    static let mainWindowTitle = "Nostr Vault"

    /// Set when something outside the window asks it to open *composing*.
    ///
    /// The panel used to open the window and post `.composeFromTabBar` 150ms
    /// later. Every receiver of that notification lives inside the window's own
    /// view tree, and NotificationCenter does not replay — so on a cold start,
    /// or any launch where creating the window takes longer than the timer, the
    /// window appeared with no composer and the click was silently lost. A flag
    /// the window consumes when it mounts cannot miss.
    @MainActor static var pendingCompose = false

    /// Reads and clears the pending compose intent.
    @MainActor
    static func consumePendingCompose() -> Bool {
        defer { pendingCompose = false }
        return pendingCompose
    }

    /// A tapped notification that still has to be routed inside the main window.
    ///
    /// Parked for the same reason `pendingCompose` is: every receiver of the
    /// `.havenOpen*` routes lives in the main window's view tree, and a menu bar
    /// app spends most of its life with no main window at all. Posting a route
    /// to nobody is how a notification click ends up doing nothing.
    struct NotificationRoute {
        let type: String
        let id: String
        let npub: String?
    }

    /// A main-window tab asked for from the Go menu. Parked like
    /// `pendingCompose`: the window may not exist yet when the menu is used.
    @MainActor static var pendingTab: MenuBarView.Tab?

    @MainActor
    static func consumePendingTab() -> MenuBarView.Tab? {
        defer { pendingTab = nil }
        return pendingTab
    }

    /// Opens the main window on `tab`. The flag covers a window that has yet
    /// to mount, the notification one already on screen; whichever lands
    /// first consumes the flag.
    @MainActor
    static func show(tab: MenuBarView.Tab) {
        pendingTab = tab
        openMainFromAppKit()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .havenSelectMainTab, object: nil)
        }
    }

    /// Opens the main window with the composer, from anywhere: the same two
    /// mechanisms as `show(tab:)`.
    @MainActor
    static func newNote() {
        pendingCompose = true
        openMainFromAppKit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .composeFromTabBar, object: 1)
        }
    }

    @MainActor static var pendingRoute: NotificationRoute?

    /// Reads and clears the pending notification route.
    @MainActor
    static func consumePendingRoute() -> NotificationRoute? {
        defer { pendingRoute = nil }
        return pendingRoute
    }

    /// True while the main window's view tree is installed — which is exactly
    /// when the route receivers inside it can hear a post.
    ///
    /// Deliberately not `mainWindow() != nil`: an `NSWindow` can outlive the
    /// SwiftUI view tree it was hosting, so asking AppKit whether the window
    /// exists answers a different question than "is anyone listening".
    @MainActor static var isMainWindowMounted = false

    /// True while the main window is mounted and someone can see it: not in
    /// the Dock, not fully covered.
    @MainActor static var isMainWindowOnScreen: Bool {
        guard isMainWindowMounted, let window = mainWindow() else { return false }
        return !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    @MainActor static func isMainWindow(_ window: NSWindow) -> Bool {
        window === mainWindow()
    }

    /// `openWindow` captured from a mounted view, so AppKit-side callers — a
    /// notification tap arrives at the app delegate, which has no SwiftUI
    /// environment — can still open the window scene.
    @MainActor static var openWindowAction: OpenWindowAction?

    /// Opens and fronts the main window from a context with no environment.
    /// Falls back to fronting an existing window when no action was captured.
    @MainActor
    static func openMainFromAppKit() {
        if let openWindowAction {
            openMain(using: openWindowAction)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            mainWindow()?.makeKeyAndOrderFront(nil)
        }
    }

    /// Opens and fronts the main window, then dismisses the menu bar panel.
    ///
    /// Two heuristics were inherited from `MenuBarView` here. Both are gone:
    ///
    /// * **Finding the window by title string.** `window.title` is display text
    ///   — it is localised, and "Nostr Vault" is also a prefix of the setup
    ///   window's "Nostr Vault Setup". SwiftUI stamps `Window(id:)` scenes with
    ///   an `NSWindow.identifier` derived from that id, so we match on the id we
    ///   actually declared. The title comparison is kept only as a fallback, so
    ///   this cannot behave worse than what it replaces if the identifier format
    ///   ever changes under us.
    /// * **Dismissing the panel via `orderOut` on any untitled window above
    ///   `.normal` level.** That describes the `MenuBarExtra` panel, but it also
    ///   describes tooltips, popovers and other transient panels — including
    ///   ones we do not own. `MenuBarExtra(.window)` content can close itself
    ///   with the `dismiss` environment action, which is the supported way and
    ///   touches exactly one window. Callers outside the panel pass `nil`.
    @MainActor
    static func openMain(using openWindow: OpenWindowAction, dismissPanel: DismissAction? = nil) {
        openWindow(id: mainWindowID)

        // The NSWindow backing a freshly-opened SwiftUI scene is not in
        // `NSApp.windows` synchronously; one main-queue hop is enough for it to
        // exist. This is the only delay left in the sequence.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            mainWindow()?.makeKeyAndOrderFront(nil)
            dismissPanel?()
        }
    }

    /// The main window, located by the scene id we declared rather than by
    /// display text. Falls back to an exact title match.
    @MainActor
    private static func mainWindow() -> NSWindow? {
        if let byID = NSApp.windows.first(where: {
            $0.identifier?.rawValue.contains(mainWindowID) == true
        }) {
            return byID
        }
        return NSApp.windows.first { $0.title == mainWindowTitle }
    }
}

/// The menu bar icon.
///
/// It is the one view that exists from launch: the panel and the window only
/// mount when someone opens them. So this is where `openWindow` is captured for
/// AppKit callers. Before, the only capture was the panel's `onAppear`, and a
/// notification clicked after a cold or login launch, with the panel never
/// opened, had nothing to open the window with: the route was parked until the
/// window happened to be opened, sometimes hours later.
struct MenuBarIconLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image("MenuBarIcon")
            .accessibilityLabel("Nostr Vault")
            .onAppear {
                if MacWindow.openWindowAction == nil {
                    MacWindow.openWindowAction = openWindow
                }
            }
    }
}

/// The app's menus. Before this there were none: ⌘1–6 and ⌘N were hidden
/// zero-size buttons in the main window, shown in no menu and dead unless that
/// window had focus. ⌘, is the Settings scene's own App-menu item.
struct MacAppCommands: Commands {
    private static let goItems: [(title: String, tab: MenuBarView.Tab, key: KeyEquivalent)] = [
        ("Feed", .feed, "1"),
        ("Search", .search, "2"),
        ("My Profile", .profile, "3"),
        ("Relay", .relay, "4"),
        ("Notes", .notes, "5"),
        ("Media", .media, "6"),
    ]

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { MacWindow.newNote() }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandMenu("Go") {
            ForEach(Self.goItems, id: \.title) { item in
                Button(item.title) { MacWindow.show(tab: item.tab) }
                    .keyboardShortcut(item.key, modifiers: .command)
            }
        }
    }
}

#endif
