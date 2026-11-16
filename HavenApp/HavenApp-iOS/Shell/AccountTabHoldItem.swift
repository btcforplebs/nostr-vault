import SwiftUI

// MARK: - Account Switcher Hold Picker

/// The avatar in the dock: tap runs `primary`; press and hold briefly, or
/// slide a little, and the accounts open in the dock's own hold menu
/// (`DockHoldMenu`), the same rows and timing as Feed and Vault, but
/// centered on screen, growing up from the middle button. Slide onto
/// an account and let go to switch to it. Above the accounts, then a
/// divider: App settings and Mesh settings (Logen 2026-11-06), so the
/// menu opens with one account too.
///
/// The menu is drawn by `DockHoldMenuOverlay` over the whole screen, not
/// hosted on the button, so switching (which rebuilds every account-scoped
/// view, this button included) has no lifted snapshot to animate back.
struct AccountTabHoldItem<Label: View>: View {
    @ObservedObject var configService: ConfigService
    @ObservedObject var nostrService: NostrService
    let primary: () -> Void
    /// On the Duo's side rail: the menu opens beside the picture, and a tap
    /// opens it too (the rail's picture has no other tap).
    var onRail = false
    @ViewBuilder let label: () -> Label

    @ObservedObject private var unreadStore = AccountUnreadStore.shared

    var body: some View {
        DockHoldButton(onTap: primary, entries: entries, onPick: pick, centered: !onRail,
                       beside: onRail, tapOpensMenu: onRail, label: label)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(onRail ? "Accounts" : "Profile")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Hold for your accounts and settings")
            .accessibilityAction { primary() }
            .accessibilityActions {
                ForEach(entries()) { entry in
                    Button(ProfileMenuSettings(rawValue: entry.id) == nil ? "Switch to \(entry.title)" : entry.title) {
                        pick(entry.id)
                    }
                }
            }
    }

    /// Drawn bottom-up, so the settings rows go last: on screen they sit at
    /// the top, App settings above Mesh settings, then a divider, then the accounts.
    private func entries() -> [DockHoldEntry] {
        accountEntries() + ProfileMenuSettings.allCases.reversed().map { $0.entry }
    }

    private func accountEntries() -> [DockHoldEntry] {
        let ownerNpub = configService.config.ownerNpub
        let currentNpub = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        return configService.allAccountNpubs.map { npub in
            let isOwner = npub == ownerNpub
            let isCurrent = currentNpub.isEmpty ? isOwner : npub == currentNpub
            let hex = Bech32.decode(npub)?.hexString ?? ""
            let profile = nostrService.profiles[hex]
            return DockHoldEntry(
                id: npub,
                title: profile?.bestName ?? (isOwner ? "Owner" : AccountSwitcherIdentity.shortNpub(npub)),
                symbol: "person.crop.circle",
                isCurrent: isCurrent,
                // The active account's news is on its own Vault tab.
                hasNews: !isCurrent && unreadStore.count(npub: npub) > 0,
                subtitle: AccountSwitcherIdentity.shortNpub(npub),
                avatarHex: hex,
                avatarURL: profile?.pictureURL
            )
        }
    }

    private func pick(_ id: String) {
        if let page = ProfileMenuSettings(rawValue: id) {
            ProfileMenuSheets.shared.open = page
        } else {
            configService.switchActiveAccount(to: id)
        }
    }
}

// MARK: - Settings rows

/// App settings and Mesh settings, above the accounts in the profile
/// picture's menus (the dock's hold menu and the iPad rail's list).
enum ProfileMenuSettings: String, CaseIterable, Identifiable {
    case app = "menu.appSettings"
    case mesh = "menu.meshSettings"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .app: "App settings"
        case .mesh: "Mesh settings"
        }
    }

    var symbol: String {
        switch self {
        case .app: "gearshape"
        case .mesh: "point.3.filled.connected.trianglepath.dotted"
        }
    }

    /// The dock menu row; Mesh settings, the lower of the two, carries the
    /// divider above the accounts.
    var entry: DockHoldEntry {
        DockHoldEntry(id: rawValue, title: title, symbol: symbol, dividerBelow: self == .mesh)
    }
}

/// Which settings screen the profile picture's menu opened. One host
/// (`profileMenuSheets()`, on the tab view) presents it, so a pick from the
/// dock or the rail opens the same sheet the Profile tab's buttons do.
@MainActor
final class ProfileMenuSheets: ObservableObject {
    static let shared = ProfileMenuSheets()
    @Published var open: ProfileMenuSettings?
}

private struct ProfileMenuSheetsHost: ViewModifier {
    @ObservedObject private var sheets = ProfileMenuSheets.shared
    let cameraStripWidth: CGFloat

    func body(content: Content) -> some View {
        content.sheet(item: $sheets.open) { page in
            Group {
            switch page {
            case .app:
                NavigationStack {
                    SettingsView()
                        .environmentObject(RelayProcessManager.shared)
                        .environmentObject(ConfigService.shared)
                        .environmentObject(NostrService.shared)
                        .environmentObject(StatsService.shared)
                        .navigationTitle("Settings")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { sheets.open = nil }
                                    .foregroundColor(.accentText)
                            }
                        }
                }
            case .mesh:
                MeshSettingsSheet(onClose: { sheets.open = nil })
                    .environmentObject(ConfigService.shared)
            }
            }
            .modifier(CameraStripSheet(stripWidth: cameraStripWidth))
        }
    }
}

extension View {
    /// Presents App settings or Mesh settings when the profile picture's menu picks one.
    /// `cameraStripWidth`: the iPhone Duo's camera strip on the right, 0 elsewhere.
    func profileMenuSheets(cameraStripWidth: CGFloat) -> some View {
        modifier(ProfileMenuSheetsHost(cameraStripWidth: cameraStripWidth))
    }
}

/// On the iPhone Duo a sheet is as wide as the screen, so its page ran on
/// under the clock in the camera strip on the right. There the sheet gets
/// the app's own column edge: the page keeps left of the strip (its safe
/// area) and a hairline marks where the strip starts, as the rail's edge
/// does on the main screens, so the clock sits in its strip, not on the
/// page. (The sheet's own surface can't be cleared: iOS 27 keeps a layer
/// under `presentationBackground`.) Elsewhere (`stripWidth` 0) unchanged.
struct CameraStripSheet: ViewModifier {
    let stripWidth: CGFloat

    /// The page's cards keep this far off the strip, as the feed's do off the rail.
    static let edgeGap: CGFloat = 16

    func body(content: Content) -> some View {
        if stripWidth > 0 {
            content
                // A list's margin here replaces the safe area rather than
                // adding to it, so it is the strip plus the gap.
                .contentMargins(.trailing, stripWidth + Self.edgeGap, for: .scrollContent)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(Color.ink.opacity(0.08))
                        .frame(width: 1)
                        .ignoresSafeArea(edges: .vertical)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        } else {
            content
        }
    }
}
