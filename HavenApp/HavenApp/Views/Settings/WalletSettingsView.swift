import SwiftUI
import CoreImage

struct WalletSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @State private var balance: Int? = nil
    @State private var isFetchingBalance = false
    @State private var balanceError: String? = nil
    @State private var taprootAddress: String = ""
    @State private var addressCopied = false
    @State private var showSweepDisclaimer = false

    var body: some View {
        Form {
            Section {
                TextEditor(text: $configService.config.nwcURI)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80)
                    .padding(4)
                    .background(Color.platformControlBackground)
                    .cornerRadius(6)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
            } header: {
                Text("Wallet Connect").settingInfo(.walletNWC)
            } footer: {
                Text("Paste a nostr+walletconnect:// link.")
            }

            if !configService.config.nwcURI.isEmpty {
                Section("Zaps") {
                    HStack {
                        Text("Default Zap").settingInfo(.walletDefaultZap)
                        Spacer()
                        let amountSats = configService.config.defaultZapAmount / 1000
                        TextField("Sats", value: Binding(
                            get: { amountSats },
                            set: { configService.config.defaultZapAmount = $0 * 1000 }
                        ), formatter: NumberFormatter())
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        Text("sats")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Balance")
                        Spacer()
                        if isFetchingBalance {
                            ProgressView().controlSize(.small)
                        } else if let bal = balance {
                            Text("\(bal / 1000) sats")
                                .foregroundColor(.secondary)
                        } else if let error = balanceError {
                            Text(error)
                                .foregroundColor(.red)
                                .font(.appCaption)
                        } else {
                            Text("Unknown")
                                .foregroundColor(.secondary)
                        }

                        Button {
                            fetchBalance()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .disabled(isFetchingBalance)
                    }
                }
            }


            // Bitcoin Taproot wallet derived from Nostr keypair (BIP-341)
            Section {
                Toggle(isOn: $configService.config.showBitcoinWallet) {
                    Label {
                        Text("Bitcoin Address").settingInfo(.walletBitcoin)
                    } icon: {
                        Image(systemName: "bitcoinsign.circle")
                    }
                }
                .onChange(of: configService.config.showBitcoinWallet) { _, enabled in
                    if enabled { deriveTaprootAddress() }
                    configService.save()
                }

                if configService.config.showBitcoinWallet {
                    if taprootAddress.isEmpty {
                        HStack {
                            Spacer()
                            ProgressView().controlSize(.small)
                            Spacer()
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            if let qrImage = generateQRCode(from: taprootAddress) {
                                HStack {
                                    Spacer()
                                    Image(platformImage: qrImage)
                                        .interpolation(.none)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 160, height: 160)
                                        .cornerRadius(8)
                                    Spacer()
                                }
                            }

                            Text(taprootAddress)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .minimumScaleFactor(0.7)

                            Button {
                                copyAddress()
                            } label: {
                                Label(
                                    addressCopied ? "Copied!" : "Copy Address",
                                    systemImage: addressCopied ? "checkmark" : "doc.on.doc"
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 4)
                    }

                    Divider()
                        .padding(.vertical, 8)

                    Button(action: { showSweepDisclaimer = true }) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.right.circle.fill")
                            Text("Sweep Wallet")
                                .font(.appSystem(size: 15, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.orange)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Bitcoin")
            }
        }
        .groupedFormStyleCompat()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showSweepDisclaimer) {
            BitcoinSweepDisclaimerView(onDismiss: { showSweepDisclaimer = false })
                .environmentObject(configService)
        }
        .onAppear {
            if !configService.config.nwcURI.isEmpty {
                fetchBalance()
            }
            if configService.config.showBitcoinWallet && taprootAddress.isEmpty {
                deriveTaprootAddress()
            }
        }
        .onChange(of: configService.config.nwcURI) { _, _ in
            balance = nil
            balanceError = nil
        }
    }

    private func fetchBalance() {
        guard !configService.config.nwcURI.isEmpty else { return }
        isFetchingBalance = true
        balanceError = nil
        Task {
            do {
                let msat = try await NWCService.getBalance()
                await MainActor.run {
                    self.balance = msat
                    self.isFetchingBalance = false
                }
            } catch {
                await MainActor.run {
                    self.balanceError = error.localizedDescription
                    self.isFetchingBalance = false
                }
            }
        }
    }

    private func deriveTaprootAddress() {
        let npub = configService.config.ownerNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !npub.isEmpty,
              let decoded = Bech32.decode(npub),
              decoded.hrp == "npub" else { return }
        let hexPubKey = decoded.hexString
        if let cAddr = hexPubKey.withCString({ DeriveTaprootAddressC(UnsafeMutablePointer(mutating: $0)) }) {
            taprootAddress = String(cString: cAddr)
        }
    }

    private func copyAddress() {
        guard !taprootAddress.isEmpty else { return }
        #if os(iOS)
        UIPasteboard.general.string = taprootAddress
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(taprootAddress, forType: .string)
        #endif
        addressCopied = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { addressCopied = false }
        }
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
