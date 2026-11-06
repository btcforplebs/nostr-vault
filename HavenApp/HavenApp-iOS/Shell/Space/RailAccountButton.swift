import SwiftUI

/// The account picture at the top of the iPad rail. A tap lists the
/// accounts on this device; a tap on one switches to it. Above them, then a
/// divider: App settings and Mesh settings, as in the dock's hold menu.
/// No hold or slide, unlike the iPhone dock's avatar.
struct RailAccountButton: View {
    @ObservedObject var configService: ConfigService
    @ObservedObject var nostrService: NostrService
    @ObservedObject private var unreadStore = AccountUnreadStore.shared
    @State private var showing = false

    private var activeHex: String { configService.activeAccountHexPubkey }
    private var othersHaveNews: Bool {
        configService.allAccountNpubs.contains { $0 != currentNpub && unreadStore.count(npub: $0) > 0 }
    }
    private var currentNpub: String {
        let npub = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        return npub.isEmpty ? configService.config.ownerNpub : npub
    }

    var body: some View {
        Button { showing = true } label: {
            AvatarView(url: nostrService.profiles[activeHex]?.pictureURL, pubkey: activeHex, size: 40)
                .overlay(Circle().stroke(Color.havenPurple.opacity(0.7), lineWidth: 2))
                .overlay(alignment: .topTrailing) {
                    NewsDot(isShown: othersHaveNews, size: 11).offset(x: 2, y: -2)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Accounts")
        .accessibilityValue(nostrService.profiles[activeHex]?.bestName ?? "")
        .accessibilityHint("Lists your accounts and settings")
        .popover(isPresented: $showing, arrowEdge: .leading) {
            AccountList(configService: configService, nostrService: nostrService, currentNpub: currentNpub) {
                showing = false
            }
        }
    }
}

private struct AccountList: View {
    @ObservedObject var configService: ConfigService
    @ObservedObject var nostrService: NostrService
    @ObservedObject private var unreadStore = AccountUnreadStore.shared
    let currentNpub: String
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ProfileMenuSettings.allCases) { page in
                settingsRow(page)
            }
            .padding(.top, 6)
            Divider()
                .padding(.vertical, 6)
            Text("Accounts")
                .font(.appSystem(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 6)
            ForEach(configService.allAccountNpubs, id: \.self) { npub in
                row(npub)
            }
        }
        .padding(.bottom, 8)
        .frame(width: 300)
        .presentationCompactAdaptation(.popover)
    }

    private func settingsRow(_ page: ProfileMenuSettings) -> some View {
        Button {
            done()
            // After the popover has gone: a sheet asked for while it is
            // still on screen is refused.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                ProfileMenuSheets.shared.open = page
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: page.symbol)
                    .font(.appSystem(size: 17, weight: .semibold))
                    .foregroundColor(.havenPurple)
                    .frame(width: 36)
                Text(page.title)
                    .font(.appSystem(size: 15, weight: .semibold))
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ npub: String) -> some View {
        let hex = Bech32.decode(npub)?.hexString ?? ""
        let profile = nostrService.profiles[hex]
        let isCurrent = npub == currentNpub
        let isOwner = npub == configService.config.ownerNpub
        return Button {
            if !isCurrent { configService.switchActiveAccount(to: npub) }
            done()
        } label: {
            HStack(spacing: 12) {
                AvatarView(url: profile?.pictureURL, pubkey: hex, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile?.bestName ?? (isOwner ? "Owner" : AccountSwitcherIdentity.shortNpub(npub)))
                        .font(.appSystem(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(AccountSwitcherIdentity.shortNpub(npub))
                        .font(.appSystem(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 8)
                if isCurrent {
                    Image(systemName: "checkmark").foregroundColor(.havenPurple)
                } else if unreadStore.count(npub: npub) > 0 {
                    NewsDot(isShown: true, size: 9)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .onAppear { if profile == nil, !hex.isEmpty { nostrService.fetchMissingProfiles(for: [hex]) } }
    }
}
