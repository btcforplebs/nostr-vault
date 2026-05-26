import SwiftUI
import CoreImage.CIFilterBuiltins
import SilentPaymentsKit

struct WalletOnChainTab: View {
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var spScanService = SPScanService.shared

    @State private var taprootAddress: String = ""
    @State private var silentPaymentAddress: String = ""
    @State private var bitcoinBalance: Int? = nil
    @State private var isLoadingBalance = false
    @State private var copiedTaproot = false
    @State private var copiedSP = false
    @State private var showSweep = false
    @State private var spError: String? = nil
    @State private var showingSPInfo = false

    // SP Sweep state
    @State private var spSweepDestination: String = ""
    @State private var spSweepFeeRate: Int = 0
    @State private var spFeeEstimates: SPFeeEstimates? = nil
    @State private var isLoadingFees = false
    @State private var isSweepingSP = false
    @State private var spSweepSuccess: (txid: String, amount: UInt64, fee: UInt64)? = nil
    @State private var spSweepError: String? = nil

    private struct SPFeeEstimates {
        let fastest: Int
        let halfHour: Int
        let hour: Int
        let economy: Int
    }

    private var ownerPubkey: String {
        nostrService.activeHexPubkey
    }

    private var unsweptUTXOs: [SPStoredUTXO] {
        spScanService.discoveredUTXOs.filter { !$0.isSwept }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // MARK: - On-Chain Balance
                balanceCard

                // MARK: - Taproot Address
                addressCard(
                    title: "Taproot Address",
                    subtitle: "BIP-341 derived from your Nostr key",
                    address: taprootAddress,
                    icon: "bitcoinsign.circle.fill",
                    tint: Color(red: 1.0, green: 0.6, blue: 0.1),
                    copied: copiedTaproot,
                    onCopy: { copyAddress(taprootAddress, binding: $copiedTaproot) }
                )

                // MARK: - Silent Payment Address
                addressCard(
                    title: "Silent Payment Address",
                    subtitle: "BIP-352 unique address per sender",
                    address: silentPaymentAddress,
                    icon: "eye.slash.fill",
                    tint: .purple,
                    copied: copiedSP,
                    onCopy: { copyAddress(silentPaymentAddress, binding: $copiedSP) }
                )

                if let error = spError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal, 16)
                }

                // MARK: - Sweep Button (Taproot)
                if let bal = bitcoinBalance, bal > 0 {
                    sweepButton(balance: bal)
                }

                // MARK: - Silent Payment Received (BETA)
                spReceivedSection

                // MARK: - SP Sweep Section
                if !unsweptUTXOs.isEmpty {
                    spSweepSection
                }

                Spacer(minLength: 20)
            }
            .padding(.top, 12)
        }
        .sheet(isPresented: $showSweep) {
            BitcoinSweepDisclaimerView(onDismiss: { showSweep = false })
                .environmentObject(configService)
        }
        .sheet(isPresented: $showingSPInfo) {
            SPInfoView()
        }
        .onAppear {
            deriveTaprootAddress()
            deriveSilentPaymentAddress()
        }
    }

    // MARK: - Balance Card

    private var balanceCard: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "link")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("ON-CHAIN BALANCE")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                if isLoadingBalance {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let balance = bitcoinBalance {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(formatSats(balance))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    Text("sats")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else if !isLoadingBalance {
                HStack {
                    Text("--")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .padding(16)
        .background(Color.platformControlBackground.opacity(0.6))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.platformSeparator.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    // MARK: - Address Card

    private func addressCard(
        title: String,
        subtitle: String,
        address: String,
        icon: String,
        tint: Color,
        copied: Bool,
        onCopy: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            if address.isEmpty {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Deriving...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                // QR Code
                if let qrImage = generateQRCode(from: address) {
                    HStack {
                        Spacer()
                        Image(platformImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 140, height: 140)
                            .cornerRadius(8)
                        Spacer()
                    }
                }

                // Address text
                Text(address)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)

                // Copy button
                Button(action: onCopy) {
                    Label(
                        copied ? "Copied!" : "Copy Address",
                        systemImage: copied ? "checkmark" : "doc.on.doc"
                    )
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(tint)
            }
        }
        .padding(16)
        .background(Color.platformControlBackground.opacity(0.6))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.platformSeparator.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    // MARK: - Sweep Button (Taproot)

    private func sweepButton(balance: Int) -> some View {
        Button(action: { showSweep = true }) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.right.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text("Sweep \(shortSats(balance)) sats to wallet")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.orange)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    // MARK: - Silent Payment Received (BETA)

    @ViewBuilder
    private var spReceivedSection: some View {
        VStack(spacing: 12) {
            // BETA disclaimer banner with More Info button
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("BETA - EXPERIMENTAL")
                        .font(.system(size: 13, weight: .black))
                        .foregroundColor(.red)
                    Text("Silent Payments is in beta. Do not store large amounts. Use at your own risk.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.red.opacity(0.8))
                }
                Spacer()
                Button(action: { showingSPInfo = true }) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(Color.red.opacity(0.1))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.red.opacity(0.4), lineWidth: 1.5)
            )

            // SP balance
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.purple)
                    Text("SILENT PAYMENT BALANCE")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary)
                    Spacer()
                    if spScanService.isScanning {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(formatSats(Int(spScanService.totalBalanceSats)))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    Text("sats")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }

                if !unsweptUTXOs.isEmpty {
                    HStack {
                        Text("\(unsweptUTXOs.count) UTXO(s) received via Silent Payment")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
            }
            .padding(16)
            .background(Color.purple.opacity(0.06))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.purple.opacity(0.3), lineWidth: 1)
            )

            if let error = spScanService.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - SP Sweep Section

    @ViewBuilder
    private var spSweepSection: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "arrow.up.right.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.purple)
                Text("SWEEP SILENT PAYMENT UTXOS")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
            }

            // Success state
            if let success = spSweepSuccess {
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 16))
                        Text("Sweep Successful!")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.green)
                        Spacer()
                    }
                    Text("Sent \(formatSats(Int(success.amount))) sats (fee: \(success.fee) sats)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text(success.txid)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                .padding(12)
                .background(Color.green.opacity(0.08))
                .cornerRadius(8)
            } else {
                // Destination address
                TextField("Destination address (bc1...)", text: $spSweepDestination)
                    .font(.system(size: 13, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    #endif

                // Fee rate picker
                if let fees = spFeeEstimates {
                    VStack(spacing: 6) {
                        HStack {
                            Text("Fee rate:")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(spSweepFeeRate) sat/vB")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(.primary)
                        }
                        HStack(spacing: 6) {
                            feeButton(label: "Eco", rate: fees.economy)
                            feeButton(label: "1hr", rate: fees.hour)
                            feeButton(label: "30m", rate: fees.halfHour)
                            feeButton(label: "Fast", rate: fees.fastest)
                        }
                    }
                } else if isLoadingFees {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Loading fees...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }

                // Sweep button
                Button(action: { executeSPSweep() }) {
                    HStack(spacing: 6) {
                        if isSweepingSP {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Sweep \(unsweptUTXOs.count) UTXO(s) (\(formatSats(Int(spScanService.totalBalanceSats))) sats)")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(canSweepSP ? Color.purple : Color.purple.opacity(0.4))
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .disabled(!canSweepSP)

                if let error = spSweepError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
        .padding(16)
        .background(Color.platformControlBackground.opacity(0.6))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.purple.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .onAppear { loadFeeEstimates() }
    }

    private var canSweepSP: Bool {
        !spSweepDestination.trimmingCharacters(in: .whitespaces).isEmpty
            && spSweepFeeRate > 0
            && !isSweepingSP
            && !unsweptUTXOs.isEmpty
    }

    private func feeButton(label: String, rate: Int) -> some View {
        Button(action: { spSweepFeeRate = rate }) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(spSweepFeeRate == rate ? Color.purple : Color.purple.opacity(0.12))
                .foregroundColor(spSweepFeeRate == rate ? .white : .purple)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Logic

    private func deriveTaprootAddress() {
        guard let cAddr = ownerPubkey.withCString({ DeriveTaprootAddressC(UnsafeMutablePointer(mutating: $0)) }) else { return }
        let address = String(cString: cAddr)
        guard !address.isEmpty else { return }
        taprootAddress = address
        fetchBitcoinBalance(address: address)
    }

    private func deriveSilentPaymentAddress() {
        do {
            silentPaymentAddress = try SilentPaymentService.deriveAddress(hexPubkey: ownerPubkey)
        } catch {
            spError = "Could not derive Silent Payment address."
        }
    }

    private func fetchBitcoinBalance(address: String) {
        isLoadingBalance = true
        Task {
            defer { Task { @MainActor in isLoadingBalance = false } }
            guard let url = URL(string: "https://mempool.btcforplebs.com/api/address/\(address)") else { return }
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }

            struct Stats: Decodable {
                let funded_txo_sum: Int
                let spent_txo_sum: Int
            }
            struct AddressResponse: Decodable {
                let chain_stats: Stats
                let mempool_stats: Stats
            }

            guard let response = try? JSONDecoder().decode(AddressResponse.self, from: data) else { return }
            let confirmed = response.chain_stats.funded_txo_sum - response.chain_stats.spent_txo_sum
            let unconfirmed = response.mempool_stats.funded_txo_sum - response.mempool_stats.spent_txo_sum
            let total = confirmed + unconfirmed

            await MainActor.run {
                bitcoinBalance = total
            }
        }
    }

    private func loadFeeEstimates() {
        isLoadingFees = true
        Task {
            defer { Task { @MainActor in isLoadingFees = false } }
            guard let url = URL(string: "https://mempool.btcforplebs.com/api/v1/fees/recommended") else { return }
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }

            struct FeeResponse: Decodable {
                let fastestFee: Int
                let halfHourFee: Int
                let hourFee: Int
                let economyFee: Int
            }

            guard let fees = try? JSONDecoder().decode(FeeResponse.self, from: data) else { return }
            await MainActor.run {
                spFeeEstimates = SPFeeEstimates(
                    fastest: fees.fastestFee,
                    halfHour: fees.halfHourFee,
                    hour: fees.hourFee,
                    economy: fees.economyFee
                )
                if spSweepFeeRate == 0 {
                    spSweepFeeRate = fees.hourFee
                }
            }
        }
    }

    private func executeSPSweep() {
        let dest = spSweepDestination.trimmingCharacters(in: .whitespaces)
        guard !dest.isEmpty, spSweepFeeRate > 0 else { return }

        isSweepingSP = true
        spSweepError = nil
        spSweepSuccess = nil

        Task {
            do {
                // Build SweepInputs from stored UTXOs
                var sweepInputs: [SweepInput] = []
                for utxo in unsweptUTXOs {
                    guard let spendKey = spScanService.retrieveSpendKey(forUTXO: utxo.id) else {
                        throw SPSweepServiceError.missingSpendKey(utxo.id)
                    }
                    guard let xOnlyData = dataFromHex(utxo.taprootXOnlyKeyHex), xOnlyData.count == 32 else {
                        throw SPSweepServiceError.invalidKey(utxo.id)
                    }
                    guard let txidData = txidToInternalOrder(utxo.txid) else {
                        throw SPSweepServiceError.invalidTxid(utxo.txid)
                    }

                    let spOutput = SilentPaymentOutput(
                        taprootXOnlyKey: xOnlyData,
                        spendPrivateKey: spendKey,
                        outputIndex: 0,
                        label: utxo.label
                    )

                    sweepInputs.append(SweepInput(
                        output: spOutput,
                        amountSats: utxo.amountSats,
                        txid: txidData,
                        vout: utxo.vout
                    ))
                }

                // Calculate total and fee
                let totalIn = sweepInputs.reduce(UInt64(0)) { $0 + $1.amountSats }
                let feeRate = FeeEstimate(satsPerVbyte: UInt64(spSweepFeeRate))
                let estimatedFee = feeRate.estimatedFee(inputCount: sweepInputs.count, outputCount: 1)

                guard totalIn > estimatedFee else {
                    throw SPSweepServiceError.dustBalance(totalIn, estimatedFee)
                }

                let sendAmount = totalIn - estimatedFee
                let destination = try SweepOutput(address: dest, amountSats: sendAmount)

                // Build and sign the transaction
                let result = try SweepTransaction.build(
                    inputs: sweepInputs,
                    destination: destination,
                    feeRate: feeRate
                )

                // Broadcast
                let txid = try await broadcastTransaction(rawTx: result.rawTx)

                // Mark UTXOs as swept and persist
                let sweptIds = unsweptUTXOs.map { $0.id }
                await MainActor.run {
                    spScanService.markSwept(utxoIds: sweptIds, sweepTxid: txid)
                    spSweepSuccess = (txid: txid, amount: sendAmount, fee: result.feeSats)
                    isSweepingSP = false
                }

            } catch {
                await MainActor.run {
                    spSweepError = error.localizedDescription
                    isSweepingSP = false
                }
            }
        }
    }

    private func broadcastTransaction(rawTx: Data) async throws -> String {
        let hexTx = rawTx.map { String(format: "%02x", $0) }.joined()

        // Try primary endpoint
        if let txid = try? await postTransaction(to: "https://mempool.btcforplebs.com/api/tx", hex: hexTx) {
            return txid
        }
        // Fallback to mempool.space
        return try await postTransaction(to: "https://mempool.space/api/tx", hex: hexTx)
    }

    private func postTransaction(to urlString: String, hex: String) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw SPSweepServiceError.broadcastFailed("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = hex.data(using: .utf8)
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SPSweepServiceError.broadcastFailed(body)
        }
        guard let txid = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !txid.isEmpty else {
            throw SPSweepServiceError.broadcastFailed("Empty response")
        }
        return txid
    }

    /// Convert display-format txid (big-endian hex) to internal byte order (little-endian / reversed).
    private func txidToInternalOrder(_ txidHex: String) -> Data? {
        guard let data = dataFromHex(txidHex), data.count == 32 else { return nil }
        return Data(data.reversed())
    }

    private enum SPSweepServiceError: Error, LocalizedError {
        case missingSpendKey(String)
        case invalidKey(String)
        case invalidTxid(String)
        case dustBalance(UInt64, UInt64)
        case broadcastFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingSpendKey(let id): return "Missing spend key for UTXO \(id.prefix(12))..."
            case .invalidKey(let id): return "Invalid key data for UTXO \(id.prefix(12))..."
            case .invalidTxid(let txid): return "Invalid txid: \(txid.prefix(12))..."
            case .dustBalance(let avail, let fee): return "Balance (\(avail) sats) is below fee (\(fee) sats)"
            case .broadcastFailed(let msg): return "Broadcast failed: \(msg)"
            }
        }
    }

    // MARK: - Helpers

    private func copyAddress(_ address: String, binding: Binding<Bool>) {
        PlatformClipboard.copy(address)
        binding.wrappedValue = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            binding.wrappedValue = false
        }
    }

    private func formatSats(_ sats: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: sats)) ?? "\(sats)"
    }

    private func shortSats(_ sats: Int) -> String {
        if sats >= 1_000_000 {
            return String(format: "%.2fM", Double(sats) / 1_000_000.0)
        } else if sats >= 10_000 {
            return String(format: "%.1fk", Double(sats) / 1_000.0)
        }
        return formatSats(sats)
    }

    private func dataFromHex(_ hex: String) -> Data? {
        let h = hex.lowercased()
        guard h.count % 2 == 0 else { return nil }
        var data = Data()
        var i = h.startIndex
        while i < h.endIndex {
            let j = h.index(i, offsetBy: 2)
            guard let byte = UInt8(h[i..<j], radix: 16) else { return nil }
            data.append(byte)
            i = j
        }
        return data
    }

    private func generateQRCode(from string: String) -> PlatformImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        #if os(iOS)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage, size: scaled.extent.size)
        #endif
    }
}

// MARK: - Silent Payments Info View

private struct SPInfoView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.purple)
                        Text("Silent Payments")
                            .font(.system(size: 22, weight: .bold))
                        Text("BIP-352 on Nostr")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 8)

                    // What are Silent Payments?
                    infoSection(
                        title: "What are Silent Payments?",
                        icon: "questionmark.circle.fill",
                        color: .purple
                    ) {
                        Text("Silent Payments (BIP-352) is a protocol for generating unique Bitcoin addresses for every sender without any interaction from the receiver. Unlike traditional static addresses (which reuse the same address and harm privacy), Silent Payments derive a fresh Taproot address per transaction using elliptic curve Diffie-Hellman (ECDH).")
                        Text("This means you can publish a single Silent Payment address (sp1...) and every sender will independently compute a unique on-chain address that only you can detect and spend from. No address reuse, no server-side scanning infrastructure, and no interactive protocols.")
                        Text("The result: a static identifier that produces unlinkable on-chain outputs. An observer cannot determine that two transactions both paid the same recipient.")
                    }

                    // How NSW Works
                    infoSection(
                        title: "Nostr Silent Wallet (NSW)",
                        icon: "network",
                        color: .blue
                    ) {
                        Text("Nostr Vault implements a Nostr-native approach to Silent Payments called NSW (Nostr Silent Wallet). Your Nostr private key (nsec) serves as the cryptographic root for the Silent Payment wallet.")
                        Text("Key derivation:")
                        bulletPoint("Your Nostr private key (secp256k1) is used as the scan key and spend key base")
                        bulletPoint("The Silent Payment address (sp1...) is derived deterministically from your Nostr public key")
                        bulletPoint("Anyone with your npub can derive your SP address and send you Bitcoin privately")
                        bulletPoint("Only your nsec can detect incoming payments and sign sweep transactions")
                        Text("This creates a natural mapping: your Nostr identity IS your Silent Payment identity. No additional key management, no separate seed phrases, no extra backups needed beyond your nsec.")
                    }

                    // Notification Protocol
                    infoSection(
                        title: "Payment Notifications (NIP-17 Gift Wraps)",
                        icon: "bell.badge.fill",
                        color: .orange
                    ) {
                        Text("The fundamental challenge with Silent Payments is detection: the receiver needs to scan every Bitcoin transaction to find payments addressed to them. On-chain light client scanning is expensive and slow.")
                        Text("Nostr Vault solves this with sender-side notifications via NIP-17 encrypted direct messages (Gift Wraps):")
                        bulletPoint("1. Sender computes the shared secret and derives the unique output key")
                        bulletPoint("2. Sender includes the payment in a Bitcoin transaction")
                        bulletPoint("3. Sender encrypts a notification containing the txid, tweak, and blockhash")
                        bulletPoint("4. Notification is wrapped in a NIP-17 Gift Wrap (Kind 1059) and sent to the receiver's Nostr pubkey")
                        bulletPoint("5. Receiver's Nostr Vault client decrypts the notification and verifies the payment on-chain")
                        Text("This eliminates the need for full-chain scanning. The receiver only needs to check specific transactions indicated by notifications, making detection instant and lightweight.")
                        Text("Trade-off: This requires the sender to cooperate by sending a notification. If a sender pays your SP address without notifying, the UTXO exists on-chain but Nostr Vault won't detect it until manual full-scan support is added.")
                    }

                    // Scanning & Verification
                    infoSection(
                        title: "Scanning & Verification",
                        icon: "magnifyingglass.circle.fill",
                        color: .green
                    ) {
                        Text("When a notification arrives, Nostr Vault performs cryptographic verification:")
                        bulletPoint("1. Decrypt the NIP-17 Gift Wrap to extract the SP notification (txid + tweak)")
                        bulletPoint("2. Fetch the transaction's Taproot outputs from Mempool API")
                        bulletPoint("3. Use SilentPaymentsKit's scanWithNotification() to perform ECDH with the tweak and scan key")
                        bulletPoint("4. If a derived output matches a Taproot output in the transaction, the payment is confirmed")
                        bulletPoint("5. The per-output spend private key is computed and stored securely in the iOS/macOS Keychain")
                        bulletPoint("6. The UTXO is added to local state with amount, txid:vout, and metadata")
                        Text("Each spend key is unique per output and stored individually in the Keychain with hardware-backed encryption (Secure Enclave on supported devices). The keys never leave the device and are not included in iCloud backups.")
                    }

                    // Sweeping
                    infoSection(
                        title: "Sweeping (Spending) UTXOs",
                        icon: "arrow.up.right.circle.fill",
                        color: .purple
                    ) {
                        Text("Silent Payment UTXOs are Taproot (P2TR) outputs with unique key-path spend conditions. To spend them, Nostr Vault constructs a sweep transaction:")
                        bulletPoint("1. Collect all unswept UTXOs and retrieve their per-output spend keys from Keychain")
                        bulletPoint("2. Construct transaction inputs with proper prevout references (txid in internal byte order + vout)")
                        bulletPoint("3. Create the destination output (your chosen address) with amount = total inputs - fee")
                        bulletPoint("4. Sign each input with BIP-341 Schnorr signatures using the corresponding spend key")
                        bulletPoint("5. Produce the signed transaction with proper witness data")
                        bulletPoint("6. Broadcast via Mempool API (with fallback endpoint)")
                        Text("Fee estimation uses real-time fee rate data from the Mempool API. You can choose between economy, 1-hour, 30-minute, and fastest confirmation targets.")
                        Text("Important: All inputs are swept in a single transaction. This consolidation is necessary because Silent Payment UTXOs use different spend keys (unlike a normal wallet where one key controls all UTXOs). Partial sweeps would leave smaller UTXOs that may become uneconomical to spend later.")
                    }

                    // Cryptographic Details
                    infoSection(
                        title: "Cryptographic Details",
                        icon: "lock.shield.fill",
                        color: .indigo
                    ) {
                        Text("BIP-352 uses the following cryptographic construction:")
                        bulletPoint("Curve: secp256k1 (same as Bitcoin and Nostr)")
                        bulletPoint("Shared secret: ECDH between sender's input key and receiver's scan key")
                        bulletPoint("Output derivation: P_output = P_spend + SHA256(shared_secret || counter) * G")
                        bulletPoint("Spending: The receiver computes the corresponding private key: k_spend + SHA256(shared_secret || counter)")
                        bulletPoint("Output type: BIP-341 Taproot (P2TR) with key-path spending")
                        bulletPoint("Signatures: BIP-340 Schnorr (64 bytes, no sighash byte for default SIGHASH_ALL)")
                        Text("The tweak in the notification allows the receiver to reconstruct the shared secret without needing the sender's actual input key. This is what enables the notification-based scanning approach.")
                    }

                    // Security Considerations
                    infoSection(
                        title: "Security Considerations",
                        icon: "shield.lefthalf.filled",
                        color: .red
                    ) {
                        Text("This implementation has specific security properties and limitations you should understand:")
                        bulletPoint("Spend keys in Keychain: Protected by device passcode/biometrics. Lost device without backup = lost funds.")
                        bulletPoint("Nostr key = Bitcoin key: Compromising your nsec compromises ALL Silent Payment funds. Use a hardware-backed nsec if possible.")
                        bulletPoint("Notification dependency: Without a notification, payments cannot be detected (until full-scan is implemented). Senders must cooperate.")
                        bulletPoint("Notification privacy: NIP-17 Gift Wraps are end-to-end encrypted, but relay metadata (timing, IP) could leak correlation hints.")
                        bulletPoint("No HD derivation: Unlike BIP-32 wallets, there is no master seed that can regenerate spend keys. Each UTXO's key is computed from the notification tweak and stored individually.")
                        bulletPoint("Single-device: Spend keys are device-local. Multi-device access requires manual key export (not yet implemented).")
                        bulletPoint("No change outputs: Sweeps send the entire balance minus fees to one destination. There is no internal change address management.")
                    }

                    // Beta Warnings
                    infoSection(
                        title: "Beta Status & Warnings",
                        icon: "exclamationmark.triangle.fill",
                        color: .red
                    ) {
                        Text("This Silent Payments implementation is EXPERIMENTAL. The following are known limitations:")
                        bulletPoint("BIP-352 is relatively new and implementations across the ecosystem are still maturing")
                        bulletPoint("The NSW notification protocol is Nostr Vault-specific and not yet standardized across Nostr clients")
                        bulletPoint("Full-chain rescanning (for missed notifications) is not yet implemented")
                        bulletPoint("There is no coin control (you cannot choose which specific UTXOs to sweep)")
                        bulletPoint("Label support (BIP-352 labels for sub-addresses) is basic")
                        bulletPoint("No PSBT export for hardware wallet signing")
                        bulletPoint("Transaction fee bumping (RBF/CPFP) is not yet supported")
                        Text("DO NOT store significant amounts in Silent Payment UTXOs at this time. Treat this as a developer preview for small test amounts only. Always maintain the ability to recover your nsec independently of this app.")
                            .fontWeight(.semibold)
                    }

                    // Technical References
                    infoSection(
                        title: "References & Specifications",
                        icon: "doc.text.fill",
                        color: .secondary
                    ) {
                        bulletPoint("BIP-352: Silent Payments (bitcoin/bips)")
                        bulletPoint("BIP-341: Taproot (SegWit v1 spend rules)")
                        bulletPoint("BIP-340: Schnorr Signatures for secp256k1")
                        bulletPoint("NIP-17: Private Direct Messages (Gift Wraps)")
                        bulletPoint("NIP-59: Gift Wrap (encrypted event envelope)")
                        bulletPoint("SilentPaymentsKit: Swift implementation used by Nostr Vault")
                        bulletPoint("secp256k1: Elliptic curve library (GigaBitcoin/secp256k1.swift)")
                    }

                    Spacer(minLength: 40)
                }
                .padding(20)
            }
            .navigationTitle("Silent Payments Info")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 550, idealWidth: 620, minHeight: 600, idealHeight: 750)
        #endif
    }

    // MARK: - Section Builder

    private func infoSection(
        title: String,
        icon: String,
        color: Color,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.primary)
            }
            .padding(.bottom, 2)

            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .font(.system(size: 13))
            .foregroundColor(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.platformControlBackground.opacity(0.5))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.platformSeparator.opacity(0.3), lineWidth: 1)
        )
    }

    private func bulletPoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.purple.opacity(0.7))
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
