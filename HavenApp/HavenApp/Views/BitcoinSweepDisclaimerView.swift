import SwiftUI

struct BitcoinSweepDisclaimerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showSweepFlow = false
    @State private var balance: Int = 0

    var body: some View {
        ZStack {
            // Full screen background
            Color.platformWindowBackground
                .ignoresSafeArea()

            if showSweepFlow {
                BitcoinSweepView(balanceSats: balance)
                    .transition(.move(edge: .trailing))
            } else {
                disclaimerContent
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showSweepFlow)
        .onAppear {
            loadBalance()
        }
    }

    private var disclaimerContent: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        // Header with warning icon
                        VStack(spacing: 16) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 56))
                                .foregroundColor(.orange)

                            VStack(spacing: 8) {
                                Text("Important Security Warning")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundColor(.white)

                                Text("Sweeping your wallet requires careful consideration")
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                        .padding(.horizontal, 20)

                        // Main warning sections
                        VStack(alignment: .leading, spacing: 20) {
                            // Cold Storage Warning
                            warningCard(
                                title: "⛔ Do NOT Sweep to Cold Storage",
                                description: "Never sweep your Bitcoin directly to a hardware wallet or cold storage address. Sweeping creates an on-chain transaction that is permanently visible to the network.",
                                highlights: [
                                    "Your wallet address will be exposed on the blockchain",
                                    "Cold wallets may not handle single sweeps correctly",
                                    "This defeats the privacy purpose of the address"
                                ],
                                backgroundColor: Color.red.opacity(0.1),
                                borderColor: Color.red.opacity(0.3)
                            )

                            // KYC Warning
                            warningCard(
                                title: "⛔ Do NOT Sweep to KYC-Linked Wallets",
                                description: "Never sweep your Bitcoin to an exchange, custodial wallet, or any service that has your personal information (KYC). This links your anonymous Bitcoin to your identity permanently.",
                                highlights: [
                                    "Exchanges, banks, and centralized services have KYC",
                                    "Exchanges can freeze, restrict, or seize your coins",
                                    "Creates a permanent transaction record linking you to these coins",
                                    "Future regulatory actions could affect your funds"
                                ],
                                backgroundColor: Color.red.opacity(0.1),
                                borderColor: Color.red.opacity(0.3)
                            )

                            // Safe Options
                            warningCard(
                                title: "✅ Safe Sweep Destinations",
                                description: "Only sweep to addresses that meet BOTH of these criteria:",
                                highlights: [
                                    "Private self-custody address you control (not KYC-linked)",
                                    "Another Nostr key you own that you've verified as a Taproot address"
                                ],
                                backgroundColor: Color.green.opacity(0.08),
                                borderColor: Color.green.opacity(0.3)
                            )

                            // Privacy Notice
                            warningCard(
                                title: "🔒 Privacy Notice",
                                description: "Sweeping your wallet reveals the entire balance on the blockchain at that moment. Consider the timing and implications for your privacy.",
                                highlights: [],
                                backgroundColor: Color.blue.opacity(0.08),
                                borderColor: Color.blue.opacity(0.3)
                            )
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 20)
                    }
                }

                Divider()

                // Action Buttons
                VStack(spacing: 12) {
                    // Cancel Button
                    Button(action: { dismiss() }) {
                        Text("Cancel")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.secondary.opacity(0.3))
                            .cornerRadius(12)
                    }
                    .buttonStyle(.plain)

                    // Proceed Button
                    Button(action: { showSweepFlow = true }) {
                        HStack(spacing: 8) {
                            Image(systemName: "bitcoinsign.circle.fill")
                            Text("I Understand - Proceed to Sweep")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.orange)
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
            }
            .navigationTitle("Sweep Bitcoin")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func warningCard(
        title: String,
        description: String,
        highlights: [String],
        backgroundColor: Color,
        borderColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)

            Text(description)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .lineHeight(1.4)

            if !highlights.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(highlights, id: \.self) { highlight in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•")
                                .foregroundColor(.secondary)
                                .font(.system(size: 12, weight: .semibold))

                            Text(highlight)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .lineHeight(1.3)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .background(backgroundColor)
        .cornerRadius(10)
        .border(borderColor, width: 1)
    }

    private func loadBalance() {
        Task {
            guard let cStr = GetOnchainBalanceC() else { return }
            let json = String(cString: cStr)
            guard let data = json.data(using: .utf8),
                  let response = try? JSONDecoder().decode(BalanceResponse.self, from: data) else { return }
            await MainActor.run {
                self.balance = response.balance
            }
        }
    }
}

private struct BalanceResponse: Decodable {
    let balance: Int
}

#Preview {
    BitcoinSweepDisclaimerView()
}
