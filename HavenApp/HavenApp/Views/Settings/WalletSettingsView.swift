import SwiftUI

struct WalletSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @State private var balance: Int? = nil
    @State private var isFetchingBalance = false
    @State private var balanceError: String? = nil
    /// The wallet slot on this Nostr account (NIP-78, Wisp's format), and
    /// whose account it was read for: an action on another account's state
    /// would publish into the wrong slot.
    @State private var backupStatus: NWCBackup.Status = .unknown
    @State private var backupStatusAccount = ""
    @State private var backupChecked = false
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

            if backupChecked {
                accountBackupSection
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
        }
        .groupedFormStyleCompat()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            if !configService.config.nwcURI.isEmpty {
                fetchBalance()
            }
        }
        .onChange(of: configService.config.nwcURI) { _, _ in
            balance = nil
            balanceError = nil
            backupError = nil
        }
        .task(id: configService.activeAccountHexPubkey) {
            await refreshBackupStatus(askSigner: false)
        }
    }

    // MARK: - Wallet saved on the Nostr account

    private var currentWallet: String {
        configService.config.nwcURI.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var savedDay: String {
        guard let at = backupStatus.savedAt else { return "" }
        return Date(timeIntervalSince1970: TimeInterval(at)).formatted(date: .abbreviated, time: .omitted)
    }

    @ViewBuilder
    private var accountBackupSection: some View {
        Section {
            switch backupStatus {
            case .unknown:
                Text("Couldn't check your Nostr account for a saved wallet.")
                    .foregroundColor(.secondary)
                Button("Check again") { Task { await refreshBackupStatus(askSigner: false) } }
            case .empty:
                if currentWallet.isEmpty {
                    Text("No wallet saved on your Nostr account.")
                        .foregroundColor(.secondary)
                } else {
                    saveToggle(isOn: false)
                }
                // One relay's answer decides "empty"; a slower one may still
                // hold a wallet, so it can be asked again.
                Button("Check again") { Task { await refreshBackupStatus(askSigner: false) } }
                    .disabled(backupBusy)
            case .saved(let uri, _):
                if currentWallet.isEmpty {
                    Button {
                        configService.config.nwcURI = uri
                        configService.save()
                    } label: {
                        Label("Use saved wallet", systemImage: "arrow.down.circle")
                    }
                } else {
                    saveToggle(isOn: uri == currentWallet)
                }
            case .needsSigner:
                Text("A wallet is saved on your Nostr account (\(savedDay)). Your signer has to open it.")
                    .foregroundColor(.secondary)
                Button("Load with signer") { Task { await refreshBackupStatus(askSigner: true) } }
                    .disabled(backupBusy)
                replaceButton
            case .unreadable:
                Text("A wallet is saved on your Nostr account (\(savedDay)), but this device can't read it.")
                    .foregroundColor(.secondary)
                Button("Try again") { Task { await refreshBackupStatus(askSigner: true) } }
                    .disabled(backupBusy)
                replaceButton
            }
            // Offered whenever a wallet may be on the account: removing needs
            // no proof it is there (see NWCBackup.Status.offersRemove).
            if backupStatus.offersRemove(current: currentWallet) {
                Button("Remove from my account", role: .destructive) { runBackupAction(save: false) }
                    .disabled(backupBusy)
            }
        } header: {
            HStack {
                Text("Your Nostr account")
                if backupBusy {
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if case .saved(let uri, _) = backupStatus, !currentWallet.isEmpty, uri != currentWallet {
                    Text("Your account holds a different wallet, saved \(savedDay). Turning this on replaces it.")
                } else if case .saved = backupStatus, currentWallet.isEmpty {
                    Text("Saved \(savedDay). It may have come from Nostr Vault on another device or from Wisp.")
                }
                Text("Stored encrypted to your key (NIP-44) on your relays, so Nostr Vault on your other devices, or Wisp, can use it. Anyone who has your key can read it and spend from this wallet.")
                if let backupError {
                    Text(backupError).foregroundColor(.red)
                }
            }
        }
    }

    /// Saving needs no read: with a wallet in use, a slot this device can't
    /// read can still be replaced by it.
    @ViewBuilder
    private var replaceButton: some View {
        if !currentWallet.isEmpty {
            Button("Save this wallet instead") { runBackupAction(save: true) }
                .disabled(backupBusy)
        }
    }

    private func saveToggle(isOn: Bool) -> some View {
        Toggle("Save wallet to my Nostr account", isOn: Binding(
            get: { isOn },
            set: { runBackupAction(save: $0) }
        ))
        .disabled(backupBusy)
    }

    private func refreshBackupStatus(askSigner: Bool) async {
        let account = configService.activeAccountHexPubkey
        if account != backupStatusAccount {
            backupStatus = .unknown
            backupChecked = false
        }
        backupStatusAccount = account
        backupBusy = askSigner
        let status = await NWCBackupService.status(for: account, askSigner: askSigner, nostrService: NostrService.shared)
        // A switch while the lookup ran: that answer belongs to someone else.
        guard configService.activeAccountHexPubkey == account else { return }
        backupStatus = status
        backupChecked = true
        backupBusy = false
    }

    /// Saves the wallet in use (`save`) or takes the slot off, as the account
    /// the screen shows. Locked to that account all the way to publishing.
    private func runBackupAction(save: Bool) {
        guard !backupBusy else { return }
        let lock = ModePostPublisher.lockAccount(configService: configService)
        guard lock.hex == backupStatusAccount else {
            backupError = NWCBackupService.BackupError.accountChanged.localizedDescription
            Task { await refreshBackupStatus(askSigner: false) }
            return
        }
        let uri = configService.config.nwcURI
        backupBusy = true
        backupError = nil
        Task {
            var next: NWCBackup.Status?
            do {
                if save {
                    try await NWCBackupService.save(uri, lockedTo: lock, nostrService: NostrService.shared)
                    next = NWCBackup.plaintext(forSaving: uri).map { .saved(uri: $0, savedAt: Int64(Date().timeIntervalSince1970)) }
                } else {
                    try await NWCBackupService.clear(lockedTo: lock, nostrService: NostrService.shared)
                    next = .empty
                }
            } catch {
                backupError = error.localizedDescription
            }
            // Only the account it was done for gets the new state.
            if let next, configService.activeAccountHexPubkey == lock.hex { backupStatus = next }
            backupBusy = false
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
}
