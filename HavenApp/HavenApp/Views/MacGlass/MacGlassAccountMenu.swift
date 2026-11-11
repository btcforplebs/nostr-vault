import SwiftUI

#if os(macOS)

/// The compact avatar + name account switcher, for the vault panel and the
/// top of the glass sidebar.
///
/// NSMenu-backed (`Menu`), so it renders outside the panel and survives the
/// panel resigning key, which a `.popover` would not. `.button` + `.plain`,
/// not `.borderlessButton`: the borderless style hands the label to an
/// NSPopUpButton, which drops the avatar's frame and clip.
struct MacGlassAccountMenu: View {
    @ObservedObject var configService: ConfigService
    @ObservedObject private var nostrService = NostrService.shared
    @ObservedObject private var unreadStore = AccountUnreadStore.shared
    // Shows pictures the window already cached; starts no loads.
    @ObservedObject private var accountAvatars = AccountMenuAvatars.shared

    var avatarSize: CGFloat = 22
    /// Extra rows shown above the accounts (the sidebar's settings shortcuts).
    var extraItems: [(title: String, action: () -> Void)] = []

    @State private var activeHex: String = ConfigService.shared.activeAccountHexPubkey

    private var isOwner: Bool {
        configService.config.activeAccountNpub
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasMultipleAccounts: Bool { configService.allAccountNpubs.count > 1 }

    private var accountName: String {
        nostrService.profiles[activeHex]?.bestName ?? (isOwner ? "Owner" : "User")
    }

    var body: some View {
        Group {
            if hasMultipleAccounts || !extraItems.isEmpty {
                Menu {
                    ForEach(Array(extraItems.enumerated()), id: \.offset) { _, item in
                        Button(item.title, action: item.action)
                    }
                    if !extraItems.isEmpty && hasMultipleAccounts { Divider() }
                    if hasMultipleAccounts {
                        ForEach(configService.allAccountNpubs, id: \.self) { npub in
                            row(npub: npub)
                        }
                    }
                } label: {
                    label
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Account")
                .accessibilityValue(accountName)
            } else {
                label
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Signed in as \(accountName)")
            }
        }
        .onReceive(ConfigService.shared.$activeAccountHexPubkey) { newHex in
            if activeHex != newHex { activeHex = newHex }
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            AvatarView(
                url: nostrService.profiles[activeHex]?.pictureURL,
                pubkey: activeHex,
                size: avatarSize
            )
            .id(activeHex)
            .overlay(Circle().stroke(Color.havenPurple.opacity(isOwner ? 0.4 : 0.8), lineWidth: isOwner ? 1.5 : 2))

            Text(accountName)
                .font(.appSystem(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)

            if hasMultipleAccounts || !extraItems.isEmpty {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.appSystem(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func row(npub: String) -> some View {
        let rowIsOwner = npub == configService.config.ownerNpub
        let activeNpub = configService.config.activeAccountNpub
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isActive = activeNpub.isEmpty ? rowIsOwner : npub == activeNpub
        let hex = Bech32.decode(npub)?.hexString ?? ""
        let profile = nostrService.profiles[hex]
        AccountMenuItem(
            npub: npub,
            name: profile?.bestName
                ?? (rowIsOwner ? "Owner" : AccountSwitcherIdentity.shortNpub(npub)),
            pictureURL: profile?.pictureURL,
            isActive: isActive,
            unread: unreadStore.count(npub: npub)
        ) {
            configService.switchActiveAccount(to: npub)
        }
    }
}

#endif
