import SwiftUI

struct ImportKeySheetView: View {
    @Environment(\.dismiss) private var dismiss
    var onDismiss: (() -> Void)? = nil
    @ObservedObject var configService: ConfigService
    let npub: String

    @State private var importNsec = ""
    @State private var importPassword = ""
    @State private var importConfirm = ""
    @State private var importError: String? = nil

    var body: some View {
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
                
                Text("Import Key")
                    .font(.appHeadline)
                
                Spacer()
                
                Button("Import") {
                    processImport()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.havenPurple)
                .disabled(importNsec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || importPassword.isEmpty || importConfirm.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            .background(Color.platformControlBackground.opacity(0.5))
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Private Key (nsec)")
                            .font(.appSystem(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                        
                        TextEditor(text: $importNsec)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 80)
                            .padding(6)
                            .background(Color.platformControlBackground)
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                            )
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Encrypt with Password")
                            .font(.appSystem(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)

                        // Hidden username field anchors AutoFill to the npub
                        // so the nsec is not captured as the username.
                        TextField("", text: .constant(npub))
                            .textContentType(.username)
                            .frame(width: 0, height: 0)
                            .opacity(0)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)

                        SecureField("Password", text: $importPassword)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.newPassword)
                            .font(.appBody)

                        SecureField("Confirm Password", text: $importConfirm)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.newPassword)
                            .font(.appBody)
                    }
                    
                    if let error = importError {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.appCaption)
                    }
                }
                .padding(20)
            }
        }
        .background(Color.platformSecondaryGroupedBackground)
        .frame(width: 480, height: 350)
        #else
        NavigationStack {
            Form {
                Section("Private Key") {
                    TextEditor(text: $importNsec).font(.system(.body, design: .monospaced)).frame(minHeight: 80)
                }
                Section("Encrypt with Password") {
                    // Hidden username field anchors AutoFill to the npub
                    // so the nsec is not captured as the username.
                    TextField("", text: .constant(npub))
                        .textContentType(.username)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    SecureField("Password", text: $importPassword)
                        .textContentType(.newPassword)
                    SecureField("Confirm", text: $importConfirm)
                        .textContentType(.newPassword)
                }
                if let error = importError { Text(error).foregroundColor(.red) }
            }
            .navigationTitle("Import Key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { performDismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Import") {
                    processImport()
                }}
            }
        }
        #endif
    }

    private func processImport() {
        guard importPassword == importConfirm, importPassword.count >= 8 else {
            importError = "Password must be at least 8 characters and match confirm password"
            return
        }
        let nsec = importNsec.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            // Before anything is overwritten: a typo'd nsec still decodes to a
            // key, and storing it loses the real one.
            try NIP49Service.validateImport(nsec: nsec, matching: npub)
        } catch {
            importError = error.localizedDescription
            return
        }
        do {
            if npub == configService.config.ownerNpub {
                try configService.config.setEncryptedNsec(nsec: nsec, password: importPassword)
                _ = NIP49Service.storePasswordInKeychain(importPassword)
                configService.save()
            } else {
                try configService.setCredential(nsec: nsec, password: importPassword, forNpub: npub)
            }
            performDismiss()
        } catch {
            importError = "Failed to import and encrypt key"
        }
    }

    private func performDismiss() {
        if let onDismiss = onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }
}
