import SwiftUI
import CoreImage.CIFilterBuiltins

struct WalletLightningTab: View {
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService

    // Balance
    @State var balanceSats: Int? = nil
    @State var isLoadingBalance = false
    @State var balanceError: String? = nil

    // Send
    @State var invoiceToPay: String = ""
    @State var isSending = false
    @State var sendResult: String? = nil
    @State var sendError: String? = nil
    @State var showingPayConfirm = false

    // Receive
    @State var receiveAmountSats: String = ""
    @State var receiveDescription: String = ""
    @State var isCreatingInvoice = false
    @State var generatedInvoice: String? = nil
    @State var receiveError: String? = nil
    @State private var copiedInvoice = false

    // Lightning address
    @State private var copiedLnAddress = false

    // Send to a lightning address / LNURL
    @State var resolved: LNURLService.Resolved? = nil
    @State var isResolving = false
    @State var resolveError: String? = nil
    @State var lnurlAmountSats: String = ""
    @State var lnurlComment: String = ""
    @State var showingLNURLPayConfirm = false
    @State var isWithdrawing = false

    // History
    @State var transactions: [WalletTransaction] = []
    @State var isLoadingHistory = false
    @State var historyError: String? = nil
    @State var historyUnsupported = false
    @State var canLoadMoreHistory = false
    @State var historyRefreshPending = false
    @State var zapDetails: [String: ZapDetail] = [:]
    @State var zapPosts: [String: FeedNote] = [:]
    static let historyPageSize = 20

    private var lightningAddress: String? {
        let pubkey = nostrService.activeHexPubkey
        return nostrService.profiles[pubkey]?.lud16
    }

    private var hasNWC: Bool {
        !configService.config.nwcURI.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if !hasNWC {
                    nwcNotConfiguredCard
                } else {
                    // MARK: - Balance
                    balanceCard

                    // MARK: - Lightning Address
                    if let lnAddr = lightningAddress, !lnAddr.isEmpty {
                        lightningAddressCard(lnAddr)
                    }

                    // MARK: - Receive
                    receiveCard

                    // MARK: - Send
                    sendCard

                    // MARK: - History
                    historyCard
                }

                Spacer(minLength: 20)
            }
            .padding(.top, 12)
        }
        .onAppear {
            if hasNWC {
                fetchBalance()
                loadHistory(reset: true)
            }
        }
        .task(id: invoiceToPay) { await resolveLNURLIfNeeded() }
        .navigationDestination(for: FeedNote.self) { note in
            NoteDetailView(note: note)
        }
    }

    // MARK: - NWC Not Configured

    private var nwcNotConfiguredCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.slash.fill")
                .font(.appSystem(size: 32))
                .foregroundColor(.secondary)
            Text("No Wallet Connected")
                .font(.appSystem(size: 16, weight: .semibold))
                .foregroundColor(.primary)
            Text("Link a wallet you already use to send and receive zaps.")
                .font(.appSystem(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            NavigationLink {
                WalletSettingsView()
                    .environmentObject(configService)
                    .navigationTitle("Wallet")
            } label: {
                Text("Connect a wallet")
                    .font(.appSystem(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.havenPurple))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            .tutorialAnchor(TutorialContent.walletConnectButton)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Color.platformControlBackground.opacity(0.6))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.platformSeparator.opacity(0.4), lineWidth: 1)
        )
        .tutorialAnchor(TutorialContent.walletEmpty)
        .padding(.horizontal, 16)
        // The Wallet Connect tutorial starts the first time the wallet opens
        // with nothing linked.
        .task(id: TutorialCenter.shared.revision) {
            TutorialCenter.shared.startIfEligible(.walletConnect, account: NostrService.shared.activeHexPubkey)
        }
    }

    // MARK: - Balance Card

    private var balanceCard: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "bolt.fill")
                    .font(.appSystem(size: 14, weight: .semibold))
                    .foregroundColor(.orange)
                Text("LIGHTNING BALANCE")
                    .font(.appSystem(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                if isLoadingBalance {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(action: { fetchBalance() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.appSystem(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Refresh")
                }
            }

            if let error = balanceError {
                Text(error)
                    .font(.appCaption)
                    .foregroundColor(.red)
            } else if let balance = balanceSats {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(formatSats(balance))
                        .font(.appSystem(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    Text("sats")
                        .font(.appSystem(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else if !isLoadingBalance {
                HStack {
                    Text("--")
                        .font(.appSystem(size: 28, weight: .bold, design: .rounded))
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

    // MARK: - Lightning Address Card

    private func lightningAddressCard(_ address: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.fill")
                .font(.appSystem(size: 14, weight: .semibold))
                .foregroundColor(.orange)
            Text(address)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer()
            Button(action: {
                PlatformClipboard.copy(address)
                copiedLnAddress = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedLnAddress = false }
            }) {
                Image(systemName: copiedLnAddress ? "checkmark" : "doc.on.doc")
                    .font(.appSystem(size: 12, weight: .semibold))
                    .foregroundColor(copiedLnAddress ? .green : .secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy")
        }
        .padding(12)
        .background(Color.platformControlBackground.opacity(0.6))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.platformSeparator.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    // MARK: - Receive Card

    private var receiveCard: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.appSystem(size: 14, weight: .semibold))
                    .foregroundColor(.green)
                Text("RECEIVE")
                    .font(.appSystem(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
            }

            HStack(spacing: 8) {
                TextField("Amount (sats)", text: $receiveAmountSats)
                    .font(.appSystem(size: 14, design: .monospaced))
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .textFieldStyle(.roundedBorder)

                TextField("Description (optional)", text: $receiveDescription)
                    .font(.appSystem(size: 14))
                    .textFieldStyle(.roundedBorder)
            }

            Button(action: { createInvoice() }) {
                HStack(spacing: 6) {
                    if isCreatingInvoice {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Create Invoice")
                        .font(.appSystem(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(.green)
            .disabled(receiveAmountSats.isEmpty || isCreatingInvoice)

            if let error = receiveError {
                Text(error)
                    .font(.appCaption)
                    .foregroundColor(.red)
            }

            if let invoice = generatedInvoice {
                invoiceResultView(invoice)
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

    // MARK: - Generated Invoice Display

    private func invoiceResultView(_ invoice: String) -> some View {
        VStack(spacing: 10) {
            if let qrImage = generateQRCode(from: invoice.uppercased()) {
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

            Text(invoice)
                .font(.appSystem(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)

            Button(action: {
                PlatformClipboard.copy(invoice)
                copiedInvoice = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedInvoice = false }
            }) {
                Label(
                    copiedInvoice ? "Copied!" : "Copy Invoice",
                    systemImage: copiedInvoice ? "checkmark" : "doc.on.doc"
                )
                .font(.appSystem(size: 13, weight: .medium))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.green)
        }
        .padding(.top, 8)
    }
}
