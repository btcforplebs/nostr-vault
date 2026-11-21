import SwiftUI

#if os(macOS)

/// The Mac's one Vault (3.3.0 "one Vault", spec
/// RESEARCH/NV_ONE_VAULT_SPEC_2026_11_21.md §2.2): the rail's Vault, Media,
/// Emoji and Relay items fold into one Vault item that shows the phone's
/// `VaultTabView`. The window's `MenuBarView.Tab` keeps `.media`, `.emoji`
/// and `.relay` as destinations inside it, so the Go menu (⌘5 ⌘6 ⌘7), the
/// status dot, Your space and the menu-bar panel land where they did.
///
/// Logen's two open calls are the two switches below. Flip one and rebuild;
/// nothing else changes.
enum MacVaultFold {
    /// Emoji is a page of the Vault, as on the phone. Off: Emoji keeps its
    /// own rail item.
    static let foldsEmoji = true
    /// The Vault Dashboard fills the window's page column. Off: it opens as a
    /// sheet over the Vault, as on the phone.
    static let dashboardIsPage = true

    /// The tabs the one Vault shows, which light the rail's Vault item.
    static func isVault(_ tab: MenuBarView.Tab) -> Bool {
        switch tab {
        case .notes, .media, .relay: return true
        case .emoji: return foldsEmoji
        default: return false
        }
    }

    /// The Vault page last shown (the pill's page), as a window tab: where the
    /// rail's Vault item and the dashboard's back button return to.
    @MainActor
    static func pageTab() -> MenuBarView.Tab {
        let section = VaultSection.shared
        if section.showsEmoji && foldsEmoji { return .emoji }
        return section.showsMedia ? .media : .notes
    }
}

/// The Vault page in the Mac window: the phone's pages under the phone's
/// page pill, and the Vault Dashboard as a page of its own. Keeps
/// `selectedTab` and `VaultSection` in step both ways, so a page picked from
/// the pill and a page picked from the Go menu are the same thing.
struct MacVaultPage: View {
    @Binding var selectedTab: MenuBarView.Tab
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @ObservedObject private var section = VaultSection.shared

    private var showsDashboard: Bool { MacVaultFold.dashboardIsPage && selectedTab == .relay }

    var body: some View {
        ZStack {
            // Kept alive under the dashboard: back to the Vault keeps its scroll.
            VStack(spacing: 0) {
                MacVaultPageBar(selectedTab: $selectedTab)
                Divider()
                VaultTabView { VaultView() }
            }
            .opacity(showsDashboard ? 0 : 1)
            .allowsHitTesting(!showsDashboard)
            .accessibilityHidden(showsDashboard)
            .disabled(showsDashboard)

            if showsDashboard {
                MacVaultDashboardPage(selectedTab: $selectedTab)
                    .transition(.opacity)
            }
        }
        .onAppear {
            section.isOnScreen = true
            showPage(for: selectedTab)
        }
        .onDisappear { section.isOnScreen = false }
        .onChange(of: selectedTab) { _, tab in showPage(for: tab) }
        .onChange(of: section.showsMedia) { _, _ in followSection() }
        .onChange(of: section.showsEmoji) { _, _ in followSection() }
        // The pill's last item, the Media page's Vault button and the menu
        // bar's signal button all ask for the dashboard this way.
        .onReceive(NotificationCenter.default.publisher(for: .openRelayDashboard)) { _ in
            if MacVaultFold.dashboardIsPage {
                selectedTab = .relay
            } else if section.showsMedia || section.showsEmoji {
                // The dashboard then opens over the relay's pages (VaultView).
                section.showsMedia = false
            }
        }
    }

    /// Go menu, rail or any opener → the Vault's page.
    private func showPage(for tab: MenuBarView.Tab) {
        switch tab {
        case .media:
            if !section.showsMedia { section.showsMedia = true }
        case .emoji:
            if !section.showsEmoji {
                section.showsMedia = false
                section.showsEmoji = true
            }
        case .notes:
            // The Vault item and ⌘5: the relay's pages, wherever the pill was.
            if section.showsMedia { section.showsMedia = false }
            if section.showsEmoji { section.showsEmoji = false }
        default:
            break
        }
    }

    /// Pill → the window's tab, so Your space and the toolbar follow the page.
    private func followSection() {
        guard selectedTab != .relay else { return }
        let tab: MenuBarView.Tab = section.showsEmoji ? .emoji : section.showsMedia ? .media : .notes
        if selectedTab != tab { selectedTab = tab }
    }
}

/// The strip over the Vault's pages: the phone's page pill on the left, the
/// Vault Dashboard on the right, coloured by the vault's state.
struct MacVaultPageBar: View {
    @Binding var selectedTab: MenuBarView.Tab
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var section = VaultSection.shared

    private var mode: VaultMode {
        section.showsEmoji ? .emoji : section.showsMedia ? .media : section.listMode
    }

    var body: some View {
        HStack(spacing: 12) {
            VaultModePill(mode: mode, zapsOnly: configService.config.zapsOnlyMode)
            Spacer(minLength: 8)
            Button {
                NotificationCenter.default.post(name: .openRelayDashboard, object: nil)
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(MacVaultGlance.stateTint(relayManager))
                        .frame(width: 8, height: 8)
                    Label(VaultDashboard.title, systemImage: VaultDashboard.symbol)
                        .font(.appSystem(size: 13, weight: .semibold))
                }
                .foregroundColor(.accentText)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Color.havenPurple.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Vault Dashboard (⌘7)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.platformSecondaryGroupedBackground)
    }
}

#endif
