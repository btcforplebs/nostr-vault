import SwiftUI

// MARK: - AccountSwitcherView

struct AccountSwitcherView: View {
    @ObservedObject var configService: ConfigService
    @ObservedObject private var nostrService = NostrService.shared
    @Environment(\.dismiss) private var dismiss

    // Key import sheet state
    @State private var importingNpub: String? = nil
    @State private var importNsec: String = ""
    @State private var importPassword: String = ""
    @State private var importConfirm: String = ""
    @State private var importError: String? = nil
    @State private var importSuccess: Bool = false

    private var activeNpub: String {
        let a = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        return a.isEmpty ? configService.config.ownerNpub : a
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Accounts")
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // Account rows
            VStack(spacing: 2) {
                ForEach(configService.allAccountNpubs, id: \.self) { npub in
                    accountRow(npub: npub)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(width: 270)
        .background(Color.platformControlBackground)
        .sheet(item: Binding<IdentifiableString?>(
            get: { importingNpub.map { IdentifiableString(id: $0) } },
            set: { importingNpub = $0?.id }
        )) { item in
            importKeySheet(forNpub: item.id)
        }
    }

    @ViewBuilder
    private func accountRow(npub: String) -> some View {
        let isOwner = npub == configService.config.ownerNpub
        let isActive = npub == activeNpub
        let hex = Bech32.decode(npub)?.hexString ?? ""
        let profile = nostrService.profiles[hex]
        let displayName = profile?.bestName ?? String(npub.prefix(16)) + "..."
        let hasKey = isOwner || configService.hasCredential(forNpub: npub)

        Button(action: {
            configService.switchActiveAccount(to: npub)
            dismiss()
        }) {
            HStack(spacing: 10) {
                // Avatar
                ZStack(alignment: .bottomTrailing) {
                    AvatarView(url: profile?.pictureURL, pubkey: hex, size: 34)
                        .overlay(
                            Circle()
                                .stroke(
                                    isActive
                                        ? (isOwner ? Color.havenPurple : Color.orange)
                                        : Color.clear,
                                    lineWidth: 2
                                )
                        )
                }

                // Name + badges
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(displayName)
                            .font(.appSystem(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        if isOwner {
                            Text("Owner")
                                .font(.appSystem(size: 9, weight: .bold))
                                .foregroundColor(Color.havenPurple)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.havenPurple.opacity(0.15))
                                .cornerRadius(4)
                        }
                    }

                    Text(npub.prefix(20) + "...")
                        .font(.appSystem(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Key status / import
                if !hasKey {
                    Button(action: { importingNpub = npub }) {
                        Image(systemName: "key.fill")
                            .font(.appSystem(size: 11))
                            .foregroundColor(.orange)
                            .padding(6)
                            .background(Color.orange.opacity(0.12))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help("Import signing key")
                } else {
                    Image(systemName: "key.fill")
                        .font(.appSystem(size: 11))
                        .foregroundColor(.secondary.opacity(0.4))
                }

                // Active checkmark
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.appSystem(size: 15))
                    .foregroundColor(isActive ? Color.havenPurple : .secondary.opacity(0.3))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isActive ? Color.havenPurple.opacity(0.08) : Color.clear)
            .cornerRadius(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }

    // MARK: - Import Key Sheet

    @ViewBuilder
    private func importKeySheet(forNpub npub: String) -> some View {
        let hex = Bech32.decode(npub)?.hexString ?? ""
        let profile = nostrService.profiles[hex]
        let displayName = profile?.bestName ?? String(npub.prefix(20)) + "..."

        VStack(spacing: 0) {
            // Sheet header
            HStack {
                AvatarView(url: profile?.pictureURL, pubkey: hex, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import Key")
                        .font(.appHeadline)
                    Text(displayName)
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            Form {
                Section("Private Key") {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $importNsec)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 70)
                            .padding(4)
                            .background(Color.platformControlBackground)
                            .cornerRadius(6)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        if importNsec.isEmpty {
                            Text("nsec1...")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.5))
                                .padding(8)
                                .allowsHitTesting(false)
                        }
                    }
                    Text("Enter the nsec for \(displayName)")
                        .font(.appCaption2)
                        .foregroundColor(.secondary)
                }

                Section("Encrypt with Password (NIP-49)") {
                    // Hidden username field anchors AutoFill to the npub so the
                    // nsec text editor above is not captured as the username.
                    TextField("", text: .constant(npub))
                        .textContentType(.username)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    SecureField("Password", text: $importPassword)
                        .textContentType(.newPassword)
                    SecureField("Confirm Password", text: $importConfirm)
                        .textContentType(.newPassword)
                    Label("Password saved to Keychain automatically", systemImage: "lock.fill")
                        .font(.appCaption)
                        .foregroundColor(.green)
                }

                if let error = importError {
                    Section {
                        Text(error).font(.appCaption).foregroundColor(.red)
                    }
                }
                if importSuccess {
                    Section {
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            Text("Key imported successfully!").font(.appCaption).fontWeight(.semibold)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    resetImportForm()
                    importingNpub = nil
                }
                .keyboardShortcut(.cancelAction)

                Button("Import") {
                    saveImportedKey(forNpub: npub)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(importNsec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || importPassword.isEmpty)
            }
            .padding()
        }
        .frame(width: 420, height: 480)
    }

    private func saveImportedKey(forNpub npub: String) {
        let nsecTrimmed = importNsec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nsecTrimmed.isEmpty else { importError = "Private key cannot be empty"; return }
        guard importPassword == importConfirm else { importError = "Passwords do not match"; return }
        guard importPassword.count >= 8 else { importError = "Password must be at least 8 characters"; return }

        do {
            try configService.setCredential(nsec: nsecTrimmed, password: importPassword, forNpub: npub)
            importSuccess = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                resetImportForm()
                importingNpub = nil
            }
        } catch {
            importError = "Failed to encrypt key: \(error.localizedDescription)"
        }
    }

    private func resetImportForm() {
        importNsec = ""
        importPassword = ""
        importConfirm = ""
        importError = nil
        importSuccess = false
    }
}
