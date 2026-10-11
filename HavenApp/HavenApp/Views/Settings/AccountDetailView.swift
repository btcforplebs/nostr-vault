import SwiftUI
import LocalAuthentication

// MARK: - Account Detail View (Signing Management)

struct AccountDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var configService: ConfigService
    @ObservedObject private var nostrService = NostrService.shared
    @ObservedObject private var nip46Service = NIP46Service.shared
    let npub: String

    var onImportKey: () -> Void
    var onConnectBunker: () -> Void
    var onRevealKey: () -> Void
    var onRemoveAccount: () -> Void

    // Every account action below is one-way: the key material is gone, or the
    // signer link is, and nothing here can put it back.
    @State private var showingRemoveKeyConfirm = false
    @State private var showingDisconnectSignerConfirm = false
    @State private var showingRemoveAccountConfirm = false

    private var isOwner: Bool { npub == configService.config.ownerNpub }
    private var activeNpub: String {
        let a = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        return a.isEmpty ? configService.config.ownerNpub : a
    }
    private var isActive: Bool { npub == activeNpub }
    private var hasLocalKey: Bool {
        isOwner ? !configService.config.ownerNcryptsec.isEmpty : configService.hasCredential(forNpub: npub)
    }
    private var hasBunker: Bool { configService.hasBunkerConfig(forNpub: npub) }
    private var currentMode: String {
        configService.config.accountSigningModes[npub] ?? (hasBunker ? "nip46" : "local")
    }

    var body: some View {
        NavigationStack {
            Form {
                // Header
                Section {
                    headerSection
                }

                // Switch to account
                if !isActive {
                    Section {
                        Button {
                            configService.switchActiveAccount(to: npub)
                            dismiss()
                        } label: {
                            Label("Switch to This Account", systemImage: "arrow.right.circle")
                        }
                    }
                }

                // Signing method picker
                if hasLocalKey && hasBunker {
                    Section {
                        Picker("Signing Method", selection: Binding(
                            get: { currentMode },
                            set: { newMode in
                                configService.setSigningMode(newMode, forNpub: npub)
                            }
                        )) {
                            Text("Local Key").tag("local")
                            Text("Remote Signer").tag("nip46")
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Sign With").settingInfo(.accountSigning)
                    }
                }

                // Local Key section
                Section {
                    if hasLocalKey {
                        HStack(spacing: 8) {
                            Image(systemName: "key.fill")
                                .foregroundColor(.orange)
                            Text("Private key stored")
                                .foregroundColor(.primary)
                            Spacer()
                            if !hasBunker {
                                // Only show active badge when there's no choice
                                Text("Active")
                                    .font(.appCaption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.havenOnline.opacity(0.2))
                                    .foregroundColor(.havenOnline)
                                    .cornerRadius(4)
                            }
                        }

                        Button {
                            authenticateAndReveal()
                        } label: {
                            Label("Reveal Key", systemImage: "eye")
                        }
                        .settingInfo(.accountRevealKey)

                        Button(role: .destructive) {
                            showingRemoveKeyConfirm = true
                        } label: {
                            Label("Remove Local Key", systemImage: "trash")
                        }
                    } else {
                        Button {
                            onImportKey()
                        } label: {
                            Label("Import Private Key", systemImage: "key")
                        }
                    }
                } header: {
                    Text("Local Key")
                }

                // Remote Signer section
                Section {
                    if hasBunker {
                        HStack(spacing: 8) {
                            Image(systemName: "link")
                                .foregroundColor(.blue)
                            Text("Remote signer configured")
                                .foregroundColor(.primary)
                            Spacer()
                            if isActive {
                                Circle()
                                    .fill(nip46Service.isConnected ? Color.havenOnline : Color.red)
                                    .frame(width: 8, height: 8)
                                Text(nip46Service.isConnected ? "Connected" : "Disconnected")
                                    .font(.appCaption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Button(role: .destructive) {
                            showingDisconnectSignerConfirm = true
                        } label: {
                            Label("Disconnect Remote Signer", systemImage: "link.badge.plus")
                        }
                    } else {
                        Button {
                            onConnectBunker()
                        } label: {
                            Label("Connect Remote Signer", systemImage: "link.badge.plus")
                        }
                    }
                } header: {
                    Text("Remote Signer (NIP-46)")
                }

                // NIP-65 Relay List Publishing
                if hasLocalKey || hasBunker {
                    Section {
                        Toggle(isOn: Binding(
                            get: { configService.config.publishRelayListPerAccount[npub] ?? false },
                            set: { enabled in
                                configService.config.publishRelayListPerAccount[npub] = enabled
                                configService.save()
                                if enabled {
                                    NostrService.shared.publishRelayList(forNpub: npub)
                                }
                            }
                        )) {
                            Text("Publish Relay List").settingInfo(.accountPublishInbox)
                        }
                    } header: {
                        Text("Relay List")
                    }
                }

                // Remove account (non-owner only)
                if !isOwner {
                    Section {
                        Button(role: .destructive) {
                            showingRemoveAccountConfirm = true
                        } label: {
                            Label("Remove Account", systemImage: "person.badge.minus")
                        }
                    }
                }
            }
            .groupedFormStyleCompat()
            .confirmDestructive(
                "Remove Local Key",
                isPresented: $showingRemoveKeyConfirm,
                consequence: removeKeyConsequence,
                confirmTitle: "Remove Key",
                action: removeLocalKey
            )
            .confirmDestructive(
                "Disconnect Remote Signer",
                isPresented: $showingDisconnectSignerConfirm,
                consequence: disconnectSignerConsequence,
                confirmTitle: "Disconnect",
                action: disconnectRemoteSigner
            )
            .confirmDestructive(
                "Remove Account",
                isPresented: $showingRemoveAccountConfirm,
                consequence: "This removes \(npub.prefix(12))… from Nostr Vault, along with any key or signer stored for it. Nothing on the relays changes, but you will need the key again to sign back in.",
                confirmTitle: "Remove Account",
                action: {
                    onRemoveAccount()
                    dismiss()
                }
            )
            .navigationTitle("Account")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #else
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
        }
    }

    /// What removing the local key costs, stated before it happens. Nostr Vault
    /// holds the only copy it knows about — if this was never written down,
    /// the account is unrecoverable.
    private var removeKeyConsequence: String {
        if hasBunker {
            return "This deletes the private key stored on this device. Signing falls back to the remote signer. If you have no backup of the key elsewhere, it cannot be recovered."
        }
        return "This deletes the private key stored on this device, and nothing else here can sign for this account afterwards. If you have no backup of the key elsewhere, it cannot be recovered."
    }

    private var disconnectSignerConsequence: String {
        if hasLocalKey {
            return "This drops the remote signer connection and its stored session. Signing falls back to the local key on this device; reconnecting needs a fresh bunker URI."
        }
        return "This drops the remote signer connection and its stored session, and nothing else here can sign for this account afterwards. Reconnecting needs a fresh bunker URI."
    }

    private func removeLocalKey() {
        if isOwner {
            configService.config.ownerNcryptsec = ""
            configService.config.ownerNsec = ""
        } else {
            configService.removeCredential(forNpub: npub)
        }
        // If was using local and now removed, switch to bunker if available
        if currentMode == "local" && hasBunker {
            configService.setSigningMode("nip46", forNpub: npub)
        }
        configService.save()
    }

    private func disconnectRemoteSigner() {
        if nip46Service.isConnected && isActive {
            nip46Service.disconnect()
        }
        configService.removeBunkerConfig(forNpub: npub)
        // If was using nip46 and now removed, switch to local
        if currentMode == "nip46" {
            configService.setSigningMode("local", forNpub: npub)
        }
    }

    private func authenticateAndReveal() {
        // Fail CLOSED: reveal the private key only after a successful device-owner
        // authentication (Face/Touch ID, or passcode fallback). The previous code
        // revealed the key with NO authentication when no biometry/passcode was
        // enrolled or LAContext errored — a fail-open leak of the signing key.
        // When auth is unavailable, evaluatePolicy calls back success=false, so we
        // simply don't reveal.
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Authenticate to reveal your private key") { success, _ in
            DispatchQueue.main.async {
                if success {
                    onRevealKey()
                }
            }
        }
    }

    @ViewBuilder
    private var headerSection: some View {
        let hex = Bech32.decode(npub)?.hexString ?? ""
        let profile = nostrService.profiles[hex]
        let displayName = profile?.bestName ?? String(npub.prefix(12)) + "..."

        HStack(spacing: 12) {
            AvatarView(url: profile?.pictureURL, pubkey: hex, size: 48)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(displayName).fontWeight(.semibold)
                    if isOwner {
                        Text("Owner")
                            .font(.appSystem(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.havenPurple.opacity(0.2))
                            .foregroundColor(.havenPurple)
                            .cornerRadius(4)
                    }
                    if isActive {
                        Text("Active")
                            .font(.appSystem(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.havenOnline.opacity(0.2))
                            .foregroundColor(.havenOnline)
                            .cornerRadius(4)
                    }
                }
                Text(npub)
                    .font(.appSystem(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}
