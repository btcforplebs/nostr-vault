import SwiftUI
import UniformTypeIdentifiers

/// Vault tab › Keep it full › Restore from a backup: the backup zip, moved
/// out of setup (Logen 2026-11-05). Only this vault owner's own backup is
/// restored (VaultBackupRestore → RestoreOwnBackupC).
struct RestoreBackupRow: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager
    @State private var picking = false
    @State private var restoring = false
    @State private var result: (text: String, failed: Bool)?

    var body: some View {
        DashboardRow(
            icon: "doc.zipper",
            title: "Restore from a backup",
            detail: result?.text ?? "Brings back notes from a backup .zip made by Nostr Vault.",
            state: result?.failed == true ? .todo : .info
        ) {
            RowButton(title: "Restore", isLoading: restoring) { pick() }
                .disabled(restoring || relayManager.isVaultBusy)
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.zip], allowsMultipleSelection: false) { picked in
            switch picked {
            case .success(let urls):
                if let url = urls.first { restore(url) }
            case .failure(let error):
                result = (error.localizedDescription, true)
            }
        }
    }

    private func pick() {
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        #endif
        picking = true
    }

    private func restore(_ url: URL) {
        restoring = true
        result = nil
        VaultBackupRestore.restore(from: url, configService: configService) { error in
            restoring = false
            result = error.map { ($0, true) } ?? ("Backup restored.", false)
        }
    }
}
