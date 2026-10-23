import SwiftUI

struct RevealKeySheetView: View {
    @Environment(\.dismiss) private var dismiss
    var onDismiss: (() -> Void)? = nil
    @ObservedObject var configService: ConfigService
    let npub: String

    @State private var password = ""
    @State private var revealedNsec: String? = nil
    @State private var errorMessage: String? = nil
    @State private var copied = false
    /// The password saved on this device for this key, read once when the
    /// sheet opens (a keychain read per render could prompt on the Mac). A
    /// key that was plaintext before 3.0.0 was encrypted with one the user
    /// never saw, so an empty field uses it; the sheet only opens after
    /// device-owner authentication (AccountDetailView.authenticateAndReveal).
    @State private var storedPassword: String? = nil

    var body: some View {
        sheetContent.onAppear {
            storedPassword = npub == configService.config.ownerNpub
                ? CredentialStore.getOwnerPassword()
                : CredentialStore.getPassword(forNpub: npub)
        }
    }

    @ViewBuilder
    private var sheetContent: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") {
                    performDismiss()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Text("Reveal Private Key")
                    .font(.appHeadline)

                Spacer()

                if revealedNsec == nil {
                    Button("Unlock") {
                        decryptKey()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.havenPurple)
                    .disabled(password.isEmpty && storedPassword == nil)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") {
                        performDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.havenPurple)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .background(Color.platformControlBackground.opacity(0.5))

            VStack(alignment: .leading, spacing: 16) {
                if let nsec = revealedNsec {
                    revealedKeyContent(nsec: nsec)
                } else {
                    passwordEntryContent()
                }
            }
            .padding(20)

            Spacer()
        }
        .background(Color.platformSecondaryGroupedBackground)
        .frame(width: 480, height: revealedNsec != nil ? 280 : 220)
        #else
        NavigationStack {
            Form {
                if let nsec = revealedNsec {
                    Section("Private Key") {
                        revealedKeyContent(nsec: nsec)
                    }
                } else {
                    Section {
                        SecureField("NIP-49 Password", text: $password)
                            .textContentType(.password)
                            .onSubmit { decryptKey() }
                    } header: {
                        Text("Enter Password")
                    } footer: {
                        if storedPassword != nil { Text(Self.storedPasswordHint) }
                    }
                    if let error = errorMessage {
                        Text(error).foregroundColor(.red).font(.appCaption)
                    }
                }
            }
            .navigationTitle("Reveal Private Key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { performDismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if revealedNsec == nil {
                        Button("Unlock") { decryptKey() }
                            .disabled(password.isEmpty && storedPassword == nil)
                    } else {
                        Button("Done") { performDismiss() }
                    }
                }
            }
        }
        #endif
    }

    @ViewBuilder
    private func passwordEntryContent() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Enter Password")
                .font(.appSystem(size: 13, weight: .semibold))
                .foregroundColor(.secondary)

            SecureField("NIP-49 Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
                .font(.appBody)
                .onSubmit { decryptKey() }

            if storedPassword != nil {
                Text(Self.storedPasswordHint)
                    .font(.appCaption)
                    .foregroundColor(.secondary)
            }
        }

        if let error = errorMessage {
            Text(error)
                .foregroundColor(.red)
                .font(.appCaption)
        }
    }

    @ViewBuilder
    private func revealedKeyContent(nsec: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your Private Key (nsec)")
                .font(.appSystem(size: 13, weight: .semibold))
                .foregroundColor(.secondary)

            Text(nsec)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.platformControlBackground)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )

            Button {
                copyNsec(nsec)
            } label: {
                Label(
                    copied ? "Copied!" : "Copy to Clipboard",
                    systemImage: copied ? "checkmark" : "doc.on.doc"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Text("Keep this key safe. Anyone with your nsec has full control of your Nostr identity.")
                .font(.appCaption2)
                .foregroundColor(.orange)
        }
    }

    private static let storedPasswordHint = "Leave it empty to use the password saved on this device."


    private func decryptKey() {
        guard let password = password.isEmpty ? storedPassword : password else { return }
        errorMessage = nil

        let isOwner = (npub == configService.config.ownerNpub)

        do {
            let nsec: String
            if isOwner {
                nsec = try configService.config.getDecryptedNsec(password: password)
            } else {
                guard let ncryptsec = configService.config.accountCredentials[npub],
                      !ncryptsec.isEmpty else {
                    errorMessage = "No encrypted key found for this account"
                    return
                }
                nsec = try NIP49Service.decrypt(ncryptsec: ncryptsec, password: password)
            }
            revealedNsec = nsec
        } catch {
            errorMessage = "Incorrect password or decryption failed"
        }
    }

    private func copyNsec(_ nsec: String) {
        PlatformClipboard.copy(nsec)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { copied = false }
        }
    }

    private func performDismiss() {
        revealedNsec = nil
        password = ""
        errorMessage = nil

        if let onDismiss = onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }
}
