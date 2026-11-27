import Foundation

/// Whether the wallet screens (A3) may make a new wallet for an account
/// (design §2 "never create a second 17375"). A new wallet key's 17375 would
/// copy over the real one on every Vault, and nutzaps locked to the old key
/// could no longer be spent, so this waits for every place the wallet could be.
///
/// The Vault this device reads is its own relay at 127.0.0.1. On a new or
/// reinstalled phone its `/private` stays empty until the mesh copy from a
/// paired desktop Vault (a Mac or a home Vault) arrives, so an empty answer
/// alone proves nothing. A new wallet is allowed only when the last read found
/// nothing (`noWallet`) and every paired desktop Vault had finished a copy into
/// this one before that read. With no desktop Vault paired, the read is the
/// whole answer. A desktop never copied from blocks it (pair and copy first).
/// Pure, so CashuWalletTests checks it.
enum CashuNewWalletGate {
    /// - outcome: the last restore's outcome for the account.
    /// - readAt: when that restore read the Vault (Unix s).
    /// - desktops: npubs of the paired desktop Vaults this device copies from.
    /// - copiedAt: when the last copy from each device finished (Unix s).
    static func allows(_ outcome: CashuRestoreOutcome?, readAt: Int?,
                       desktops: [String], copiedAt: [String: Int]) -> Bool {
        guard outcome == .noWallet, let readAt else { return false }
        return desktops.allSatisfy { npub in
            guard let at = copiedAt[npub] else { return false }
            return at <= readAt
        }
    }

    /// The desktop Vaults that have not copied into this one before `readAt`.
    static func waitingFor(readAt: Int?, desktops: [String], copiedAt: [String: Int]) -> [String] {
        desktops.filter { npub in
            guard let readAt, let at = copiedAt[npub] else { return true }
            return at > readAt
        }
    }
}
