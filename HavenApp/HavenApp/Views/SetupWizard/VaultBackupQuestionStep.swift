import SwiftUI
import UniformTypeIdentifiers

// MARK: - Do you have a Vault backup?

/// Asked of people who already use Nostr, before the relay import
/// (VaultBackupQuestion). Yes picks a backup file and restores it with the
/// same restore as Settings and the Import step; the relay import is then
/// skipped. No carries on to the relay import as before.
struct VaultBackupQuestionStep: View {
    @EnvironmentObject var configService: ConfigService
    /// The backup was restored.
    let onRestored: () -> Void
    /// No backup: on to the relay import.
    let onNo: () -> Void

    @State private var showingFileImporter = false
    @State private var isRestoring = false
    @State private var restored = false
    @State private var restoreError: String?

    var body: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 12)
            Text("Do you have a Vault backup?")
                .font(.appSystem(size: isIOSDevice ? 24 : 28, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .multilineTextAlignment(.center)
            Text("A backup file from Nostr Vault brings your notes back at once, without downloading them from relays again.")
                .font(.appSystem(size: 15))
                .foregroundColor(WizardColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer().frame(height: 8)

            if isRestoring {
                statusCard {
                    ProgressView().controlSize(.small).tint(WizardColors.accentPrimary)
                    Text("Restoring your backup…")
                        .font(.appSystem(size: 15))
                        .foregroundColor(WizardColors.textSecondary)
                }
            } else if restored {
                statusCard {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(WizardColors.success)
                    Text("Backup restored")
                        .font(.appSystem(size: 15, weight: .medium))
                        .foregroundColor(WizardColors.textPrimary)
                }
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.success.opacity(0.5), lineWidth: 2))
                WizardPrimaryButton(title: "Continue", action: onRestored)
            } else {
                WizardPrimaryButton(title: "Yes, restore my backup", action: pickFile)
                Button(action: onNo) {
                    Text("No, import from my relays")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(WizardColors.textPrimary)
                        .frame(maxWidth: isIOSDevice ? .infinity : nil, minHeight: 44)
                        .padding(.horizontal, isIOSDevice ? 0 : 32)
                        .background(WizardColors.bgCard)
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.borderSubtle, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Text("Backups are the .zip files from Settings › Backup & Restore.")
                    .font(.appSystem(size: 12))
                    .foregroundColor(WizardColors.textMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.zip],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { restore(url) }
            case .failure(let error):
                restoreError = error.localizedDescription
            }
        }
        .alert("Could not restore the backup", isPresented: Binding(
            get: { restoreError != nil }, set: { if !$0 { restoreError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(restoreError ?? "")
        }
    }

    private func statusCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(WizardColors.bgCard)
            .cornerRadius(12)
    }

    private func pickFile() {
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        #endif
        showingFileImporter = true
    }

    private func restore(_ url: URL) {
        isRestoring = true
        VaultBackupRestore.restore(from: url, configService: configService) { error in
            isRestoring = false
            if let error {
                restoreError = error
            } else {
                restored = true
            }
        }
    }
}
