import SwiftUI

struct WalletView: View {
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @Environment(\.dismiss) private var dismiss

    enum WalletTab: String, CaseIterable, Identifiable {
        case onchain = "On-Chain"
        case lightning = "Lightning"
        var id: String { rawValue }
    }

    @State private var selectedTab: WalletTab = .onchain

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    ForEach(WalletTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                switch selectedTab {
                case .onchain:
                    WalletOnChainTab()
                        .environmentObject(nostrService)
                        .environmentObject(configService)
                case .lightning:
                    WalletLightningTab()
                        .environmentObject(nostrService)
                        .environmentObject(configService)
                }
            }
            .navigationTitle("Wallet")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundColor(.havenPurple)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 550)
        #endif
    }
}
