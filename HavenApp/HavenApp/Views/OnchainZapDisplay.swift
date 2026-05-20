import SwiftUI

struct OnchainZapDisplay: View {
    let amountSats: Int?
    @StateObject private var priceService = PriceService.shared
    @State private var usdAmount: String = "0"

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "bitcoinsign.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.orange)

            if priceService.isLoadingPrice {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 12, height: 12)
            } else {
                let displayAmount = amountSats ?? 0
                if displayAmount == 0 {
                    Text("0")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.orange)
                } else {
                    Text(usdAmount)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.orange)
                }
            }
        }
        .frame(height: 32)
        .padding(.horizontal, (amountSats ?? 0) > 0 ? 10 : 0)
        .frame(minWidth: 32)
        .background(Color.orange.opacity(0.2))
        .clipShape(Capsule())
        .onChange(of: amountSats) { _, newAmount in
            if newAmount != nil && newAmount! > 0 {
                calculateUSD()
            }
        }
        .onAppear {
            if amountSats != nil && amountSats! > 0 {
                Task {
                    await priceService.fetchBTCPrice()
                    calculateUSD()
                }
            }
        }
    }

    private func calculateUSD() {
        guard let sats = amountSats, sats > 0, let btcPrice = priceService.btcUsdPrice else {
            usdAmount = "0"
            return
        }

        let btc = Double(sats) / 100_000_000
        let usd = btc * btcPrice
        usdAmount = String(format: "$%.2f", usd)
    }
}

#Preview {
    HStack(spacing: 16) {
        OnchainZapDisplay(amountSats: 500000)
        OnchainZapDisplay(amountSats: 0)
        OnchainZapDisplay(amountSats: nil)
    }
    .padding()
    .background(Color(red: 0.08, green: 0.08, blue: 0.1))
}
