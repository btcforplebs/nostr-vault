import SwiftUI

struct AccountsSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var nostrService = NostrService.shared
    @ObservedObject private var nip46Service = NIP46Service.shared

    // Delete Account (Leave Nostr Forever)
    @State private var showDeleteAccount = false

    // Add Account Sheet
    @State private var showAddAccount = false

    // Account Detail Sheet
    @State private var selectedAccountNpub: String? = nil

    // Import Key Sheet
    @State private var importingNpub: String? = nil

    // Reveal Key Sheet
    @State private var revealingNpub: String? = nil

    // Connect Signer Sheet
    @State private var connectingSignerNpub: String? = nil

    var body: some View {
        Form {
            Section {
                ForEach(configService.allAccountNpubs, id: \.self) { npub in
                    accountRow(npub: npub)
                }
                .onDelete { indexSet in
                    // Read every npub before removing any: each removal shifts the list.
                    let npubs = indexSet.filter { $0 > 0 }.map { configService.allAccountNpubs[$0] }
                    for npub in npubs { configService.removeAccount(npub: npub) }
                }
            } header: {
                Text("Accounts").settingInfo(.accountAccounts)
            } footer: {
                #if os(iOS)
                Text("Tap an account to manage its keys. Swipe to remove.")
                #else
                Text("Click an account to manage its keys or remove it.")
                #endif
            }

            Section {
                Button(action: {
                    showAddAccount = true
                }) {
                    Label("Add Account", systemImage: "plus.circle.fill")
                }
            }

            if !configService.config.ownerNpub.isEmpty {
                Section {
                    DeleteAccountButton { showDeleteAccount = true }
                } footer: {
                    Text("Asks your relays to erase your account, then deletes it and everything Nostr Vault keeps on this device.")
                }
            }
        }
        .groupedFormStyleCompat()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showDeleteAccount) {
            LeaveNostrForeverView(configService: configService, nostrService: NostrService.shared,
                                  relayManager: RelayProcessManager.shared, onDismiss: { showDeleteAccount = false })
        }
        .sheet(isPresented: $showAddAccount) {
            AddAccountSheetView(onDismiss: { showAddAccount = false }, configService: configService)
        }
        .sheet(item: Binding<IdentifiableString?>(
            get: { importingNpub.map { IdentifiableString(id: $0) } },
            set: { importingNpub = $0?.id }
        )) { item in
            ImportKeySheetView(onDismiss: { importingNpub = nil }, configService: configService, npub: item.id)
        }
        .sheet(item: Binding<IdentifiableString?>(
            get: { revealingNpub.map { IdentifiableString(id: $0) } },
            set: { revealingNpub = $0?.id }
        )) { item in
            RevealKeySheetView(onDismiss: { revealingNpub = nil }, configService: configService, npub: item.id)
        }
        .sheet(item: Binding<IdentifiableString?>(
            get: { connectingSignerNpub.map { IdentifiableString(id: $0) } },
            set: { connectingSignerNpub = $0?.id }
        )) { item in
            ConnectSignerSheetView(onDismiss: { connectingSignerNpub = nil }, configService: configService, npub: item.id)
        }
        .sheet(item: Binding<IdentifiableString?>(
            get: { selectedAccountNpub.map { IdentifiableString(id: $0) } },
            set: { selectedAccountNpub = $0?.id }
        )) { item in
            AccountDetailView(
                configService: configService,
                npub: item.id,
                onImportKey: {
                    selectedAccountNpub = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        importingNpub = item.id
                    }
                },
                onConnectBunker: {
                    selectedAccountNpub = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        connectingSignerNpub = item.id
                    }
                },
                onRevealKey: {
                    selectedAccountNpub = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        revealingNpub = item.id
                    }
                },
                onRemoveAccount: {
                    configService.removeAccount(npub: item.id)
                }
            )
        }
    }

    private func accountRow(npub: String) -> some View {
        let hex = Bech32.decode(npub)?.hexString ?? ""
        let profile = nostrService.profiles[hex]
        let displayName = profile?.bestName ?? String(npub.prefix(12)) + "..."
        let isOwner = (npub == configService.config.ownerNpub)
        let activeNpub = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let isActive = activeNpub.isEmpty ? isOwner : npub == activeNpub
        let hasLocalKey = isOwner ? !configService.config.ownerNcryptsec.isEmpty : configService.hasCredential(forNpub: npub)
        let hasBunker = configService.hasBunkerConfig(forNpub: npub)
        let signingMode = configService.config.accountSigningModes[npub] ?? (hasBunker ? "nip46" : "local")

        return HStack(spacing: 12) {
            AvatarView(url: profile?.pictureURL, pubkey: hex, size: 38)
                .overlay(
                    Circle().stroke(
                        isActive ? (isOwner ? Color.havenPurple : Color.orange) : Color.clear,
                        lineWidth: 2
                    )
                )

            VStack(alignment: .leading, spacing: 3) {
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
                }

                // Compact signing mode indicator
                HStack(spacing: 4) {
                    if hasBunker && signingMode == "nip46" {
                        Image(systemName: "link")
                            .font(.appSystem(size: 9))
                        Text("Remote Signer")
                        if isActive {
                            Circle()
                                .fill(nip46Service.isConnected ? Color.havenOnline : Color.red)
                                .frame(width: 5, height: 5)
                        }
                    } else if hasLocalKey {
                        Image(systemName: "key.fill")
                            .font(.appSystem(size: 9))
                            .foregroundColor(.orange)
                        Text("Local Key")
                    } else {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.appSystem(size: 9))
                        Text("No signing key")
                    }
                }
                .font(.appCaption)
                .foregroundColor(.secondary)
            }

            Spacer()

            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.havenOnline)
            }

            Image(systemName: "chevron.right")
                .font(.appCaption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedAccountNpub = npub
        }
    }
}
