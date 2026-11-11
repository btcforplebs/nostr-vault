import SwiftUI

#if os(macOS)

/// The main window's rail: the iPad's and the web app's 68 pt rail, floating
/// on glass. Account on top, New Post under it (the web's place for it), the
/// sections with an icon over a small label, then Settings and the vault's
/// status at the foot. The selected section takes the accent colour, with no
/// fill behind it, as on both.
struct MacRail: View {
    @ObservedObject var configService: ConfigService
    @ObservedObject var relayManager: RelayProcessManager
    @ObservedObject private var nostrService = NostrService.shared
    @Binding var selectedTab: MenuBarView.Tab
    @Binding var settingsPaneRequest: SettingsView.SettingsTab?
    let onNewPost: () -> Void

    @State private var activeHex: String = ConfigService.shared.activeAccountHexPubkey

    var body: some View {
        VStack(spacing: 6) {
            MacGlassAccountMenu(
                configService: configService,
                avatarSize: 36,
                extraItems: [
                    ("View Profile", { selectedTab = .profile }),
                    ("App settings", { selectedTab = .settings }),
                    ("Mesh settings", {
                        settingsPaneRequest = .fipsMesh
                        selectedTab = .settings
                    }),
                ],
                compact: true
            )
            .padding(.top, 12)

            // None for a read-only sign-in: it can't sign a post.
            if configService.activeAccountCanSign {
                Button(action: onNewPost) {
                    Image(systemName: "square.and.pencil")
                        .font(.appSystem(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle().fill(LinearGradient(
                                colors: [.havenPurple, Color.havenPurple.opacity(0.72)],
                                startPoint: .top, endPoint: .bottom))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("New Post (⌘N)")
                .accessibilityLabel("New Post")
                .padding(.top, 6)
            }

            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 32, height: 1)
                .padding(.vertical, 6)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    MacRailItem(title: "Feed", selected: selectedTab == .feed) { selectedTab = .feed } icon: {
                        Image(systemName: "person.2.wave.2")
                    }
                    MacRailItem(title: "Search", selected: selectedTab == .search) { selectedTab = .search } icon: {
                        Image(systemName: "magnifyingglass")
                    }
                    MacRailItem(title: "Profile", selected: selectedTab == .profile) { selectedTab = .profile } icon: {
                        // The live account picture: the zap flight lands here.
                        AvatarView(url: nostrService.profiles[activeHex]?.pictureURL, pubkey: activeHex, size: 22)
                            .id(activeHex)
                            .overlay(Circle().stroke(selectedTab == .profile ? Color.havenPurple : .clear, lineWidth: 1.5))
                            .zapFlightOrigin()
                    }
                    MacRailItem(title: "WoT", selected: selectedTab == .wot) { selectedTab = .wot } icon: {
                        Image("WoTTab").renderingMode(.template).resizable().scaledToFit().frame(width: 22, height: 22)
                    }
                    MacRailItem(title: "Vault", selected: selectedTab == .notes) { selectedTab = .notes } icon: {
                        Image(systemName: "lock.rectangle.stack")
                    }
                    // The Vault (VaultView): what the return pill's arrow points at.
                    .vaultAnchor(.leading)
                    MacRailItem(title: "Media", selected: selectedTab == .media) { selectedTab = .media } icon: {
                        Image(systemName: "photo.on.rectangle")
                    }
                    MacRailItem(title: "Relay", selected: selectedTab == .relay) { selectedTab = .relay } icon: {
                        Image(systemName: "server.rack")
                    }
                }
            }

            Spacer(minLength: 4)

            MacRailItem(title: "Settings", selected: selectedTab == .settings) { selectedTab = .settings } icon: {
                Image(systemName: "gearshape")
            }

            statusFoot
                .padding(.bottom, 10)
        }
        .frame(width: MacShellLayout.railWidth)
        .macGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous), fallback: .regularMaterial)
        .onReceive(ConfigService.shared.$activeAccountHexPubkey) { newHex in
            if activeHex != newHex { activeHex = newHex }
        }
    }

    /// The vault's state as a dot and a word, as at the foot of the web rail.
    /// Opens the Relay page.
    private var statusFoot: some View {
        Button { selectedTab = .relay } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(MacVaultGlance.stateTint(relayManager))
                    .frame(width: 8, height: 8)
                    .shadow(color: MacVaultGlance.stateTint(relayManager).opacity(0.8), radius: 4)
                Text(MacVaultGlance.stateLabel(relayManager))
                    .font(.appSystem(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 58, height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(MacVaultGlance.connections(relayManager).map { "Vault: \($0)" } ?? "Vault status")
        .accessibilityLabel("Vault \(MacVaultGlance.stateLabel(relayManager))")
        .onAppear { MacVaultGlance.refreshConnections(relayManager) }
    }
}

/// One rail section: a 20 pt icon over a 10 pt label. Accent when selected,
/// a soft fill under the pointer.
struct MacRailItem<Icon: View>: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let icon: Icon

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                icon
                    .font(.appSystem(size: 19, weight: selected ? .semibold : .regular))
                    .frame(height: 24)
                Text(title)
                    .font(.appSystem(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(selected ? .havenPurple : Color.white.opacity(0.72))
            .frame(width: 58, height: 52)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.08 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#endif
