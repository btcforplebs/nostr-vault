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
    /// The wallet saved on this Nostr account (NIP-78, Wisp's format), if any.
    @State private var savedWallet: NWCBackupService.Saved?
    @State private var backupBusy = false
    @State private var backupError: String?

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

            if configService.config.nwcURI.isEmpty, let saved = savedWallet {
                Section {
                    Button {
                        configService.config.nwcURI = saved.uri
                        configService.save()
                    } label: {
                        Label("Use saved wallet", systemImage: "arrow.down.circle")
                    }
                } header: {
                    Text("Saved wallet found")
                } footer: {
                    Text("Your Nostr account holds a wallet connection, saved \(saved.savedAt.formatted(date: .abbreviated, time: .omitted)). It may have come from Nostr Vault on another device or from Wisp.")
                }
            }

            if !configService.config.nwcURI.isEmpty {
                Section {
                    Toggle(isOn: saveToAccountBinding) {
                        HStack {
                            Text("Save wallet to my Nostr account")
                            if backupBusy {
                                Spacer()
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(backupBusy)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Stored encrypted to your key (NIP-44) on your relays, so Nostr Vault on your other devices, or Wisp, can use it. Anyone who has your key can read it and spend from this wallet.")
                        if let backupError {
                            Text(backupError).foregroundColor(.red)
                        }
                    }
                }
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
            backupError = nil
        }
        .task(id: NostrService.shared.activeHexPubkey) {
            savedWallet = await NWCBackupService.fetchSaved(nostrService: NostrService.shared)
        }
    }

    /// On when the account holds exactly the wallet in use. Turning it on
    /// publishes the encrypted wallet; off takes it off the account. A wallet
    /// changed since saving shows off until it is saved again.
    private var saveToAccountBinding: Binding<Bool> {
        Binding(
            get: { savedWallet?.uri == configService.config.nwcURI.trimmingCharacters(in: .whitespacesAndNewlines) },
            set: { on in
                let uri = configService.config.nwcURI
                backupBusy = true
                backupError = nil
                Task {
                    do {
                        if on {
                            try await NWCBackupService.save(uri, nostrService: NostrService.shared)
                            if let trimmed = NWCBackup.plaintext(forSaving: uri) {
                                savedWallet = NWCBackupService.Saved(uri: trimmed, savedAt: Date())
                            }
                        } else {
                            try await NWCBackupService.clear(nostrService: NostrService.shared)
                            savedWallet = nil
                        }
                    } catch {
                        backupError = error.localizedDescription
                    }
                    backupBusy = false
                }
            }
        )
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
