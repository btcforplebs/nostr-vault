import SwiftUI

#if os(macOS)

/// The Vault Dashboard as a page of the Mac window (MacVaultFold.dashboardIsPage),
/// in place of the Relay rail item's console. The same `VaultDashboardView`
/// the phone shows, at a reading width. A wide window keeps the console's
/// form: the live activity panel at full height beside it.
struct MacVaultDashboardPage: View {
    @Binding var selectedTab: MenuBarView.Tab
    @EnvironmentObject var relayManager: RelayProcessManager

    /// Below this the activity panel would squeeze the dashboard; it stays a card.
    private static let besideWidth: CGFloat = 1_040

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { geo in
                let beside = geo.size.width >= Self.besideWidth
                HStack(alignment: .top, spacing: 16) {
                    NavigationStack {
                        VaultDashboardView()
                            .environment(\.vaultActivityBeside, beside)
                            .frame(maxWidth: 680)
                            .frame(maxWidth: .infinity)
                    }
                    if beside {
                        RelayActivityPanel(logStore: relayManager.logStore)
                            .frame(width: min(520, geo.size.width * 0.42))
                            .padding(.vertical, 12)
                            .padding(.trailing, 12)
                    }
                }
            }
        }
        .background(Color.platformWindowBackground)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                selectedTab = MacVaultFold.pageTab()
            } label: {
                Label("Vault", systemImage: "chevron.left")
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(.accentText)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Back to the Vault (Esc)")

            Label(VaultDashboard.title, systemImage: VaultDashboard.symbol)
                .labelStyle(.titleAndIcon)
                .font(.appSystem(size: 15, weight: .bold, design: .rounded))
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(Color.platformSecondaryGroupedBackground)
    }
}

#endif
