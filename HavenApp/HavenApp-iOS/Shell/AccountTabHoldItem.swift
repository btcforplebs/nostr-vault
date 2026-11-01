import SwiftUI

// MARK: - Account Switcher Hold Picker

/// The avatar in the dock: tap runs `primary`; press and hold briefly, or
/// slide a little, and the accounts open in the dock's own hold menu
/// (`DockHoldMenu`), the same rows and timing as Feed and Vault. Slide onto
/// an account and let go to switch to it.
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
        DockHoldButton(onTap: primary, entries: entries, onPick: pick, label: label)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Profile")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Hold to switch account")
            .accessibilityAction { primary() }
            .accessibilityActions {
                ForEach(entries()) { entry in
                    Button("Switch to \(entry.title)") { pick(entry.id) }
                }
            }
    }

    private func entries() -> [DockHoldEntry] {
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

    private func pick(_ npub: String) {
        configService.switchActiveAccount(to: npub)
    }
}
