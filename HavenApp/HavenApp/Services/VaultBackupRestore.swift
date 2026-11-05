import Foundation

/// Restores a Nostr Vault backup file picked by the user into this device's
/// relay: the Vault tab's "Restore from a backup" (moved out of setup, Logen
/// 2026-11-05). Only the vault owner's own backup is restored
/// (RestoreOwnBackupC), as in Settings › Backup.
@MainActor
enum VaultBackupRestore {
    /// Restores the picked file where it is (no temp copy, #17), holding
    /// its security scope until the restore ends. `completion` gets nil on
    /// success, or the message to show.
    static func restore(from url: URL, configService: ConfigService,
                        completion: @escaping @MainActor (String?) -> Void) {
        configService.save()
        ScopedImportFile.read(url) { path, finished in
            RelayProcessManager.shared.runOwnBackupRestore(config: configService.config, inputPath: path) { code in
                finished()
                Task { @MainActor in
                    if code == 0 { configService.reload() }
                    completion(BackupRestoreCode.error(code: code))
                }
            }
        }
    }
}
