import SwiftUI

#if os(macOS)

/// The main window's floating glass sidebar (spec §1.3).
///
/// Top: the account menu. Then two sections, Vault and Social, then
/// Settings. Restart and Quit are gone from here: Restart lives in the
/// toolbar and the vault panel, Quit in the app menu (⌘Q). New Post is a
/// toolbar button. The footer is one live status chip.
struct MacGlassSidebar: View {
    @ObservedObject var configService: ConfigService
    @ObservedObject var relayManager: RelayProcessManager
    @ObservedObject private var nostrService = NostrService.shared
    @Binding var selectedTab: MenuBarView.Tab
    @Binding var settingsPaneRequest: SettingsView.SettingsTab?

    static let width: CGFloat = 220
    static let inset: CGFloat = 10

    @State private var activeHex: String = ConfigService.shared.activeAccountHexPubkey

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGlassAccountMenu(
                configService: configService,
                avatarSize: 26,
                extraItems: [
                    ("View Profile", { selectedTab = .profile }),
                    ("App settings", { selectedTab = .settings }),
                    ("Mesh settings", { openSettings(.fipsMesh) }),
                ]
            )
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    sectionHeader("Vault")
                    row("Overview", icon: "server.rack", tab: .relay)
                    Button { openSettings(.fipsMesh) } label: {
                        rowLabel("Devices", icon: "point.3.connected.trianglepath.dotted", selected: false)
                    }
                    .buttonStyle(.plain)
                    .help("My Devices on the mesh")

                    sectionHeader("Social").padding(.top, 10)
                    row("Feed", icon: "list.bullet.rectangle.portrait", tab: .feed)
                    row("Search", icon: "magnifyingglass", tab: .search)
                    row("Notes", icon: "note.text", tab: .notes)
                        // The Vault (VaultView): what the return pill's arrow points at.
                        .vaultAnchor(.leading)
                    row("Media", icon: "photo.on.rectangle", tab: .media)
                    profileRow
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 8)

            row("Settings", icon: "gearshape", tab: .settings)
                .padding(.horizontal, 8)

            statusChip
                .padding(10)
        }
        .frame(width: Self.width)
        .macGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), fallback: .regularMaterial)
        .onReceive(ConfigService.shared.$activeAccountHexPubkey) { newHex in
            if activeHex != newHex { activeHex = newHex }
        }
    }

    private func openSettings(_ pane: SettingsView.SettingsTab) {
        settingsPaneRequest = pane
        selectedTab = .settings
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.appSystem(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
    }

    private func row(_ title: String, icon: String, tab: MenuBarView.Tab) -> some View {
        Button { selectedTab = tab } label: {
            rowLabel(title, icon: icon, selected: selectedTab == tab)
        }
        .buttonStyle(.plain)
    }

    private func rowLabel(_ title: String, icon: String, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.appSystem(size: 13, weight: .medium))
                .frame(width: 18)
                .foregroundColor(selected ? .white : .havenPurple)
            Text(title)
                .font(.appSystem(size: 13, weight: selected ? .semibold : .medium))
                .foregroundColor(selected ? .white : .primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.havenPurple.opacity(0.85) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    /// My Profile with the live account avatar: the zap flight lands here.
    private var profileRow: some View {
        Button { selectedTab = .profile } label: {
            HStack(spacing: 10) {
                AvatarView(url: nostrService.profiles[activeHex]?.pictureURL, pubkey: activeHex, size: 18)
                    .id(activeHex)
                    .frame(width: 18, height: 18)
                    .zapFlightOrigin()
                Text("My Profile")
                    .font(.appSystem(size: 13, weight: selectedTab == .profile ? .semibold : .medium))
                    .foregroundColor(selectedTab == .profile ? .white : .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selectedTab == .profile ? Color.havenPurple.opacity(0.85) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "● Running · 2 connected". Opens Overview (the Activity inspector is
    /// not built yet).
    private var statusChip: some View {
        Button { selectedTab = .relay } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(MacVaultGlance.stateTint(relayManager))
                    .frame(width: 7, height: 7)
                Text(chipText)
                    .font(.appSystem(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            // Plain fill: glass inside the glass sidebar would stack two layers.
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Vault status")
        .onAppear { MacVaultGlance.refreshConnections(relayManager) }
    }

    private var chipText: String {
        let state = MacVaultGlance.stateLabel(relayManager)
        guard let connections = MacVaultGlance.connections(relayManager) else { return state }
        return "\(state) · \(connections)"
    }
}

#endif
