import Foundation

/// What a backup restore tells the person, from the relay's restore code
/// (RestoreOwnBackupC): nil on success. Only a backup holding notes signed
/// by the vault owner is restored, so someone else's is never merged in.
enum BackupRestoreCode {
    static func error(code: Int32) -> String? {
        switch code {
        case 0: return nil
        case 2: return "This backup isn't this vault's. It holds no notes signed by the vault owner's key."
        default: return "Failed to restore backup. Check logs for details."
        }
    }
}
