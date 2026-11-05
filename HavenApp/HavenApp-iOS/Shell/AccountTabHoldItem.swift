import SwiftUI

// MARK: - Account Switcher Hold Picker

/// The avatar in the dock: tap runs `primary`; press and hold briefly, or
/// slide a little, and the accounts open in the dock's own hold menu
/// (`DockHoldMenu`), the same rows and timing as Feed and Vault, but
/// centered on screen, growing up from the middle button. Slide onto
/// an account and let go to switch to it. Under the accounts, after a
/// divider: App settings and Mesh settings (Logen 2026-11-05), so the
/// menu opens with one account too.
///
/// The menu is drawn by `DockHoldMenuOverlay` over the whole screen, not
/// hosted on the button, so switching (which rebuilds every account-scoped
/// view, this button included) has no lifted snapshot to animate back.
struct AccountTabHoldItem<Label: View>: View {
    @ObservedObject var configService: ConfigService
    @ObservedObject var nostrService: NostrService
    let primary: () -> Void
    @ViewBuilder let label: () -> Label

    @ObservedObject private var unreadStore = AccountUnreadStore.shared

    var body: some View {
        DockHoldButton(onTap: primary, entries: entries, onPick: pick, centered: true, label: label)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Profile")
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

    /// Drawn bottom-up, so the settings rows go first: on screen they sit
    /// under the accounts, App settings above Mesh settings.
    private func entries() -> [DockHoldEntry] {
        ProfileMenuSettings.allCases.reversed().map { $0.entry } + accountEntries()
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

/// App settings and Mesh settings, under the accounts in the profile
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

    /// The dock menu row; App settings carries the divider that ends the accounts.
    var entry: DockHoldEntry {
        DockHoldEntry(id: rawValue, title: title, symbol: symbol, dividerAbove: self == .app)
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

    func body(content: Content) -> some View {
        content.sheet(item: $sheets.open) { page in
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
                                    .foregroundColor(.havenPurple)
                            }
                        }
                }
            case .mesh:
                MeshSettingsSheet(onClose: { sheets.open = nil })
                    .environmentObject(ConfigService.shared)
            }
        }
    }
}

extension View {
    /// Presents App settings or Mesh settings when the profile picture's menu picks one.
    func profileMenuSheets() -> some View { modifier(ProfileMenuSheetsHost()) }
}
