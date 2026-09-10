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
    @ObservedObject private var nostrService = NostrService.shared
    @ObservedObject private var statsService = StatsService.shared

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismissPanel

    @State private var activeHex: String = ConfigService.shared.activeAccountHexPubkey
    @State private var statusPulse = false

    private var isOwner: Bool {
        configService.config.activeAccountNpub
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasMultipleAccounts: Bool {
        configService.allAccountNpubs.count > 1
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.platformSeparator)
            relayCard
            Divider().background(Color.platformSeparator)
            actions
            Divider().background(Color.platformSeparator)
            footer
        }
        .frame(width: 340)
        .background(Color.platformWindowBackground)
        .onReceive(ConfigService.shared.$activeAccountHexPubkey) { newHex in
            if activeHex != newHex { activeHex = newHex }
        }
        .onAppear {
            // Deliberately does not call statsService.refreshStats(). That runs a
            // recursive FileManager enumeration over four directories, and because
            // blossom/cache/thumbnails are children of the relay dir they are each
            // walked twice. Fine on a view you open on purpose; not fine on a panel
            // opened dozens of times a day against a full media archive.
            statusPulse = Motion.ambientPulse != nil
        }
        .onChange(of: relayManager.isRunning) { _, running in
            statusPulse = running && Motion.ambientPulse != nil
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.appSystem(size: 15, weight: .bold))
                .foregroundColor(.havenPurple)

            Text("Nostr Vault")
                .font(.appSystem(size: 14, weight: .semibold))
                .foregroundColor(.primary)

            Spacer()

            statusPill
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(status.tint)
                .frame(width: 6, height: 6)
                .scaleEffect(status == .online && statusPulse ? Motion.pulseScale : 1.0)
                .animation(Motion.ambientPulse, value: statusPulse)

            Text(status.label)
                .font(.appSystem(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(status.tint.opacity(0.12))
        )
        .animation(Motion.fade, value: status)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Relay status")
        .accessibilityValue(status.label)
    }

    private enum RelayStatus: Equatable {
        case booting, syncing, online, offline

        var label: String {
            switch self {
            case .booting: return "Booting"
            case .syncing: return "Syncing"
            case .online: return "Online"
            case .offline: return "Offline"
            }
        }

        @MainActor
        var tint: Color {
            switch self {
            case .booting: return .havenPurple
            case .syncing: return .havenPurple
            case .online: return .havenOnline
            case .offline: return .red
            }
        }
    }

    private var status: RelayStatus {
        if relayManager.isBooting { return .booting }
        if relayManager.isRunning && relayManager.isWotSyncing { return .syncing }
        return relayManager.isRunning ? .online : .offline
    }

    // MARK: - Relay card

    private var relayCard: some View {
        VStack(spacing: 8) {
            statRow(
                label: "Port",
                value: relayManager.isRunning ? "\(configService.config.relayPort)" : placeholder
            )
            statRow(label: "Events", value: eventCountText)
            statRow(label: "Storage", value: storageText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.appSystem(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.appSystem(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.primary)
        }
        .accessibilityElement(children: .combine)
    }

    /// An em-dash, not a zero. The size stats are `@Published var … = 0` and are
    /// never persisted — only `loadedEventsCount` is seeded from `UserDefaults`.
    /// Rendering an uncomputed size as "0 bytes" would read as data loss on a
    /// full vault, so an unknown value is shown as unknown.
    private let placeholder = "—"

    private var eventCountText: String {
        statsService.loadedEventsCount > 0
            ? "\(statsService.loadedEventsCount)"
            : placeholder
    }

    private var storageText: String {
        statsService.storageSize > 0 ? statsService.formattedStorageSize : placeholder
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 8) {
            Button(action: toggleRelay) {
                actionLabel(
                    icon: relayManager.isRunning ? "arrow.clockwise" : "play.fill",
                    title: relayManager.isBooting
                        ? "Booting…"
                        : (relayManager.isRunning ? "Restart Relay" : "Start Relay"),
                    tint: relayManager.isRunning ? .havenPurple : .havenOnline
                )
            }
            .buttonStyle(.plain)
            .disabled(relayManager.isBooting)

            Button(action: newPost) {
                actionLabel(icon: "square.and.pencil", title: "New Post", tint: .havenPurple)
            }
            .buttonStyle(.plain)

            Button(action: { openMainWindow() }) {
                actionLabel(
                    icon: "arrow.up.forward.square",
                    title: "Open Full App",
                    tint: .havenPurple,
                    prominent: true
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func actionLabel(
        icon: String,
        title: String,
        tint: Color,
        prominent: Bool = false
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.appSystem(size: 12, weight: .semibold))
                .frame(width: 16)
            Text(title)
                .font(.appSystem(size: 13, weight: .semibold))
            Spacer()
        }
        .foregroundColor(prominent ? .white : tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(prominent ? tint : tint.opacity(0.12))
        )
        .contentShape(Rectangle())
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            accountControl

            Spacer()

            Button(action: { openSettings() }) {
                Image(systemName: "gearshape")
                    .font(.appSystem(size: 14))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")

            Button(action: { NSApp.terminate(nil) }) {
                Image(systemName: "power")
                    .font(.appSystem(size: 14))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Quit Nostr Vault")
            .accessibilityLabel("Quit Nostr Vault")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var accountName: String {
        nostrService.profiles[activeHex]?.bestName ?? (isOwner ? "Owner" : "User")
    }

    @ViewBuilder
    private var accountControl: some View {
        if hasMultipleAccounts {
            // NSMenu-backed, so it renders outside the panel and is not torn down
            // when the panel resigns key. A `.popover` here would be.
            Menu {
                ForEach(configService.allAccountNpubs, id: \.self) { npub in
                    accountMenuItem(npub: npub)
                }
            } label: {
                accountLabel
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Switch account")
            .accessibilityValue(accountName)
        } else {
            accountLabel
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Signed in as \(accountName)")
        }
    }

    @ViewBuilder
    private func accountMenuItem(npub: String) -> some View {
        let rowIsOwner = npub == configService.config.ownerNpub
        let activeNpub = configService.config.activeAccountNpub
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isActive = activeNpub.isEmpty ? rowIsOwner : npub == activeNpub
        let hex = Bech32.decode(npub)?.hexString ?? ""
        let name = nostrService.profiles[hex]?.bestName
            ?? (rowIsOwner ? "Owner" : String(npub.prefix(8)))

        Button {
            configService.switchActiveAccount(to: npub)
        } label: {
            if isActive {
                Label(name, systemImage: "checkmark")
            } else {
                Text(name)
            }
        }
    }

    private var accountLabel: some View {
        HStack(spacing: 8) {
            AvatarView(
                url: nostrService.profiles[activeHex]?.pictureURL,
                pubkey: activeHex,
                size: 22
            )
            .id(activeHex)
            .overlay(
                Circle().stroke(
                    isOwner ? Color.havenPurple.opacity(0.4) : Color.havenPurple.opacity(0.8),
                    lineWidth: isOwner ? 1.5 : 2
                )
            )

            Text(accountName)
                .font(.appSystem(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)

            if hasMultipleAccounts {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.appSystem(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
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

#endif
