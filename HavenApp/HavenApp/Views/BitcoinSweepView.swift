import SwiftUI

struct BitcoinSweepView: View {
    let balanceSats: Int
    var onDismiss: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var destAddress = ""
    @State private var feeEstimates: FeeEstimates? = nil
    @State private var selectedTier: FeeTier = .normal
    @State private var sweepState: SweepState = .idle
    @State private var loadingFees = true
    /// Set when Sweep is tapped; the confirm step sends exactly this address
    /// at exactly this rate, even if fee estimates land while it is open.
    @State private var pending: PendingSweep? = nil

    struct PendingSweep {
        let address: String
        let feeRate: Int
        let amount: Int
        let fee: Int
    }

    enum FeeTier: CaseIterable, Identifiable {
        case economy, normal, fast
        var id: Self { self }
        var label: String {
            switch self {
            case .economy: return "Economy"
            case .normal:  return "Normal"
            case .fast:    return "Fast"
            }
        }
        func rate(from e: FeeEstimates) -> Int {
            switch self {
            case .economy: return e.economyFee
            case .normal:  return e.halfHourFee
            case .fast:    return e.fastestFee
            }
        }
    }

    enum SweepState {
        case idle
        case sweeping
        case success(txid: String, amount: Int, fee: Int)
        case failure(String)
    }

    struct FeeEstimates: Decodable {
        let fastestFee: Int
        let halfHourFee: Int
        let hourFee: Int
        let economyFee: Int
    }

    struct SweepResult: Decodable {
        let txid: String?
        let amount: Int?
        let fee: Int?
        let error: String?
    }

    private var currentFeeRate: Int {
        guard let e = feeEstimates else { return 5 }
        return max(1, selectedTier.rate(from: e))
    }

    // Rough vsize for a 1-in 1-out P2TR key-path sweep
    private var estimatedVsize: Int { 111 }

    private var estimatedFee: Int { estimatedVsize * currentFeeRate }

    private var sendAmount: Int { max(0, balanceSats - estimatedFee) }

    private var validAddress: String? { BitcoinAddress.normalizedMainnet(destAddress) }

    private var canSweep: Bool {
        validAddress != nil
            && sendAmount > 546
            && sweepState.isIdle
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    switch sweepState {
                    case .success(let txid, let amount, let fee):
                        successView(txid: txid, amount: amount, fee: fee)
                    default:
                        sweepForm
                    }
                }
                .padding(20)
            }
            .background(Color.platformWindowBackground)
            .navigationTitle("Sweep Bitcoin")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if let onDismiss = onDismiss {
                            onDismiss()
                        } else {
                            dismiss()
                        }
                    }
                    .foregroundColor(.havenPurple)
                }
            }
        }
        .onAppear { loadFeeEstimates() }
        .alert("Send entire balance?", isPresented: Binding(
            get: { pending != nil },
            set: { if !$0 { pending = nil } }
        ), presenting: pending) { sweep in
            Button("Cancel", role: .cancel) { pending = nil }
            Button("Send", role: .destructive) {
                pending = nil
                executeSweep(sweep)
            }
        } message: { sweep in
            Text("About \(formatSats(sweep.amount)) to:\n\n\(sweep.address)\n\nFee about \(formatSats(sweep.fee)) at \(sweep.feeRate) sat/vB. This cannot be undone.")
        }
    }

    // MARK: - Form

    private var sweepForm: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Balance card
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Available balance")
                        .font(.appSystem(size: 12))
                        .foregroundColor(.secondary)
                    Text(formatSats(balanceSats))
                        .font(.appSystem(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(red: 1.0, green: 0.75, blue: 0.3))
                }
                Spacer()
                Image(systemName: "bitcoinsign.circle.fill")
                    .font(.appSystem(size: 32))
                    .foregroundColor(.orange)
            }
            .padding(16)
            .background(Color.orange.opacity(0.1))
            .cornerRadius(12)

            // Destination
            VStack(alignment: .leading, spacing: 6) {
                Text("Destination address")
                    .font(.appSystem(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                TextField("bc1p…", text: $destAddress)
                    .font(.appSystem(size: 13, design: .monospaced))
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.asciiCapable)
                    #endif
                    .padding(10)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(8)
                if !destAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && validAddress == nil {
                    Text("Not a valid Bitcoin mainnet address")
                        .font(.appSystem(size: 12))
                        .foregroundColor(.red)
                }
            }

            // Fee tier
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Fee rate")
                        .font(.appSystem(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                    if loadingFees {
                        ProgressView().scaleEffect(0.6)
                    }
                }
                HStack(spacing: 8) {
                    ForEach(FeeTier.allCases) { tier in
                        feeTierButton(tier)
                    }
                }
            }

            // Preview
            VStack(spacing: 8) {
                feePreviewRow(label: "Fee (\(currentFeeRate) sat/vB × ~\(estimatedVsize) vB)",
                              value: formatSats(estimatedFee),
                              color: .secondary)
                Divider()
                feePreviewRow(label: "You'll send",
                              value: formatSats(max(0, sendAmount)),
                              color: sendAmount > 546 ? .white : .red)
            }
            .padding(14)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(10)

            if case .failure(let msg) = sweepState {
                Text(msg)
                    .font(.appSystem(size: 13))
                    .foregroundColor(.red)
                    .padding(10)
                    .background(Color.red.opacity(0.08))
                    .cornerRadius(8)
            }

            // Sweep button
            Button(action: requestSweep) {
                HStack(spacing: 8) {
                    if case .sweeping = sweepState {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(.white)
                    } else {
                        Image(systemName: "bitcoinsign.circle.fill")
                    }
                    Text(sweepState.isSweeping ? "Broadcasting…" : "Sweep")
                        .font(.appSystem(size: 16, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(canSweep ? Color.havenPurple : Color.secondary.opacity(0.3))
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
            .disabled(!canSweep)

            if sendAmount <= 546 && sendAmount > 0 {
                Text("Insufficient funds after fees")
                    .font(.appSystem(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Success

    private func successView(txid: String, amount: Int, fee: Int) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.appSystem(size: 56))
                .foregroundColor(.orange)

            Text("Swept!")
                .font(.appTitle2.bold())
                .foregroundColor(.white)

            VStack(spacing: 6) {
                feePreviewRow(label: "Sent", value: formatSats(amount), color: .white)
                feePreviewRow(label: "Fee paid", value: formatSats(fee), color: .secondary)
            }
            .padding(14)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(10)

            VStack(spacing: 8) {
                Text("Transaction ID")
                    .font(.appSystem(size: 12))
                    .foregroundColor(.secondary)
                Text(txid)
                    .font(.appSystem(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            if let url = URL(string: "https://mempool.btcforplebs.com/tx/\(txid)") {
                Link(destination: url) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right.square")
                        Text("View on mempool")
                    }
                    .font(.appSystem(size: 14, weight: .medium))
                    .foregroundColor(.havenPurple)
                }
            }
        }
        .padding(.top, 20)
    }

    // MARK: - Subviews

    private func feeTierButton(_ tier: FeeTier) -> some View {
        let rate = feeEstimates.map { tier.rate(from: $0) }
        let isSelected = selectedTier == tier
        return Button(action: { selectedTier = tier }) {
            VStack(spacing: 2) {
                Text(tier.label)
                    .font(.appSystem(size: 12, weight: .semibold))
                if let rate = rate {
                    Text("\(rate) sat/vB")
                        .font(.appSystem(size: 10))
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                } else {
                    Text("–")
                        .font(.appSystem(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .foregroundColor(isSelected ? .white : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isSelected ? Color.orange : Color.secondary.opacity(0.1))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private func feePreviewRow(label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.appSystem(size: 13))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.appSystem(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
        }
    }

    // MARK: - Logic

    private func loadFeeEstimates() {
        Task {
            guard let cStr = FetchFeeEstimatesC() else { return }
            let json = String(cString: cStr)
            free(cStr)
            guard let data = json.data(using: .utf8),
                  let estimates = try? JSONDecoder().decode(FeeEstimates.self, from: data) else { return }
            await MainActor.run {
                feeEstimates = estimates
                loadingFees = false
            }
        }
    }

    /// Sweep sends everything, so the button only opens a confirm step that
    /// shows the amount and the full address.
    private func requestSweep() {
        guard canSweep, let address = validAddress else { return }
        pending = PendingSweep(address: address, feeRate: currentFeeRate,
                               amount: sendAmount, fee: estimatedFee)
    }

    private func executeSweep(_ sweep: PendingSweep) {
        guard sweepState.isIdle, BitcoinAddress.normalizedMainnet(sweep.address) == sweep.address else { return }
        let dest = sweep.address

        let config = ConfigService.shared.config
        var hexKey: String?
        if !config.ownerNcryptsec.isEmpty {
            let pwd = NIP49Service.getPasswordFromKeychain()
            hexKey = pwd.flatMap { try? config.getDecryptedHexKey(password: $0) }
        } else {
            hexKey = config.ownerHexKey
        }

        guard let nsecHex = hexKey, !nsecHex.isEmpty else {
            sweepState = .failure("Could not access private key. Unlock your wallet first.")
            return
        }

        let rate = Int32(sweep.feeRate)

        sweepState = .sweeping
        Task.detached {
            guard let cStr = SweepToAddressC(
                UnsafeMutablePointer(mutating: (nsecHex as NSString).utf8String),
                UnsafeMutablePointer(mutating: (dest as NSString).utf8String),
                rate
            ) else {
                await MainActor.run { sweepState = .failure("Sweep failed (no response).") }
                return
            }
            let json = String(cString: cStr)
            free(cStr)
            guard let data = json.data(using: .utf8),
                  let result = try? JSONDecoder().decode(SweepResult.self, from: data) else {
                await MainActor.run { sweepState = .failure("Could not parse sweep response.") }
                return
            }
            await MainActor.run {
                if let err = result.error {
                    sweepState = .failure(err)
                } else if let txid = result.txid, let amount = result.amount, let fee = result.fee {
                    sweepState = .success(txid: txid, amount: amount, fee: fee)
                } else {
                    sweepState = .failure("Unknown error.")
                }
            }
        }
    }

    private func formatSats(_ sats: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        return (formatter.string(from: NSNumber(value: sats)) ?? "\(sats)") + " sats"
    }
}

private extension BitcoinSweepView.SweepState {
    var isIdle: Bool {
        if case .idle = self { return true }
        if case .failure = self { return true }
        return false
    }
    var isSweeping: Bool {
        if case .sweeping = self { return true }
        return false
    }
}
